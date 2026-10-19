#!/usr/bin/env bash

# Shared build/package identity. Only the opt-in Ubuntu experiment gets a
# second namespace; the default Client remains byte-for-byte named as before.
plank_client_package_identity() {
  case ${PLANK_CLIENT_VARIANT:-production} in
    production)
      client_package=plank-client
      client_app_name=PLANK
      client_display_name='PLANK Client'
      client_desktop_id=la.instinctual.Plank.Client
      client_lib_name=plank
      client_config=client.conf
      client_log_path=plank/logs
      client_product=client
      client_qmake_config=()
      ;;
    qt)
      client_package=plank-client-qt
      client_app_name='PLANK Client Qt'
      client_display_name='PLANK Client Qt'
      client_desktop_id=la.instinctual.Plank.Client.Qt
      client_lib_name=plank-client-qt
      client_config=client-qt.conf
      client_log_path=plank-client-qt/logs
      client_product=client-qt
      client_qmake_config=(CONFIG+=plank-qt-session)
      ;;
    *) echo 'PLANK_CLIENT_VARIANT must be production or qt' >&2; return 2 ;;
  esac
}

plank_client_require_session_runtime() {
  # Namespace/package scaffolding is deliberately ahead of live-session
  # integration. Do not accidentally ship the ordinary SDL path under the Qt
  # name. Remove this temporary gate only with the Qt session-runtime wiring
  # and its end-to-end candidate tests, not merely a renamed executable.
  if [[ ${PLANK_CLIENT_VARIANT:-production} == qt ]]; then
    echo 'Qt live-session integration is not enabled yet; refusing to package the SDL Client as PLANK Client Qt.' >&2
    echo 'Continue with scripts/test/run-qt-session-tests.sh and the isolated Qt probe.' >&2
    return 1
  fi
}
