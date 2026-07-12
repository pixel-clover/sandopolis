#!/usr/bin/env python3
"""Framebuffer accuracy check vs the Genesis Plus GX reference core.

Runs the `dump-frames` tool at a set of diagnostic (rom, frame, region)
points, computes the normalized RMSE between Sandopolis's framebuffer and
gpgx's at each point, and reports PASS / FAIL / DRIFT against a recorded
baseline.

Two kinds of case:
  * guard  -- a frame where the two cores should match closely (near the
              color-expansion floor ~0.04).  FAILS if RMSE rises above the
              band: a real rendering regression.
  * gap    -- a frame with a known, unfixed accuracy gap (e.g. the TiTAN
              Overdrive PAL gradient shear).  Not a failure; reported so the
              gap stays visible and any movement (better OR worse) is flagged.

Requires: a built gpgx core (`make reference-core`) and ImageMagick.
Run via `make pal-accuracy`.  Exit code is nonzero iff a guard case fails.
"""

import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OD1 = "tests/testroms/TiTAN - Overdrive (Rev1.1-106-Final) (Hardware).bin"
OD2 = "tests/testroms/titan-overdrive2.bin"

# label, rom, frame, pal, kind, baseline_rmse, tolerance
CASES = [
    ("od1-ntsc-corridor",       OD1,  900, False, "guard", 0.040, 0.020),
    ("od1-pal-titan-gradient",  OD1, 2000, True,  "gap",   0.097, 0.030),
    ("od2-pal-tunnel-desync",   OD2, 1500, True,  "gap",   0.177, 0.050),
    ("od2-pal-starfield-resync", OD2, 2300, True, "guard", 0.034, 0.020),
]


def rmse(ppm_a: str, ppm_b: str) -> float:
    out = subprocess.run(
        ["convert", ppm_a, ppm_b, "-metric", "RMSE", "-compare",
         "-format", "%[distortion]", "info:"],
        capture_output=True, text=True, cwd=REPO,
    )
    return float(out.stdout.strip())


def dump(rom: str, frame: int, pal: bool, prefix: str) -> None:
    args = ["zig", "build", "dump-frames", "-Doptimize=ReleaseFast", "--",
            rom, str(frame)]
    if pal:
        args.append("--pal")
    args += ["--out", prefix]
    r = subprocess.run(args, capture_output=True, text=True, cwd=REPO)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit(f"dump-frames failed for {rom} @ {frame}")


def main() -> int:
    failed = False
    with tempfile.TemporaryDirectory() as tmp:
        print(f"{'case':<28} {'region':<5} {'RMSE':>8} {'base':>7} {'kind':<6} verdict")
        print("-" * 72)
        for label, rom, frame, pal, kind, base, tol in CASES:
            prefix = os.path.join(tmp, label)
            dump(rom, frame, pal, prefix)
            val = rmse(prefix + "_gpgx.ppm", prefix + "_sando.ppm")
            region = "PAL" if pal else "NTSC"
            delta = val - base
            if kind == "guard":
                if val > base + tol:
                    verdict, mark = "FAIL (regressed)", True
                else:
                    verdict, mark = "pass", False
            else:  # gap
                if abs(delta) > tol:
                    verdict = "DRIFT (improved!)" if delta < 0 else "DRIFT (worse)"
                    mark = False  # informational, never fails the build
                else:
                    verdict = "gap (as expected)"
                    mark = False
            failed = failed or mark
            print(f"{label:<28} {region:<5} {val:>8.4f} {base:>7.4f} {kind:<6} {verdict}")
    print("-" * 72)
    print("FAIL: a guard frame regressed." if failed else "OK: all guard frames within band.")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
