#!/usr/bin/env bash
# Dispatch the committed local revision, not an unverified remote branch tip.
set -euo pipefail
product=${1:-all}
signed=${2:-false}
clean_bootstrap=false
case ${3:-} in '') ;; --clean-bootstrap) clean_bootstrap=true;; *) exit 2;; esac
(( $# <= 3 )) || exit 2
case $product in all|linux-host|linux-client|macos-host|macos-client|macos-fullscreen-probe) ;; *) exit 2 ;; esac
case $signed in
  false) ;;
  true) case $product in macos-host|macos-client|macos-fullscreen-probe) ;; *) exit 2;; esac ;;
  *) exit 2 ;;
esac
[[ $product != macos-fullscreen-probe || $signed == true ]] || exit 2
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
test -z "$(git status --porcelain)" || { echo 'Commit the candidate before dispatch.' >&2; exit 1; }
branch=$(git symbolic-ref --quiet --short HEAD)
revision=$(git rev-parse HEAD)
remote=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
test "$remote" = "$revision" || { echo 'Push this exact commit before dispatch.' >&2; exit 1; }
gh workflow run build.yml --ref "$branch" -f "product=$product" -f "source_sha=$revision" -f "signed=$signed" -f "clean_bootstrap=$clean_bootstrap"
