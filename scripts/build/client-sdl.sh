#!/usr/bin/env bash
# Source-only constants shared by bootstrap, package verification and cache.
plank_sdl_version=3.4.2
plank_sdl_sha256=ef39a2e3f9a8a78296c40da701967dd1b0d0d6e267e483863ce70f8a03b4050c
plank_sdl_patch_relative=apps/client/app/deploy/linux/sdl-patches/0001-wayland-detach-the-tablet-cursor-surface.patch

plank_verify_client_sdl() {
    local repo=$1 work=$2 audit
    printf '%s  %s\n' "$plank_sdl_sha256" "$work/SDL3-$plank_sdl_version.tar.gz" |
      sha256sum --check --status || return 1
    audit=$(mktemp -d) || return 1
    # Compare all prepared source, not a marker that can outlive an old patch.
    if ! tar -xzf "$work/SDL3-$plank_sdl_version.tar.gz" -C "$audit" ||
       ! patch --batch --fuzz=0 --no-backup-if-mismatch -d "$audit/SDL3-$plank_sdl_version" -p1 \
           < "$repo/$plank_sdl_patch_relative" >/dev/null ||
       ! diff -qr "$audit/SDL3-$plank_sdl_version" "$work/SDL3-$plank_sdl_version"; then
        find "$audit" -depth -delete
        echo 'Client SDL source differs from the pinned archive plus required patch' >&2
        return 1
    fi
    find "$audit" -depth -delete
    (cd "$work" && sha256sum --check --status prepared.sha256) || return 1
}
