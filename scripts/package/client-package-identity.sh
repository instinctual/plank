#!/usr/bin/env bash

# One Ubuntu Client identity, independent of its Qt session implementation.
plank_client_package_identity() {
  client_package=plank-client
  client_app_name=PLANK
  client_display_name='PLANK Client'
  client_desktop_id=la.instinctual.Plank.Client
  client_lib_name=plank
  client_config=client.conf
  client_log_path=plank/logs
  client_product=client
}

plank_client_require_session_runtime() {
  # The ordinary Linux package must actually contain the Qt session owners.
  # Source/linkage checks complement, not replace, live hardware acceptance.
  local script_dir
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../test" && pwd)
  python3 "$script_dir/check-client-qt-runtime.py" --source "${1:?Client source required}" "${@:2}"
}
