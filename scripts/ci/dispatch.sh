#!/usr/bin/env bash
# Dispatch the committed local revision, not an unverified remote branch tip.
set -euo pipefail
product=${1:-all}
signed=${2:-false}
clean_bootstrap=false
macos_host_min_os=27.0
target_selected=false
for option in "${@:3}"; do
  case $option in
    --clean-bootstrap)
      [[ $clean_bootstrap == false ]] || exit 2
      clean_bootstrap=true ;;
    --macos-host-min-os=*)
      [[ $target_selected == false ]] || exit 2
      target_selected=true
      macos_host_min_os=${option#*=} ;;
    *) exit 2 ;;
  esac
done
case $macos_host_min_os in 27.0|26.7) ;; *) exit 2;; esac
[[ $macos_host_min_os != 26.7 || $product == macos-host ]] || exit 2
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
[[ $macos_host_min_os != 26.7 || $branch != main ]] || {
  echo 'Experimental Host 26.7 builds require a candidate branch.' >&2; exit 2;
}
revision=$(git rev-parse HEAD)
remote=$(git ls-remote origin "refs/heads/$branch" | cut -f1)
test "$remote" = "$revision" || { echo 'Push this exact commit before dispatch.' >&2; exit 1; }
gh workflow run build.yml --ref "$branch" -f "product=$product" -f "source_sha=$revision" -f "signed=$signed" -f "clean_bootstrap=$clean_bootstrap" -f "macos_host_min_os=$macos_host_min_os"
