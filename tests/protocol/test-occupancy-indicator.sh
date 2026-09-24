#!/usr/bin/env bash

set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
host_http="${repo_dir}/apps/host/linux/src/nvhttp.cpp"
client_http="${repo_dir}/apps/client/app/backend/nvhttp.cpp"
client_computer="${repo_dir}/apps/client/app/backend/nvcomputer.cpp"
client_model="${repo_dir}/apps/client/app/gui/computermodel.cpp"
client_view="${repo_dir}/apps/client/app/gui/PcView.qml"

rg -Fq 'tree.put("root.PlankOccupied", occupied ? 1 : 0);' "$host_http"
rg -Fq 'confirmed_desktop_stage() == "user"' "$host_http"
rg -Fq 'config::nvhttp.publish_session_user' "$host_http"
rg -Fq 'tree.put("root.PlankSessionUser", *account);' "$host_http"
rg -Fq 'getXmlString(serverInfo, "PlankOccupied")' "$client_http"
rg -Fq 'getXmlString(serverInfo, "PlankSessionUser")' "$client_http"
rg -Fq 'qsTr("In Session - %1")' "$client_view"
rg -Fq 'NvHTTP::getPlankOccupied(serverInfo)' "$client_computer"
rg -Fq 'names[InSessionRole] = "inSession";' "$client_model"
rg -Fq 'qsTr("In Session")' "$client_view"
rg -Fq 'theme.danger' "$client_view"
rg -Fq '@[@"PlankOccupied", _occupied ? @"1" : @"0"]' \
  "${repo_dir}/apps/host/macos/control/server-information.m"
rg -Fq 'occupied:(phase == PLANKMacScopeDesktop)' \
  "${repo_dir}/apps/host/macos/session/host-main.m"

echo 'occupancy_indicator=pass'
