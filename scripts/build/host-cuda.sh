#!/usr/bin/env bash
# Shared Linux Host build-tool policy; these packages do not install a GPU driver.
# CUDA 13.2 Update 2 uses compiler/runtime component version 13.2.86.
PLANK_HOST_CUDA_PACKAGES=(
  cuda-compiler-13-2-13.2.2-1
  cuda-crt-13-2-13.2.86-1
  cuda-cuobjdump-13-2-13.2.86-1
  cuda-cuxxfilt-13-2-13.2.86-1
  cuda-nvcc-13-2-13.2.86-1
  cuda-nvprune-13-2-13.2.86-1
  cuda-tileiras-13-2-13.2.86-1
  libnvptxcompiler-13-2-13.2.86-1
  libnvvm-13-2-13.2.86-1
  cuda-cccl-13-2-13.2.86-1
  cuda-cudart-13-2-13.2.86-1
  cuda-cudart-devel-13-2-13.2.86-1
  cuda-culibos-devel-13-2-13.2.86-1
  cuda-driver-devel-13-2-13.2.86-1
  cuda-nvml-devel-13-2-13.2.86-1
  cuda-nvrtc-13-2-13.2.86-1
  cuda-nvrtc-devel-13-2-13.2.86-1
)

plank_verify_host_cuda() {
  local compiler=${1:-/usr/local/cuda/bin/nvcc}
  local version package installed
  if ! version=$("$compiler" --version); then
    echo 'CUDA compiler is unavailable' >&2
    return 1
  fi
  if ! grep -Eq '^Cuda compilation tools, release 13\.2, V13\.2\.86$' <<< "$version"; then
    echo 'Linux Host requires CUDA 13.2 Update 2 (NVCC 13.2.86)' >&2
    return 1
  fi
  for package in "${PLANK_HOST_CUDA_PACKAGES[@]}"; do
    if ! installed=$(rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}' "${package%-*-*}") ||
        [[ $installed != "$package" ]]; then
      echo "CUDA build component does not match the pinned version: $package" >&2
      return 1
    fi
  done
  echo 'host_cuda_toolchain_gate=pass toolkit=13.2.2 nvcc=13.2.86'
}
