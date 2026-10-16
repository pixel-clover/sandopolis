# Our Vendored Version of `zsdl3`

SDL3 Zig bindings from [zig-gamedev/zsdl](https://github.com/zig-gamedev/zsdl) (vendored from commit `100f46b336a112497436144e14877118573e0adf` 
(`v0.4.0-dev`)).

## Why Vendored?

Only this single self-contained file (`sdl3.zig`, imports nothing but `std` and `builtin`) was used from the `zsdl` package. SDL3 itself is built from
source via the `sdl3` (from `castholm/SDL`) dependency.

Upstream zsdl's build script still calls `std.Build.getInstallPath`, which Zig 0.17 removed. Zig compiles the dependency's build script even when
only the binding source is needed. Keeping this file locally avoids that build failure and the package's prebuilt SDL dependencies.

Local Zig 0.17 compatibility changes use `bufPrintSentinel` for C strings and make `Keymod` a non-exhaustive enum so combined modifier bits remain valid.

## Updating

Copy `src/sdl3.zig` from the upstream repo, reapply the compatibility changes, and update the commit hash above.
Replace this copy with a `build.zig.zon` dependency when upstream's build script and bindings support Zig 0.17.
