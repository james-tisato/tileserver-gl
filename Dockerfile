FROM centos:centos7.9.2009 AS builder

ENV NODE_ENV="production"

# Add additional package repositories
RUN set -ex; \
    yum install -y \
      centos-release-scl \
      epel-release;

# Install build dependencies
RUN set -ex; \
    yum install -y \
      devtoolset-10 \
      python3 \
      ca-certificates \
      wget \
      git \
      ccache \
      cmake3 \
      ninja-build \
      pkgconfig \
      xorg-x11-server-Xvfb \
      glfw-devel \
      libuv-devel \
      libjpeg-turbo-devel \
      libicu \
      cairo-devel \
      pango-devel \
      giflib-devel \
      libglvnd-devel \
      librsvg2-devel \
      libcurl-devel \
      pixman-devel; \
    wget -qO- https://rpm.nodesource.com/setup_16.x | bash; \
    yum install -y nodejs;

# Rebuild maplibre-gl-native from source because the prebuilt binaries don't work on CentOS 7.
# This is more involved and follows the binaries build process, adapted as best we can to CentOS 7:
# https://github.com/maplibre/maplibre-gl-native/tree/main/platform/linux

# Clone repo and pull submodules
RUN set -ex; \
    cd /usr/src; \
    git clone https://github.com/maplibre/maplibre-gl-native.git; \
    cd maplibre-gl-native; \
    git checkout node-v5.1.0-pre.1; \
    git submodule update --init --recursive;

WORKDIR /usr/src/maplibre-gl-native

# Modify CMake config to include pthread support
# https://stackoverflow.com/questions/46519307/undefined-reference-to-symbol-pthread-setname-npglibc-2-12-haskell-stack-err
# https://stackoverflow.com/questions/5395309/how-do-i-force-cmake-to-include-pthread-option-during-compilation
RUN set -ex; \
    sed -i 's?set(BLACKLIST "mbgl-compiler-options")?set(BLACKLIST "mbgl-compiler-options" "Threads::Threads")?g' scripts/license.cmake; \
    sed -i 's?set(CMAKE_VISIBILITY_INLINES_HIDDEN 1)?set(CMAKE_VISIBILITY_INLINES_HIDDEN 1)\nset(CMAKE_THREAD_PREFER_PTHREAD TRUE)\nset(THREADS_PREFER_PTHREAD_FLAG TRUE)\nfind_package(Threads REQUIRED)?g' CMakeLists.txt; \
    sed -i 's?        mbgl-vendor-wagyu?        mbgl-vendor-wagyu\n        Threads::Threads?g' CMakeLists.txt;

# Prep for maplibre build
RUN set -ex; \
    npm ci --ignore-scripts; \
    ccache --clear --set-config cache_dir=~/.ccache;
    
# Build maplibre
RUN set -ex; \
    scl enable devtoolset-10 "cmake3 . -B build -G Ninja -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++"; \
    scl enable devtoolset-10 "cmake3 --build build -j $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)";
    
# Install tileserver-gl packages
WORKDIR /usr/src/app
COPY package* ./
RUN npm ci --omit=dev

# Deploy maplibre binary built earlier
RUN set -ex; \
    cp /usr/src/maplibre-gl-native/lib/node-v93/mbgl.node /usr/src/app/node_modules/\@maplibre/maplibre-gl-native/lib/node-v93

# Rebuild a few other packages from source (using npm build) because the prebuilt binaries don't work on CentOS 7
#  - canvas: https://github.com/Automattic/node-canvas/issues/1796
#  - sqlite3: https://github.com/TryGhost/node-sqlite3/issues/1582
RUN scl enable devtoolset-10 'npm rebuild --build-from-source canvas sqlite3'


FROM centos:centos7.9.2009 AS final

ENV \
    NODE_ENV="production" \
    CHOKIDAR_USEPOLLING=1 \
    CHOKIDAR_INTERVAL=500

# Add additional package repositories
RUN set -ex; \
    yum install -y \
      epel-release;

# Install runtime dependencies
RUN set -ex; \
    groupadd -r node; \
    useradd -r -g node node; \
    yum install -y \
      ca-certificates \
      which \
      wget \
      xorg-x11-server-Xvfb \
      glfw \
      libuv \
      libjpeg-turbo \
      libicu \
      cairo \
      pango \
      giflib \
      libglvnd-opengl \
      libglvnd-egl \
      libglvnd-gles \
      libglvnd-glx \
      mesa-dri-drivers \
      librsvg2 \
      libcurl \
      pixman; \
    wget -qO- https://rpm.nodesource.com/setup_16.x | bash; \
    yum install -y nodejs; \
    yum erase -y wget; \
    yum clean all -y;

# Copy node environment built earlier
COPY --from=builder /usr/src/app /usr/src/app

# Copy in tileserver app
COPY . /usr/src/app

RUN mkdir -p /data && chown node:node /data
VOLUME /data
WORKDIR /data

EXPOSE 8080

USER node:node

ENTRYPOINT ["/usr/src/app/docker-entrypoint.sh"]

HEALTHCHECK --interval=5s --timeout=2s --retries=5 CMD node /usr/src/app/src/healthcheck.js
