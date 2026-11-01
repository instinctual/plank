#!/usr/bin/env bash

set -euo pipefail

if (($# < 1 || $# > 2)); then
  echo "usage: $0 BINARY [PRIVATE_LIBRARY_DIR]" >&2
  exit 2
fi

binary=$(realpath -- "$1")
private_libdir=${2:-}
if [[ ! -x ${binary} ]]; then
  echo "binary is not executable: ${binary}" >&2
  exit 1
fi

for command_name in awk ldd readelf realpath rg; do
  command -v "${command_name}" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

if [[ -n ${private_libdir} ]]; then
  private_libdir=$(realpath -- "$private_libdir")
  [[ -d ${private_libdir} ]] || {
    echo "private library directory is unavailable: ${private_libdir}" >&2
    exit 1
  }
fi

if [[ -n ${private_libdir} ]]; then
  loader_output=$(LD_LIBRARY_PATH="${private_libdir}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}" ldd "$binary")
else
  loader_output=$(ldd "$binary")
fi
printf '%s\n' "$loader_output"
if rg -q '=> not found|^[[:space:]]*not found' <<<"$loader_output"; then
  echo "runtime_dependency_gate=fail" >&2
  exit 1
fi

if [[ -n ${private_libdir} ]]; then
  for soname in libavcodec.so.63 libavutil.so.61 libswresample.so.7; do
    resolved=$(awk -v name="$soname" '$1 == name && $2 == "=>" {print $3}' <<<"$loader_output")
    if [[ -z ${resolved} ]]; then
      echo "required private FFmpeg library is absent from the runtime closure: ${soname}" >&2
      exit 1
    fi
    resolved=$(realpath -- "$resolved")
    case "$resolved" in
      "${private_libdir}"/*) ;;
      *)
        echo "${soname} resolved outside the package library directory: ${resolved}" >&2
        exit 1
        ;;
    esac
  done
  echo "private_ffmpeg_runtime_gate=pass"
fi

echo "direct_dependencies=$(readelf -d "$binary" | rg -c '\(NEEDED\)')"
echo "runtime_dependency_gate=pass"
