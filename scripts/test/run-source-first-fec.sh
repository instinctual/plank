#!/usr/bin/env bash
# Check the production source iterator against the exact linked RaptorQ.
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
target_dir=${1:?Usage: run-source-first-fec.sh CARGO_TARGET_DIR}
fec_rlibs=("$target_dir"/release/deps/libraptorq-*.rlib)
if [[ ${#fec_rlibs[@]} != 1 || ! -f ${fec_rlibs[0]} ]]; then
    echo 'Expected one exact RaptorQ library in the release target directory.' >&2
    exit 1
fi
rustc --edition=2024 --test -O "$repo_root/tests/protocol/source-first-fec.rs" \
    -L "dependency=$target_dir/release/deps" --extern "raptorq=${fec_rlibs[0]}" \
    -o "$target_dir/source-first-test"
"$target_dir/source-first-test" --nocapture --test-threads=1
