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
