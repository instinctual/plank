#!/usr/bin/env python3
"""GitHub-hosted orchestration of the Client's pinned, unsigned native recipe."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
CLIENT = ROOT / "apps/client"
RECIPE = CLIENT / "scripts/apple-native/build.py"


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
    sdk = {"device": "xros", "simulator": "xrsimulator", "macos": "macosx"}[target]
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
         "--bundle-id", os.environ["PLANK_NATIVE_BUNDLE_ID"],
         "--branch", os.environ["PLANK_BUILD_BRANCH"]])


def prepare(target):
    inputs = settings()
    rust = inputs["toolchain"]["rust"]
    triple = {"device": "aarch64-apple-visionos", "simulator": "aarch64-apple-visionos-sim",
              "macos": "aarch64-apple-darwin"}[target]
    run(["rustup", "toolchain", "install", rust, "--profile", "minimal", "--target", triple])
    recipe("prepare", target)


def dependencies(target):
    work = Path(os.environ["PLANK_NATIVE_WORK"])
    recipe("deps", target)
    run(["bash", CLIENT / "scripts/apple-native/test.sh", work / "policy-tests"])
    if target == "macos":
        run(["bash", CLIENT / "scripts/test-macos-native.sh", work / "mac-tests"])


def build(target):
    inputs = settings()
    work = Path(os.environ["PLANK_NATIVE_WORK"])
    destination = Path(os.environ["PLANK_NATIVE_ARTIFACTS"])
    destination.mkdir()
    recipe("build", target)
    receipt = json.loads((work / "application.json").read_text())
    receipt.update(parent_commit=os.environ["EXPECTED_SOURCE_SHA"], inputs=inputs,
                   version=os.environ["PLANK_NATIVE_VERSION"], bundle_id=os.environ["PLANK_NATIVE_BUNDLE_ID"])
    if target == "device":
        archive = work / "PlankVision.xcarchive"
        env = dict(os.environ, CARGO_HOME=str(work / "cargo"), CARGO_NET_OFFLINE="true",
                   RUSTUP_TOOLCHAIN=inputs["toolchain"]["rust"])
        run(["xcodebuild", "-project", work / "app-build/PlankVision.xcodeproj", "-scheme", "PlankVision",
             "-configuration", "Release", "-destination", "generic/platform=visionOS", "-archivePath", archive,
             "archive", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGN_IDENTITY=", "DEVELOPMENT_TEAM="], env=env)
        require((archive / "Products/Applications/PLANK.app/PLANK").is_file(), "Archive application is absent")
        require(list((archive / "dSYMs").glob("*.dSYM")), "Archive must contain crash symbols")
        artifact = destination / "PlankVision.xcarchive.tar.gz"
        with tarfile.open(artifact, "w:gz") as stream:
            stream.add(archive, arcname=archive.name)
    else:
        sdk = "macosx" if target == "macos" else "xrsimulator"
        app = work / "app-build" / ("Release" if target == "macos" else "Release-" + sdk) / (
            "PLANK Native Pilot.app" if target == "macos" else "PLANK.app")
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
        require(target in ("macos", "device", "simulator"), "Invalid target")
        {"context": context, "prepare": prepare, "dependencies": dependencies, "build": build}[sys.argv[1]](target)
    except (RuntimeError, subprocess.CalledProcessError, KeyError) as error:
        raise SystemExit(f"Native build stopped: {error}")
