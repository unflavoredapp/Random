#!/usr/bin/env python3
"""Fetch the pinned IDeviceKit Swift package into ./IDeviceKit (no submodule needed).

AirCore resolves IDeviceKit as a local package. This clones it at the exact
reviewed revision so integrate_devicekit.py's checksum gate passes.
Safe to rerun: an already-correct checkout is left alone.
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KIT = ROOT / "IDeviceKit"
URL = "https://github.com/khcrysalis/IDeviceKit.git"
REVISION = "837cf1e14d4875771dd5ee1b754a4c86215c5db3"


def main():
    if not (KIT / ".git").exists():
        # The CI cache restores IDeviceKit/.build before this runs, so the folder
        # may already exist with only untracked build output in it. Init in place.
        KIT.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q"], cwd=KIT, check=True)
        subprocess.run(["git", "remote", "add", "origin", URL], cwd=KIT, check=True)
    head = subprocess.run(["git", "rev-parse", "--verify", "-q", "HEAD"], cwd=KIT,
                          capture_output=True, text=True).stdout.strip()
    if head != REVISION:
        subprocess.run(["git", "fetch", "-q", "--depth", "1", "origin", REVISION], cwd=KIT, check=True)
        subprocess.run(["git", "checkout", "-q", "--force", REVISION], cwd=KIT, check=True)
    print(f"IDeviceKit @ {REVISION[:10]}")


if __name__ == "__main__":
    main()
