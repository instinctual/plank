#!/usr/bin/env python3
"""Fail closed on inaccessible Host bundles, staged payloads and actual PKG BOMs."""
import argparse
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tempfile


EXECUTABLES = {"Contents/MacOS/plank-host", "Contents/Resources/uninstall.sh"}
REQUIRED_APP = {
    "Contents", "Contents/MacOS", "Contents/Resources", "Contents/_CodeSignature",
    "Contents/MacOS/plank-host", "Contents/Info.plist", "Contents/Resources/plank.icns",
    "Contents/_CodeSignature/CodeResources",
}
APP = "Applications/PLANK Host.app"
DRIVER = "Library/Audio/Plug-Ins/HAL/PLANK Microphone.driver"


def expected_mode(name, directory, app_only=False):
    if directory:
        return "drwxr-xr-x"
    relative = name if app_only else name.removeprefix(APP + "/")
    return "-rwxr-xr-x" if relative in EXECUTABLES or name == DRIVER + "/Contents/MacOS/plank-microphone" else "-rw-r--r--"


def check_records(records, app_only=False):
    required = {"."} | (REQUIRED_APP if app_only else {
        "Applications", APP, "Library", "Library/LaunchAgents", "Library/LaunchDaemons",
        APP + "/Contents/Resources/uninstall.sh",
        "Library/LaunchDaemons/la.instinctual.PLANK.Host.machine.plist",
        "Library/LaunchAgents/la.instinctual.PLANK.Host.desktop.plist",
        "Library/LaunchAgents/la.instinctual.PLANK.Host.sign-in.plist",
        DRIVER, DRIVER + "/Contents/Info.plist", DRIVER + "/Contents/MacOS/plank-microphone",
        DRIVER + "/Contents/_CodeSignature/CodeResources",
    } | {APP + "/" + name for name in REQUIRED_APP})
    missing = required - records.keys()
    if missing:
        raise ValueError("missing required package entries: " + ", ".join(sorted(missing)))
    for name, mode in records.items():
        if PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
            raise ValueError("unsafe package entry")
        expected = expected_mode(name, mode.startswith("d"), app_only)
        if mode != expected:
            raise ValueError(f"{name}: permissions {mode}, expected {expected}")


def check_tree(root, app_only=False):
    # lstat refuses to treat a symlink as an ordinary file or directory.
    records = {".": stat.filemode(root.lstat().st_mode)}
    for path in root.rglob("*"):
        records[path.relative_to(root).as_posix()] = stat.filemode(path.lstat().st_mode)
    check_records(records, app_only)


def check_bom(text):
    records = {}
    for line in text.splitlines():
        name, mode = line.rsplit("\t", 1)
        name = name.removeprefix("./")
        if name in records:
            raise ValueError("duplicate BOM entry")
        # lsbom's symbolic mode column includes a trailing space on macOS.
        records[name] = mode.strip()
    check_records(records)


def check_package(package):
    with tempfile.TemporaryDirectory(prefix="plank-host-pkg-check-") as scratch:
        expanded = Path(scratch) / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        boms = list(expanded.rglob("Bom"))
        if len(boms) != 1:
            raise ValueError("expected exactly one Host component BOM")
        check_bom(subprocess.check_output(["lsbom", "-p", "fM", str(boms[0])], text=True))
        check_tree(boms[0].parent / "Payload")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--app", type=Path)
    group.add_argument("--payload", type=Path)
    group.add_argument("--pkg", type=Path)
    args = parser.parse_args()
    if args.pkg:
        check_package(args.pkg.resolve())
    else:
        check_tree(args.app or args.payload, app_only=bool(args.app))
    print("macos_host_permissions=pass")


if __name__ == "__main__":
    main()
