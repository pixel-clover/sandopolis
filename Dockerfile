FROM debian:trixie-slim AS build

ARG TARGETARCH
ARG SANDOPOLIS_GIT_BRANCH=unknown
ARG SANDOPOLIS_GIT_HASH=unknown
ARG SANDOPOLIS_BUILD_TIME=unknown

WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    xz-utils \
    jq \
    && rm -rf /var/lib/apt/lists/*

COPY build.zig.zon ./

RUN set -eux; \
    zig_version="$(sed -n 's/.*\.minimum_zig_version = "\(.*\)",/\1/p' build.zig.zon)"; \
    case "${TARGETARCH:-amd64}" in \
        amd64) zig_arch="x86_64" ;; \
        arm64) zig_arch="aarch64" ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fL "https://ziglang.org/download/index.json" -o /tmp/zig-index.json; \
    expected_sha="$(jq -r --arg v "${zig_version}" --arg k "${zig_arch}-linux" '.[$v][$k].shasum' /tmp/zig-index.json)"; \
    if [ -z "${expected_sha}" ] || [ "${expected_sha}" = "null" ]; then \
        echo "Could not find SHA256 for ${zig_arch}-linux Zig ${zig_version} in index" >&2; \
        exit 1; \
    fi; \
    curl -fL "https://ziglang.org/download/${zig_version}/zig-${zig_arch}-linux-${zig_version}.tar.xz" -o /tmp/zig.tar.xz; \
    echo "${expected_sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm -f /tmp/zig.tar.xz /tmp/zig-index.json; \
    ln -s /opt/zig/zig /usr/local/bin/zig

COPY build.zig ./
COPY src/ src/
RUN --mount=type=cache,target=/root/.cache/zig \
    zig build wasm \
    -Dgit-branch="${SANDOPOLIS_GIT_BRANCH}" \
    -Dgit-hash="${SANDOPOLIS_GIT_HASH}" \
    -Dbuild-time="${SANDOPOLIS_BUILD_TIME}"

# Pinned to a specific minor for reproducibility; bump deliberately when needed.
# A SHA digest pin (FROM nginx:1.27-alpine@sha256:...) would be even tighter.
FROM nginx:1.27-alpine

RUN mkdir -p /usr/share/nginx/html/fonts
COPY web/*.html web/*.js /usr/share/nginx/html/
COPY src/frontend/fonts/ttf/JetBrainsMono-*.ttf /usr/share/nginx/html/fonts/
COPY docs/assets/overlays/crt/ /tmp/overlays/crt/
COPY docs/assets/overlays/genesis/ /tmp/overlays/genesis/
RUN set -eux; \
    mkdir -p /usr/share/nginx/html/img; \
    for f in /tmp/overlays/crt/*.png /tmp/overlays/genesis/*.png; do \
        target="/usr/share/nginx/html/img/$(basename "$f")"; \
        if [ -e "$target" ]; then \
            echo "Overlay name collision: $f and existing $target" >&2; \
            exit 1; \
        fi; \
        cp "$f" "$target"; \
    done; \
    rm -rf /tmp/overlays
COPY --from=build /src/zig-out/web/sandopolis.wasm /usr/share/nginx/html/

# Pre-compress static assets so nginx can serve them via gzip_static. Keeps the
# original alongside (-k) so clients without gzip support still work.
RUN find /usr/share/nginx/html -type f \( \
        -name "*.wasm" -o -name "*.js" -o -name "*.html" -o -name "*.ttf" \
    \) -exec gzip -9 -k -f {} \;

# Minimal nginx site config with gzip_static enabled. Replaces the default.
RUN printf '%s\n' \
    'server {' \
    '    listen 80;' \
    '    server_name _;' \
    '    root /usr/share/nginx/html;' \
    '    index index.html;' \
    '    gzip_static on;' \
    '    location / { try_files $uri $uri/ =404; }' \
    '}' > /etc/nginx/conf.d/default.conf

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --spider -q http://localhost/ || exit 1

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
