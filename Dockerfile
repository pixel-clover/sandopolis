FROM ghcr.io/ziglang/zig:0.15.2 AS build

WORKDIR /src
COPY build.zig build.zig.zon ./
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
