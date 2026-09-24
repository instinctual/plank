#!/usr/bin/env bash

# Load the public PLANK product version and package-manager-specific metadata.
# The operator-facing patch component is zero-padded from 1.1.001 onward.
# Callers must pass the repository root containing packaging/VERSION.
plank_load_package_version() {
  if (($# != 1)); then
    echo "usage: plank_load_package_version REPOSITORY_ROOT" >&2
    return 2
  fi

  local repository_root=$1
  local version_file="${repository_root}/packaging/VERSION"
  [[ -f $version_file ]] || {
    echo "PLANK version file is unavailable: ${version_file}" >&2
    return 1
  }

  PLANK_BASE_VERSION=$(<"$version_file")
  [[ $PLANK_BASE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "invalid shared package version: ${PLANK_BASE_VERSION}" >&2
    return 1
  }

  local build_branch=${PLANK_BUILD_BRANCH:-}
  if [[ -z $build_branch ]]; then
    build_branch=$(git -C "$repository_root" symbolic-ref --quiet --short HEAD) || {
      echo "detached build requires PLANK_BUILD_BRANCH=main or the feature branch name" >&2
      return 1
    }
  fi
  build_branch=${build_branch#refs/heads/}
  [[ $build_branch =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "invalid PLANK build branch qualifier: ${build_branch}" >&2
    return 1
  }

  PLANK_BUILD_BRANCH_RESOLVED=$build_branch
  PLANK_PACKAGE_VERSION=$PLANK_BASE_VERSION
  PLANK_RPM_VERSION=$PLANK_BASE_VERSION
  PLANK_RPM_RELEASE=1
  if [[ $build_branch != main ]]; then
    PLANK_PACKAGE_VERSION="${PLANK_BASE_VERSION}-${build_branch}"
    # Feature candidates must compare older than the final main RPM for the
    # same base version. RPM Release values cannot contain hyphens.
    PLANK_RPM_RELEASE="0.${build_branch//-/_}.1"
  fi
}

# Collection happens only after the package's existing independent gates pass.
# An explicit artifact root allows builders to collect outside candidate trees.
plank_collect_package() {
  local root=$1 product=$2 platform=$3 architecture=$4 target_os=$5 package=$6
  python3 "$root/scripts/package/collect-package.py" --source-root "$root" \
    --package "$package" --product "$product" --platform "$platform" \
    --architecture "$architecture" --target-os "$target_os" \
    --branch "$PLANK_BUILD_BRANCH_RESOLVED" --validation passed \
    --output-root "${PLANK_ARTIFACT_ROOT:-${PLANK_CANONICAL_ROOT:-$root}/artifacts/packages}"
}
