FROM debian:trixie-slim AS build

ARG TARGETARCH

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY build.zig.zon ./

RUN set -eux; \
    zig_version="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)",/\1/p' build.zig.zon)"; \
    case "${TARGETARCH:-amd64}" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fL "https://ziglang.org/download/${zig_version}/zig-${zig_arch}-linux-${zig_version}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    ln -s /opt/zig/zig /usr/local/bin/zig

COPY build.zig ./
COPY src/ src/
RUN zig build wasm

FROM nginx:alpine

RUN mkdir -p /usr/share/nginx/html/fonts
COPY web/index.html web/sandopolis.js web/audio-worklet.js /usr/share/nginx/html/
COPY src/frontend/fonts/ttf/JetBrainsMono-*.ttf /usr/share/nginx/html/fonts/
COPY docs/assets/overlays/crt/ docs/assets/overlays/genesis/ /tmp/overlays/
RUN mkdir -p /usr/share/nginx/html/img && cp /tmp/overlays/*.png /usr/share/nginx/html/img/ && rm -rf /tmp/overlays
COPY --from=build /src/zig-out/web/sandopolis.wasm /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
