#!/usr/bin/env bash

set -euo pipefail

if (($# > 1)); then
  echo "usage: $0 [BUILD_DEPS_BUILD_DIR]" >&2
  exit 2
fi

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
patch_root="${repo_dir}/apps/host/linux/third-party/build-deps/patches"
build_dir=$(realpath -e -- "${1:-${PLANK_HOST_FFMPEG_BUILD:?set PLANK_HOST_FFMPEG_BUILD}}")

for command_name in find git realpath sort; do
  command -v "$command_name" >/dev/null || {
    echo "required command is unavailable: ${command_name}" >&2
    exit 1
  }
done

[[ -d $patch_root ]] || {
  echo "Host dependency patch directory is unavailable: ${patch_root}" >&2
  exit 1
}

# These are product selections, not opportunistic use of whatever an old
# builder cache contains. FFmpeg still prepares the complete pinned source
# tree; only CBS patches belong to the retained Host build.
for option in SVT_AV1 AMF LIBVA VULKAN; do
  grep -Fxq "BUILD_FFMPEG_${option}:BOOL=OFF" "${build_dir}/CMakeCache.txt" || {
    echo "prepared Host FFmpeg must disable BUILD_FFMPEG_${option}; rebuild dependencies" >&2
    exit 1
  }
done
patch_count=0
verify_patch_group() {
  local generated_repo=$1
  local product_patch_dir=$2
  local git_dir
  local patch_file
  local patched_path
  local change_status
  local group_patch_count=0
  local -A expected_paths=()
  local -a actual_paths=()

  [[ -d $generated_repo ]] || {
    echo "generated dependency source is unavailable: ${generated_repo}" >&2
    exit 1
  }
  [[ -d $product_patch_dir ]] || {
    echo "Host dependency patch group is unavailable: ${product_patch_dir}" >&2
    exit 1
  }

  while IFS= read -r -d '' patch_file; do
    if ! git -C "$generated_repo" apply --ignore-whitespace \
        --reverse --check "$patch_file"; then
      echo "prepared Host dependency source is missing or conflicts with patch: ${patch_file}" >&2
      exit 1
    fi
    ((patch_count += 1))
    ((group_patch_count += 1))
    printf 'host_dependency_patch=present:%s\n' \
      "${patch_file#"${patch_root}/"}"
    while IFS= read -r patched_path; do
      [[ -n $patched_path ]] && expected_paths["$patched_path"]=1
    done < <(sed -n -e 's#^+++ b/##p' -e 's#^--- a/##p' "$patch_file")
  done < <(find "$product_patch_dir" -type f -name '*.patch' -print0 | sort -z)

  ((group_patch_count > 0)) || {
    echo "required Host dependency patch group is empty: ${product_patch_dir}" >&2
    exit 1
  }

  git_dir=$(git -C "$generated_repo" rev-parse --absolute-git-dir)
  while IFS= read -r -d '' change_status && IFS= read -r -d '' patched_path; do
    [[ -n $patched_path ]] && actual_paths+=("$patched_path")
  done < <(
    git --git-dir="$git_dir" --work-tree="$generated_repo" \
      diff --no-renames --name-status -z HEAD
  )
  ((${#actual_paths[@]} == ${#expected_paths[@]})) || {
    echo "prepared dependency has an unexpected tracked modification count: ${generated_repo}" >&2
    printf 'expected=%s actual=%s\n' \
      "${#expected_paths[@]}" "${#actual_paths[@]}" >&2
    printf 'actual_modified_path=%q\n' "${actual_paths[@]}" >&2
    exit 1
  }
  for patched_path in "${actual_paths[@]}"; do
    [[ -n ${expected_paths["$patched_path"]+present} ]] || {
      echo "prepared dependency has an untracked product modification: ${generated_repo}/${patched_path}" >&2
      exit 1
    }
  done
  if find "$generated_repo" -type f \( -name '*.orig' -o -name '*.rej' \) \
      -print -quit | grep -q .; then
    echo "prepared Host dependency contains patch backup or reject files: ${generated_repo}" >&2
    exit 1
  fi
  echo "host_dependency_patch_modified_file_gate=pass:${generated_repo#"${build_dir}/"}"
}

verify_patch_group \
  "${build_dir}/FFmpeg/FFmpeg" \
  "${patch_root}/FFmpeg/FFmpeg/cbs"

((patch_count > 0)) || {
  echo "no active Host dependency patches were verified" >&2
  exit 1
}

echo "host_dependency_patch_count=${patch_count}"
echo "host_dependency_patch_source_gate=pass"
