#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
host_launcher=${repo_dir}/packaging/host/linux/bin/plank-host
host_profile=${repo_dir}/packaging/host/linux/config/plank-host.conf
client_policy=${repo_dir}/packaging/client/config/plank-client.conf
client_main=${repo_dir}/apps/client/app/main.cpp
client_path=${repo_dir}/apps/client/app/path.cpp
client_project=${repo_dir}/apps/client/app/app.pro

expect_status() {
  local expected=$1
  shift
  local actual
  set +e
  "$@" >/dev/null 2>&1
  actual=$?
  set -e
  if [[ ${actual} -ne ${expected} ]]; then
    echo "Expected status ${expected}, received ${actual}: $*" >&2
    return 1
  fi
}

expect_status 127 env PLANK_HOST_BINARY=/does/not/exist \
  "${host_launcher}"
expect_status 1 env -u DISPLAY -u XAUTHORITY \
  PLANK_HOST_BINARY=/bin/true "${host_launcher}"
expect_status 1 env DISPLAY=:99 XAUTHORITY=/does/not/exist \
  PLANK_HOST_BINARY=/bin/true \
  PLANK_AUTH_SOCKET=/does/not/exist "${host_launcher}"

if [[ -e ${repo_dir}/packaging/client/linux/bin/plank-client ]]; then
  echo 'Client package still carries an unnecessary launcher wrapper' >&2
  exit 1
fi
grep -Fq '\$$ORIGIN/../lib/plank' "${client_project}" || {
  echo 'Client executable does not define its private relative RUNPATH' >&2
  exit 1
}

grep -Fxq 'sw_vbv_maxrate_percentage = 150' "${host_profile}"
grep -Fxq 'sw_vbv_buffer_frames = 4' "${host_profile}"
grep -Fxq 'mdns_discovery = false' "${host_profile}"
grep -Fxq 'ping_timeout = 10000' "${host_profile}"
if rg -n '^[#[:space:]]*(address_family|bind_address)[[:space:]]*=' "${host_profile}"; then
  echo 'host profile contains removed listener-binding options' >&2
  exit 1
fi
for section in network x264-encoder security discovery; do
  grep -Fxq "[${section}]" "${host_profile}"
done
if grep -Fxq '[software-encoder]' "${host_profile}"; then
  echo 'host profile contains the obsolete generic software-encoder section' >&2
  exit 1
fi
if rg -q '^\[video\]$|^[[:space:]]*(capture|encoder)[[:space:]]*=' "${host_profile}"; then
  echo 'host profile contains removed global video backend selectors' >&2
  exit 1
fi
if rg -q '^[[:space:]]*[A-Z][A-Z0-9_]*=' "${host_profile}"; then
  echo 'host profile contains shell environment syntax instead of INI syntax' >&2
  exit 1
fi
grep -Fxq '[network]' "${client_policy}"
grep -Fxq '# mdns_discovery = false' "${client_policy}"
grep -Fxq 'port = 28989' "${client_policy}"
if rg -q '^[[:space:]]*mdns_discovery[[:space:]]*=' "${client_policy}"; then
  echo 'Packaged client policy locks mDNS instead of leaving it user-configurable' >&2
  exit 1
fi

for required_log_token in XDG_STATE_HOME '.local/state' 'plank/logs'; do
  rg -Fq "${required_log_token}" "${client_path}"
done
for required_log_token in \
  'plank-client-*.log' \
  'MAX_LOG_SIZE_BYTES (10 * 1024 * 1024)' \
  'QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner' \
  'QFileDevice::ReadOwner | QFileDevice::WriteOwner' \
  's_LoggerFileStream << message' \
  'toOffsetFromUtc(localTime.offsetFromUtc()).toString(Qt::ISODateWithMs)' \
  '#if !defined(LOG_TO_FILE)' \
  'Persistent client log:'; do
  rg -Fq "${required_log_token}" "${client_main}"
done
