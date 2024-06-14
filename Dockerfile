# syntax=docker/dockerfile:1.3
ARG BUILD_OS=debian
ARG BUILD_NGINX_VERSION=1.27.0
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.4.0 AS xx

### Build base image for debian
FROM --platform=$BUILDPLATFORM debian:bullseye as build-base-debian

RUN apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y \
    build-essential \
    ca-certificates \
    clang \
    git \
    golang \
    libcurl4 \
    libtool \
    libz-dev \
    lld \
    pkg-config \
    wget

COPY --from=xx / /
ARG TARGETPLATFORM

RUN xx-apt install -y xx-cxx-essentials zlib1g-dev libcurl4-openssl-dev libc-ares-dev libre2-dev libssl-dev libc-dev libmsgpack-dev


### Build base image for alpine
FROM --platform=$BUILDPLATFORM alpine:3.20 as build-base-alpine

RUN apk add --no-cache \
    alpine-sdk \
    bash \
    build-base \
    clang \
    gcompat \
    git \
    libcurl \
    lld \
    zlib-dev

COPY --from=xx / /
ARG TARGETPLATFORM

RUN xx-apk add --no-cache xx-cxx-essentials openssl-dev zlib-dev zlib libgcc curl-dev msgpack-cxx-dev


### Build image
FROM build-base-${BUILD_OS} as build-base

ENV CMAKE_VERSION 3.22.2
RUN wget -q -O cmake-linux.sh "https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-linux-$(arch).sh" \
    && sh cmake-linux.sh -- --skip-license --prefix=/usr \
    && rm cmake-linux.sh

# XX_CC_PREFER_STATIC_LINKER prefers ld to lld in ppc64le and 386.
ENV XX_CC_PREFER_STATIC_LINKER=1


### Base build image for debian
FROM nginx:${BUILD_NGINX_VERSION}-bookworm as build-nginx-debian

RUN echo "deb-src [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian/ bookworm nginx" >> /etc/apt/sources.list.d/nginx.list \
    && apt-get update \
    && apt-get build-dep -y nginx \
    && apt-get install -y cmake git git-lfs libc-ares-dev libc-ares2 libssl-dev wget \
    && git config --global http.version HTTP/1.1 && git config --global http.postBuffer 524288000 \
    && git config --global http.lowSpeedLimit 0 && git config --global http.lowSpeedTime 999999


### Base build image for alpine
FROM nginx:${BUILD_NGINX_VERSION}-alpine AS build-nginx-alpine
RUN apk add --no-cache \
    build-base \
    c-ares \
    c-ares-dev \
    cmake \
    git \
    git-lfs \
    linux-headers \
    openssl-dev \
    pcre2-dev \
    wget \
    zlib-dev \
    && git config --global http.version HTTP/1.1 && git config --global http.postBuffer 524288000 \
    && git config --global http.lowSpeedLimit 0 && git config --global http.lowSpeedTime 999999


### Build nginx-otel modules
FROM build-nginx-${BUILD_OS} as build-nginx

COPY . /src

RUN curl -fsSL -O https://github.com/nginx/nginx/archive/release-${NGINX_VERSION}.tar.gz \
    && tar zxf release-${NGINX_VERSION}.tar.gz \
    && cd nginx-release-${NGINX_VERSION} \
    && auto/configure \
    --with-compat 
RUN cd /src \
    && mkdir .build && cd .build && \
    cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTING=OFF \
    -DNGX_OTEL_FETCH_DEPS=ON \
    -D NGX_OTEL_NGINX_BUILD_DIR=/nginx-release-${NGINX_VERSION}/objs \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON .. \
    && make -j$(nproc) install \
    && strip ngx_otel_module.so \
    && cp ngx_otel_module.so /usr/lib/nginx/modules/


### Base image for alpine
FROM nginx:${BUILD_NGINX_VERSION}-alpine as nginx-alpine
RUN apk add --no-cache libstdc++ c-ares


### Base image for debian
FROM nginx:${BUILD_NGINX_VERSION}-bookworm as nginx-debian
RUN apt-get update && apt-get upgrade -y && apt-get install -y libc-ares2


### Build final image
FROM nginx-${BUILD_OS} as final

COPY --from=build-nginx /usr/lib/nginx/modules/ /usr/lib/nginx/modules/

RUN ldconfig /usr/local/lib/

STOPSIGNAL SIGQUIT
