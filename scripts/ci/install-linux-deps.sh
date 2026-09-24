#!/usr/bin/env bash
set -euo pipefail
role=${1:?host or client}
source /etc/os-release
case "$role:$ID:$VERSION_ID" in
  host:rocky:9.7)
    test "$(id -u)" = 0
    # Freeze the Rocky minor release rather than following the moving 9 mirror.
    for pair in baseos:BaseOS appstream:AppStream crb:CRB extras:extras; do
      repo=${pair%%:*}; directory=${pair#*:}
      dnf config-manager --save --setopt="$repo.mirrorlist=" \
        --setopt="$repo.baseurl=https://dl.rockylinux.org/vault/rocky/9.7/$directory/\$basearch/os/"
    done
    dnf config-manager --set-enabled crb
    dnf install -y epel-release
    dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo
    dnf install -y --setopt=install_weak_deps=False \
      autoconf automake clang cmake curl-minimal git libtool make nasm ninja-build patch \
      pkgconf-pkg-config ripgrep rpm-build cpio wget xz tar gzip python3 python3-jinja2 \
      gcc-toolset-14-gcc gcc-toolset-14-gcc-c++ \
      cuda-compiler-13-0 cuda-cudart-devel-13-0 cuda-driver-devel-13-0 \
      cuda-nvml-devel-13-0 cuda-nvrtc-devel-13-0 \
      glib2-devel libcap-devel libdrm-devel libevdev-devel libva-devel \
      libX11-devel libxcb-devel libXcomposite-devel libXcursor-devel libXfixes-devel \
      libXi-devel libXinerama-devel libXrandr-devel libXtst-devel libxkbcommon-devel \
      mesa-libgbm-devel mesa-libGL-devel numactl-devel openssl-devel opus-devel \
      pam-devel pipewire-devel pulseaudio-libs-devel python3-devel systemd-devel \
      vulkan-loader-devel wayland-devel wayland-protocols-devel
    /usr/local/cuda/bin/nvcc --version
    python3 -c 'import jinja2' # Fail before the long FFmpeg bootstrap.
    rpm -qa | sort
    ;;
  client:ubuntu:26.04)
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential cmake curl git make nasm ninja-build openssl patch \
      pkg-config python3 python3-venv ripgrep xz-utils dpkg-dev \
      qt6-base-dev qt6-declarative-dev qt6-svg-dev qt6-svg-plugins qt6-wayland \
      libsdl3-dev libsdl3-ttf-dev libpipewire-0.3-dev libdecor-0-dev libdrm-dev libinput-dev \
      libopus-dev libplacebo-dev libssl-dev libudev-dev libva-dev libvdpau-dev \
      libwayland-dev libx11-dev zlib1g-dev
    test "$(qmake6 -query QT_VERSION)" = 6.10.2
    test -f "$(qmake6 -query QT_INSTALL_PLUGINS)/imageformats/libqsvg.so"
    dpkg-query -W
    ;;
  *) echo 'Unsupported CI product/OS tuple' >&2; exit 2 ;;
esac
