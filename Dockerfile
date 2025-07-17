ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# npm packages
WORKDIR /git
COPY package.json .
COPY yarn.lock .
ENV YARN_CHECKSUM_BEHAVIOR=update

# git
RUN apt-get update && apt-get install -y git

RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3
RUN yarn install

# App
WORKDIR /git
ADD . /git
RUN yarn install
RUN yarn build && find ./dist -name "*.d.ts" -delete

#
# Dashboard
#
FROM node:${NODE_IMAGE_TAG} AS dashboard

# jq to parse json
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# wget, unzip
RUN apt-get update && apt-get install -y wget unzip && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
RUN \
    WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
    WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
    wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip \
    && unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard \
    && mkdir -p /dashboard \
    && mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ \
    && rm -rf ${WAHA_DASHBOARD_SHA}.zip \
    && rm -rf /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

#
# GOWS
#
FROM golang:${GOLANG_IMAGE_TAG} AS gows

# jq to parse json
RUN apt-get update && apt-get install -y jq && rm -rf /var/lib/apt/lists/*

# install protoc
RUN apt-get update && \
    apt-get install protobuf-compiler -y

# Image processing for thumbnails
RUN apt-get update  \
    && apt-get install -y libvips-dev \
    && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN \
    GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
    GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    mkdir -p /go/gows/bin && \
    wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
    chmod +x /go/gows/bin/gows

#
# Final
#
FROM node:${NODE_IMAGE_TAG} AS release

# Gunakan mode ringan
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV USE_BROWSER=none
ENV WHATSAPP_DEFAULT_ENGINE=noweb
ENV NODE_OPTIONS="--max-old-space-size=16384"

# Install hanya yang perlu
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libvips \
    curl \
    libc6 \
    tini \
    && rm -rf /var/lib/apt/lists/*

# GOWS
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Set working directory
WORKDIR /app

# Copy file dari build sebelumnya
COPY package.json ./
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows

# Entrypoint dan expose port
COPY entrypoint.sh /entrypoint.sh
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000
ENV WAHA_ZIPPER=ZIPUNZIP

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
