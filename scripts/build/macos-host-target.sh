#!/usr/bin/env bash
# SDK and runtime floors are independent. The 26.7 candidate is opt-in.
plank_macos_host_target() {
    PLANK_MACOS_HOST_MIN_OS=${PLANK_MACOS_HOST_MIN_OS:-27.0}
    case $PLANK_MACOS_HOST_MIN_OS in
      26.7|27.0) ;;
      *) echo 'Host deployment target must be 27.0 or 26.7' >&2; return 2 ;;
    esac
    [[ $(uname -s) = Darwin && $(uname -m) = arm64 ]] || {
        echo 'Host requires an authorized Apple Silicon development Mac' >&2; return 2;
    }
    local system_version sdk_version major minor required_major required_minor
    system_version=$(sw_vers -productVersion) || return
    sdk_version=$(xcrun --sdk macosx --show-sdk-version) || return
    [[ $system_version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ &&
       $sdk_version =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
        echo 'Cannot determine macOS/SDK version' >&2; return 2;
    }
    major=${system_version%%.*}; minor=${system_version#*.}; minor=${minor%%.*}
    required_major=${PLANK_MACOS_HOST_MIN_OS%%.*}
    required_minor=${PLANK_MACOS_HOST_MIN_OS#*.}
    [[ $major -gt $required_major ||
       ( $major -eq $required_major && $minor -ge $required_minor ) ]] || {
        echo "Host component tests require macOS $PLANK_MACOS_HOST_MIN_OS or newer" >&2; return 2;
    }
    [[ ${sdk_version%%.*} -ge 27 ]] || {
        echo 'Host requires SDK27 or newer, including the 26.7 candidate' >&2; return 2;
    }
    SDKROOT=$(xcrun --sdk macosx --show-sdk-path) || return
    MACOSX_DEPLOYMENT_TARGET=$PLANK_MACOS_HOST_MIN_OS
    export PLANK_MACOS_HOST_MIN_OS MACOSX_DEPLOYMENT_TARGET SDKROOT
}
