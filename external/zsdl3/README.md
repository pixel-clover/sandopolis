# Our Vendored Version of `zsdl3`

SDL3 Zig bindings from [zig-gamedev/zsdl](https://github.com/zig-gamedev/zsdl) (vendored from commit `100f46b336a112497436144e14877118573e0adf` 
(`v0.4.0-dev`)).

## Why Vendored?

Only this single self-contained file (`sdl3.zig`, imports nothing but `std` and `builtin`) was used from the `zsdl` package. SDL3 itself is built from
source via the `sdl3` (from `castholm/SDL`) dependency.

Depending on the full `zsdl` package pulled its build script into the dependency graph, which lazily fetches prebuilt SDL binaries per target OS and
the pinned `sdl3-prebuilt-x86_64-windows-gnu` tarball fails Zig 0.16's fetch-time validation (its `build.zig.zon` has no `fingerprint` field),
breaking Windows CI on any cold cache.
Vendoring the one file we use removes that tarball from the dependency graph entirely.

## Updating

Copy `src/sdl3.zig` from the upstream repo and update the commit hash above.
