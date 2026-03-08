{
  description = "Sandopolis: Sega Genesis / Mega Drive emulator development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          linuxRuntimeLibs = with pkgs; [
            alsa-lib
            libpulseaudio
            libxkbcommon
            wayland
            xorg.libX11
            xorg.libXcursor
            xorg.libXi
            xorg.libXext
            xorg.libXrandr
          ];
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs;
              [
                zig
                gnumake
                cmake
                git
                pre-commit
                pkg-config
                clang-tools
                gdb
              ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux linuxRuntimeLibs;

            shellHook =
              pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath linuxRuntimeLibs}:''${LD_LIBRARY_PATH:-}"
              ''
              + ''
                echo "Sandopolis dev shell"
                echo "Common commands:"
                echo "  make build"
                echo "  make test"
                echo "  make help"
                echo "  BUILD_TYPE=ReleaseFast make run ARGS=\"'tests/testroms/titan-overdrive2.bin'\""
              '';
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
