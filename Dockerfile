FROM ghcr.io/ziglang/zig:0.15.2 AS build

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src/ src/
RUN zig build wasm

FROM nginx:alpine

COPY web/index.html web/sandopolis.js web/audio-worklet.js /usr/share/nginx/html/
COPY --from=build /src/zig-out/web/sandopolis.wasm /usr/share/nginx/html/

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
