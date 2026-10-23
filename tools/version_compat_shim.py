#!/usr/bin/env python3
import os
import plistlib
import platform
import sys
from pathlib import Path

SUPPORTED = {
    "15.4": "iOS-15.4",
    "16.2": "iOS-16.2",
    "26.0.1": "iOS-26.0.1",
}

def read_version(path: Path):
    with path.open("rb") as f:
        data = plistlib.load(f)
    version = str(data.get("ProductVersion", "")).strip()
    if not version:
        raise ValueError(f"ProductVersion missing in {path}")
    return version

def main():
    requested = os.environ.get("TEST_IOS_VERSION", "").strip()
    plist_path = Path(os.environ.get("TEST_SYSTEM_VERSION_PLIST", "SystemVersion.plist"))

    if requested:
        version = requested
        source = "TEST_IOS_VERSION"
    else:
        version = read_version(plist_path)
        source = str(plist_path)

    profile = SUPPORTED.get(version)
    result = {
        "host": {
            "system": platform.system(),
            "release": platform.release(),
            "machine": platform.machine(),
        },
        "requested_version": version,
        "source": source,
        "supported": profile is not None,
        "profile": profile,
    }

    import json
    print(json.dumps(result, indent=2))

    return 0 if profile else 2

if __name__ == "__main__":
    raise SystemExit(main())
