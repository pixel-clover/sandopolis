<div align="center">
  <picture>
    <img alt="Sandopolis Logo" src="logo.svg" height="25%" width="25%">
  </picture>
<br>

<h2>Sandopolis</h2>

[![Tests](https://img.shields.io/github/actions/workflow/status/pixel-clover/sandopolis/tests.yml?label=tests&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/actions/workflows/tests.yml)
[![Docs](https://img.shields.io/badge/docs-read-blue?style=flat&labelColor=282c34&logo=read-the-docs)](https://pixel-clover.github.io/sandopolis/)
[![License](https://img.shields.io/badge/license-MIT-007ec6?label=license&style=flat&labelColor=282c34&logo=open-source-initiative)](https://github.com/pixel-clover/sandopolis/blob/main/LICENSE)
[![Zig Version](https://img.shields.io/badge/Zig-0.15.2-orange?logo=zig&labelColor=282c34)](https://ziglang.org/download/)
[![Release](https://img.shields.io/github/release/pixel-clover/sandopolis.svg?label=release&style=flat&labelColor=282c34&logo=github)](https://github.com/pixel-clover/sandopolis/releases/latest)

A Sega Genesis/Mega Drive emulator written in Zig and C

</div>

---

Footage of Sandopolis running a few games:

<div align="center">

<table>
  <tr>
    <td align="center"><img alt="SK demo" src="docs/assets/gif/003_sk_optimized.gif" height="500"><br>Sonic &amp; Knuckles</td>
    <td align="center"><img alt="ROS demo" src="docs/assets/gif/002_ros_optimized.gif" height="500"><br>The Revenge of Shinobi</td>
  </tr>
  <tr>
    <td align="center"><img alt="GA2 demo" src="docs/assets/gif/001_ga2_optimized.gif" height="500"><br>Golden Axe II</td>
    <td align="center"><img alt="SOR demo" src="docs/assets/gif/004_sor_optimized.gif" height="500"><br>Streets of Rage</td>
  </tr>
</table>

</div>

### Key Features

- Accurate Sega Genesis/Mega Drive emulation
- Very portable; can be built and run on any platform that Zig supports including WASM
- Configurable gameplay input, frontend hotkeys, and rendering settings
- Supports ROM loading at runtime, recent-ROM history, a save-state manager, quick state save/load, persistent state slots, and keyboard rebinding
- Has a permissive license that allows commercial use

See [ROADMAP.md](ROADMAP.md) for the list of implemented and planned features.

> [!IMPORTANT]
> This project is still in early development, so compatibility is not perfect.
> Bugs and breaking changes are also expected.
> Please use the [issues page](https://github.com/pixel-clover/sandopolis/issues) to report bugs or request features.

---

### Quickstart

#### Download the latest release

You can download the latest pre-build binaries from the project's [releases page](https://github.com/pixel-clover/sandopolis/releases).

#### Build Sandopolis from source

Alternatively, you can build the emulator from source by following the steps below.

##### 1. Clone the repository

```bash
git clone --depth=1 https://github.com/pixel-clover/sandopolis.git
cd sandopolis
```

> [!NOTE]
> If you want to run the tests and develop Sandopolis further, you may want to clone the repository with
> `git clone --recursive https://github.com/pixel-clover/sandopolis.git`.
> Note that you also need to have `git-lfs` installed to download some of the files like test ROMs. 

##### 2. Build the Sandopolis binary

```bash
zig build -Doptimize=ReleaseFast
```

##### 3. Run the emulator with a ROM

```bash
# Start the emulator with a ROM
./zig-out/bin/sandopolis <path-to-rom>
```

If the default SDL renderer is unstable on your system, try:

```bash
./zig-out/bin/sandopolis --renderer software <path-to-rom>
```

Sandopolis now auto-selects PAL/NTSC timing and the console region bits from the ROM header when the region is clear. You can still override timing manually:

```bash
./zig-out/bin/sandopolis --pal <path-to-rom>
./zig-out/bin/sandopolis --ntsc <path-to-rom>
```

Useful frontend hotkeys:

- `F3`: open ROM dialog
- `Shift+F3`: soft reset console
- `Ctrl+Shift+F3`: hard reset and reload current ROM

If you launch Sandopolis without a ROM, it now starts in a frontend home screen with `Open ROM`, recent-ROM entries, settings, help, and quit actions. Frontend actions such as save/load state, recording, fullscreen, and ROM loads also show short on-screen status toasts. Persistent states also have a modal save manager: pause, press `Enter`, then use `Up`/`Down` to pick a slot, `F8` to save, `Enter` or `F9` to load, and `Delete` to remove a slot. Each persistent slot also writes a small `.preview` sidecar and the save manager shows the captured screenshot for the selected slot. The frontend is gamepad-driven too: `Guide` opens or closes the pause flow, the home screen and save manager accept `D-pad` navigation plus `A`/`Start` confirm, and the save manager maps `X` to save and `Y` to delete. There is also a settings modal for runtime-safe frontend controls such as aspect mode, integer scaling, fullscreen, audio render mode, and the performance HUD. Recent ROM history, the last-open directory, and frontend video settings are stored in `sandopolis_frontend.cfg` (or the path from `SANDOPOLIS_FRONTEND_CONFIG`).

> [!NOTE]
> To build from source, you mainly need to have Zig and Git installed.
> The current version of the emulator is developed and tested using Zig 0.15.2.

---

### Documentation

Project documentation is available [here](https://pixel-clover.github.io/sandopolis/).

---

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to make a contribution.

### Acknowledgements

* The logo is from [SVG Repo](https://www.svgrepo.com/svg/519365/sonic-runners) with some modifications.
* This project uses material from the following projects and resources:
    * [Minish](https://github.com/CogitatorTech/minish) framework for property-based testing
    * [Rocket 68](https://github.com/habedi/rocket68) for the main CPU emulation
    * [jgz80](https://github.com/carmiker/jgz80) for the Z80 chip emulation
    * [SDL3](https://www.libsdl.org/) for the emulator frontend (rendering and input; via [zsdl](https://github.com/zig-gamedev/zsdl) and [SDL](https://github.com/castholm/SDL))
    * [Test ROMs](https://techdocs.exodusemulator.com/Console/SegaMegaDrive/Software.html#test-roms)
    * [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2)

> [!IMPORTANT]
> Nuked-OPN2 is mainly used for testing the output of the Zig YM2612 implementation.
> The code is not directly included in the project because its license (LGPL 2.1) is incompatible with the project's license.

#### Reference Implementations

Sandopolis implementation logic was checked with the following emulators for findings errors and verifying correctness:

* [Genesis-Plus-GX](https://github.com/ekeeke/Genesis-Plus-GX)
* [clownmdemu-core](https://github.com/Clownacy/clownmdemu-core)
* [kiwi](https://github.com/drx/kiwi)
* [jgenesis](https://github.com/jsgroth/jgenesis/tree/master/backend/genesis-core)

### License

This project is licensed under the MIT License (see [LICENSE](LICENSE)).
