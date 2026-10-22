#!/usr/bin/env python3
"""GitHub-hosted orchestration of the Client's pinned, unsigned native recipe."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "apps/client"
RECIPE = CLIENT / "scripts/apple-native/build.py"
TARGETS = {
    "macos": ("macosx", "aarch64-apple-darwin"),
    "device": ("xros", "aarch64-apple-visionos"),
    "simulator": ("xrsimulator", "aarch64-apple-visionos-sim"),
    "ios-device": ("iphoneos", "aarch64-apple-ios"),
    "ios-simulator": ("iphonesimulator", "aarch64-apple-ios-sim"),
}


def bundle_id(target):
    return os.environ["PLANK_NATIVE_IPAD_BUNDLE_ID" if target.startswith("ios-")
                      else "PLANK_NATIVE_BUNDLE_ID"]


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, **kwargs)


def output(args):
    return subprocess.check_output([str(x) for x in args], text=True).strip()


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def branch_name(value):
    branch = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    require(bool(branch) and len(branch) <= 100, "Invalid source branch")
    return branch


def build_number(value):
    require(re.fullmatch(r"[1-9][0-9]{0,3}\.[0-9]{1,2}", value),
            "Run number/attempt exceeds Apple's version fields; advance the version deliberately")
    return value


def runner():
    require(platform.system() == "Darwin" and platform.machine() == "arm64"
            and os.environ.get("GITHUB_ACTIONS") == "true"
            and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "Native automation requires a GitHub-hosted Apple Silicon runner")
    require(sys.version_info >= (3, 12), "Native recipe requires Python 3.12+")


def settings():
    return json.loads((CLIENT / "scripts/apple-native/inputs.json").read_text())


def context(target):
    require(output(["git", "rev-parse", "HEAD"]) == os.environ["EXPECTED_SOURCE_SHA"],
            "Checkout does not match the requested parent SHA")
    require(not output(["git", "status", "--porcelain"]), "Parent source is dirty")
    # Only the native Client and its protocol headers are needed, not Host or Qt prebuilts.
    run(["git", "submodule", "update", "--init", "--", "apps/client"])
    run(["git", "-C", CLIENT, "submodule", "update", "--init", "--",
         "moonlight-common-c/moonlight-common-c"])
    inputs = settings()
    scratch = Path(os.environ["RUNNER_TEMP"]).resolve()
    require(scratch.is_dir(), "Missing runner scratch directory")
    sdk = TARGETS[target][0]
    require(int(output(["xcrun", "--sdk", sdk, "--show-sdk-version"]).split(".")[0]) >= 27,
            "SDK 27+ is required")
    env = {
        "PLANK_NATIVE_WORK": str(scratch / f"plank-native-{target}"),
        "PLANK_NATIVE_DOWNLOADS": str(scratch / "plank-native-downloads"),
        "PLANK_NATIVE_ARTIFACTS": str(scratch / f"plank-native-artifacts-{target}"),
        "PLANK_BUILD_BRANCH": branch_name(os.environ.get("GITHUB_HEAD_REF") or os.environ["GITHUB_REF_NAME"]),
        "RUSTUP_HOME": str(scratch / "plank-native-rustup"),
    }
    build_number(os.environ["PLANK_NATIVE_BUILD"])
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        for key, value in env.items():
            require("\n" not in value and "\r" not in value, "Invalid environment path")
            stream.write(f"{key}={value}\n")
    with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
        stream.write(f"inputs={sha(CLIENT / 'scripts/apple-native/inputs.json')}\n")
        stream.write(f"rust={inputs['toolchain']['rust']}\n")


def recipe(stage, target):
    run([sys.executable, RECIPE, stage, "--platform", target,
         "--work", os.environ["PLANK_NATIVE_WORK"],
         "--cache", os.environ["PLANK_NATIVE_DOWNLOADS"], "--jobs", "3",
         "--configuration", "Release", "--version", os.environ["PLANK_NATIVE_VERSION"],
         "--build-number", build_number(os.environ["PLANK_NATIVE_BUILD"]),
         "--bundle-id", bundle_id(target),
         "--branch", os.environ["PLANK_BUILD_BRANCH"]])


def prepare(target):
    inputs = settings()
    rust = inputs["toolchain"]["rust"]
    triple = TARGETS[target][1]
    run(["rustup", "toolchain", "install", rust, "--profile", "minimal", "--target", triple])
    recipe("prepare", target)


def dependencies(target):
    work = Path(os.environ["PLANK_NATIVE_WORK"])
    recipe("deps", target)
    run(["bash", CLIENT / "scripts/apple-native/test.sh", work / "policy-tests"])
    if target == "macos":
        run(["bash", CLIENT / "scripts/test-macos-native.sh", work / "mac-tests"])
        env = dict(os.environ, PLANK_RELAY_SOURCE_DIR=str(work / "git/raw"),
                   PLANK_MANAGED_RELAY_SOURCE_DIR=str(work / "git/managed"),
                   PLANK_RELAY_SODIUM_PREFIX=str(work / "install"))
        run(["bash", CLIENT / "scripts/test-macos-relay.sh", work / "relay-tests"], env=env)
        run(["bash", CLIENT / "apple-native/Tests/run-pencil-image-checks.sh",
             work, work / "image-tests"])
        run(["bash", CLIENT / "scripts/test-apple-pencil.sh", work, work / "pencil-tests"])
        for directory, name in (
            ("ios-native", "zoom-policy"), ("ios-native", "zoom-input-integration"),
            ("ios-native", "finger-input"), ("ios-native", "automatic-image"),
            ("visionos-native", "pencil-flow-diagnostics"),
        ):
            run([sys.executable, CLIENT / directory / "Tests" / f"run-{name}-checks.py",
                 "--output", work / f"{name}-tests"])


def collect_symbols(archive, generated, name="PLANK"):
    executable = archive / "Products/Applications" / f"{name}.app" / name
    symbols = archive / "dSYMs" / f"{name}.app.dSYM"
    # CMake overrides DWARF_DSYM_FOLDER_PATH to its configuration directory.
    # Xcode therefore generates symbols but does not copy them into .xcarchive.
    if not symbols.exists():
        require(generated.is_dir(), "CMake did not generate the required crash symbols")
        symbols.parent.mkdir(exist_ok=True)
        shutil.copytree(generated, symbols)
    def uuids(path):
        return set(re.findall(r"UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)", output(["dwarfdump", "--uuid", path])))
    expected = uuids(executable)
    require(expected and expected == uuids(symbols), "Archive crash-symbol UUID mismatch")


def build(target):
    inputs = settings()
    work = Path(os.environ["PLANK_NATIVE_WORK"])
    destination = Path(os.environ["PLANK_NATIVE_ARTIFACTS"])
    destination.mkdir()
    recipe("build", target)
    receipt = json.loads((work / "application.json").read_text())
    receipt.update(parent_commit=os.environ["EXPECTED_SOURCE_SHA"], inputs=inputs,
                   version=os.environ["PLANK_NATIVE_VERSION"], bundle_id=bundle_id(target))
    if target in ("device", "ios-device"):
        ipad = target == "ios-device"
        project = "PlankIPad" if ipad else "PlankVision"
        name = "PLANK iPad Pilot" if ipad else "PLANK"
        archive = work / f"{project}.xcarchive"
        env = dict(os.environ, CARGO_HOME=str(work / "cargo"), CARGO_NET_OFFLINE="true",
                   RUSTUP_TOOLCHAIN=inputs["toolchain"]["rust"], CARGO_PROFILE_RELEASE_STRIP="none")
        run(["xcodebuild", "-project", work / "app-build" / f"{project}.xcodeproj", "-scheme", project,
             "-configuration", "Release", "-destination", "generic/platform=" + ("iOS" if ipad else "visionOS"), "-archivePath", archive,
             "archive", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="], env=env)
        require((archive / "Products/Applications" / f"{name}.app" / name).is_file(), "Archive application is absent")
        collect_symbols(archive, work / "app-build" / f"Release-{TARGETS[target][0]}" / f"{name}.app.dSYM", name)
        artifact = destination / f"{project}.xcarchive.tar.gz"
        with tarfile.open(artifact, "w:gz") as stream:
            stream.add(archive, arcname=archive.name)
    else:
        sdk = TARGETS[target][0]
        app = work / "app-build" / ("Release" if target == "macos" else "Release-" + sdk) / (
            "PLANK Native Pilot.app" if target == "macos" else
            "PLANK iPad Pilot.app" if target.startswith("ios-") else "PLANK.app")
        if target == "macos":
            staged = work / "staged/PLANK Native Pilot.app"
            run([sys.executable, CLIENT / "scripts/stage-macos-native.py", "--app", app, "--output", staged,
                 "--ffmpeg-prefix", work / "install", "--ffmpeg-source", work / "source" / inputs["archives"]["ffmpeg"]["directory"],
                 "--opus-license", work / "source" / inputs["archives"]["opus"]["directory"] / "COPYING",
                 "--sodium-license", work / "source" / inputs["archives"]["sodium"]["directory"] / "LICENSE", "--identity", "-"])
            app = staged
        artifact = destination / f"plank-native-{target}-{os.environ['PLANK_NATIVE_VERSION']}-{os.environ['PLANK_BUILD_BRANCH']}-{os.environ['PLANK_NATIVE_BUILD']}-unsigned.zip"
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, artifact])
    receipt["artifact"] = artifact.name
    receipt["artifact_sha256"] = sha(artifact)
    (destination / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
        stream.write(f"### Native {target}\n\nUnsigned Release build and component tests passed. "
                     "No hardware acceptance or production release is implied.\n\n"
                     f"Parent `{receipt['parent_commit']}`; Client `{receipt['client_commit']}`.\n")


if __name__ == "__main__":
    try:
        runner()
        target = os.environ["PLANK_NATIVE_PLATFORM"]
        require(target in TARGETS, "Invalid target")
        {"context": context, "prepare": prepare, "dependencies": dependencies, "build": build}[sys.argv[1]](target)
    except (RuntimeError, subprocess.CalledProcessError, KeyError) as error:
        raise SystemExit(f"Native build stopped: {error}")
