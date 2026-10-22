#!/usr/bin/env bash
# Job-local compiler names; never replace a system compiler or cache a linker.
set -euo pipefail
compiler=${0##*/}
case "$compiler" in cc|c++|gcc|g++) ;; *) exit 2 ;; esac
exec /usr/bin/sccache "/usr/bin/$compiler" "$@"
