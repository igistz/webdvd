# --------------------------------------------------
# 1. Build the DVD navigation WebAssembly components
# --------------------------------------------------
FROM emscripten/emsdk:latest AS wasm-builder

WORKDIR /src

COPY . .

RUN chmod +x wasm/build.sh \
    && ./wasm/build.sh


# --------------------------------------------------
# 2. Build the frontend
# --------------------------------------------------
FROM node:22-bookworm-slim AS frontend-builder

WORKDIR /src/player

COPY player/package*.json ./

RUN npm ci --no-audit --no-fund

COPY player/ ./

COPY --from=wasm-builder /src/wasm/build/dvdnav.js ./public/wasm/dvdnav.js
COPY --from=wasm-builder /src/wasm/build/dvdnav.wasm ./public/wasm/dvdnav.wasm

RUN npm run build


# --------------------------------------------------
# 3. Build the Rust backend
# --------------------------------------------------
FROM rust:1-bookworm AS backend-builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       pkg-config \
       libdvdread-dev \
       build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/server

COPY server/ ./

RUN cargo build --release --locked


# --------------------------------------------------
# 4. Runtime image
# --------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       nginx \
       ffmpeg \
       libdvdread8 \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=backend-builder \
    /src/server/target/release/webdvd-server \
    /usr/local/bin/webdvd-server

COPY --from=frontend-builder \
    /src/player/dist/ \
    /usr/share/nginx/html/

# Nginx serves the frontend and forwards API requests to Rust.
RUN printf '%s\n' \
    'server {' \
    '    listen 8080;' \
    '    server_name _;' \
    '    root /usr/share/nginx/html;' \
    '    index index.html;' \
    '    location /api/ {' \
    '        proxy_pass http://127.0.0.1:3000;' \
    '        proxy_http_version 1.1;' \
    '        proxy_buffering off;' \
    '        proxy_read_timeout 4h;' \
    '        proxy_send_timeout 4h;' \
    '    }' \
    '    location / {' \
    '        try_files $uri $uri/ /index.html;' \
    '    }' \
    '}' \
    > /etc/nginx/sites-available/default \
    && rm -f /etc/nginx/sites-enabled/default \
    && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

EXPOSE 8080

# Start the Rust API and then keep Nginx in the foreground.
CMD ["sh", "-c", "/usr/local/bin/webdvd-server /library --port 3000 --cache-dir /cache & exec nginx -g 'daemon off;'"]

