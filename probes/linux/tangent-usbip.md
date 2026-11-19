# Tangent USB/IP compatibility probe

This is an uninstalled qualification tool for the Linux USB/TangentHub boundary.
It is not a PLANK Client or an implemented PLANK forwarding feature. See the
[integration plan](../../docs/development/plans/tangent-panel-forwarding.plan).

`python3 probes/linux/tangent-usbip.py inventory` is read-only. It reports module
availability, candidate panel descriptors and endpoint sizes without device
serials or input reports. Run it without sudo first. Unreadable or removed sysfs
nodes are reported as inspection errors, not silently accepted.

The active `export` and `attach` modes are for an explicitly authorized test.
Both require root, their acknowledgement flag, and binary standard streams
connected over authenticated SSH. Never expose these streams on an open socket.
They deliberately do not run usbipd or listen on TCP port 3240. USB/IP kernel
endpoints use local UNIX stream socket pairs; the source code accepts SOCK_STREAM
but that path still needs installed-kernel qualification.

- `export --bus-id BUS --allow-device-rebind --seconds 120` claims only the
  selected full-speed `04d8:fa1a` device with the verified Mf HID report layout.
  It temporarily rebinds that USB device to usbip-host and restores its original
  USB driver on normal exit, SSH EOF, SIGINT, SIGTERM or a setup exception.
- `attach --device-id ID --allow-virtual-attach --seconds 120` selects an unused
  VHCI USB2 port. `ID` is `(bus_number << 16) | device_number` from the current
  Client inventory; it is not a persistent identity. The socket closes and the
  virtual port detaches at exit. The probe never evicts an existing port.
- Diagnostics and readiness events use stderr. stdout is USB/IP bytes, never
  a terminal. Buffering is bounded to 64 KiB per direction and duration to
  600 seconds maximum. Restore the device before ending a test, and independently
  verify the original driver binding and absence of virtual devices afterward.
- The export-side request filter accepts bounded control/interrupt traffic and
  rejects vendor/firmware requests, inconsistent lengths and isochronous data.
  Raw responses are acceptable here only from the controlled kernel over SSH;
  **this is not sufficient validation for shipping network input**. Product code
  must correlate responses to pending transfers before passing anything to VHCI.
- SIGKILL, machine loss or a kernel fault cannot run Python cleanup. Keep a
  separate privileged session available, record the initial binding and owned
  VHCI port, and restore those exact resources if needed. Do not use a blanket
  USB reset, module unload or system reboot to clean up this probe.

The operator's machine addresses, SSH routing, credentials and exact active-test
commands stay in private deployment notes. This repository contains no public
test target or embedded credentials. Do not ship the probe in product packages.

Portable checks:

```bash
python3 tests/tangent/test_usbip_probe.py
```

These tests check split USB/IP requests, malformed/oversized transfers, prohibited
firmware commands, free-port selection and failure cleanup. They do not establish
TangentHub discovery, application controls, WAN latency or multi-panel support.
