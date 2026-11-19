#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Bounded Linux Tangent USB/IP compatibility probe; not a product service.

Inventory is read-only and omits serial numbers. Active modes require root,
explicit acknowledgement, and authenticated SSH standard streams. They expose
no network listener and must never be used as a public USB/IP server. Their
purpose is to qualify the kernel/TangentHub boundary before product integration.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time


MF_ID = (0x04D8, 0xFA1A)
MF_DESCRIPTOR = bytes.fromhex(
    "05010908a10105f009017508950f810205f00902750895409102c0")
BUS_ID = re.compile(r"[1-9][0-9]*-[1-9][0-9]*(?:\.[1-9][0-9]*)*")
QUEUE_LIMIT = 64 * 1024
TRANSFER_LIMIT = 4096
HEADER_SIZE = 48
SYSFS = Path("/sys")


def read_text(path):
    return path.read_text().strip()


def read_hex(path):
    return int(read_text(path), 16)


def module_state(name):
    """Check availability without loading a module or changing module policy."""
    try:
        result = subprocess.run(
            ["/usr/sbin/modinfo", "-F", "filename", name],
            capture_output=True, text=True, timeout=5, check=False)
        available = result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        available = False
    return {"available": available,
            "loaded": (SYSFS / "module" / name.replace("-", "_")).exists()}


def inspect_device(device):
    """Return metadata only; do not open USB/hidraw nodes or query the device."""
    vendor = read_hex(device / "idVendor")
    product = read_hex(device / "idProduct")
    name = read_text(device / "product") if (device / "product").exists() else ""
    if (vendor, product) != MF_ID and "tangent" not in name.lower():
        return None
    interfaces = []
    for interface in sorted(device.glob(device.name + ":*")):
        endpoints = []
        for endpoint in sorted(interface.glob("ep_*")):
            endpoints.append({
                "address": read_text(endpoint / "bEndpointAddress"),
                "attributes": read_text(endpoint / "bmAttributes"),
                "max_packet_bytes": read_hex(endpoint / "wMaxPacketSize"),
            })
        descriptors = []
        for descriptor in sorted(interface.glob("*/report_descriptor")):
            data = descriptor.read_bytes()
            descriptors.append({"bytes": len(data),
                                "sha256": hashlib.sha256(data).hexdigest(),
                                "matches_mf": data == MF_DESCRIPTOR})
        interfaces.append({"number": read_hex(interface / "bInterfaceNumber"),
                           "class": read_hex(interface / "bInterfaceClass"),
                           "endpoints": endpoints, "hid_descriptors": descriptors})
    return {"bus_id": device.name, "vendor": f"{vendor:04x}",
            "product": f"{product:04x}", "name": name,
            "bus_number": int(read_text(device / "busnum")),
            "device_number": int(read_text(device / "devnum")),
            "speed_mbps": read_text(device / "speed"), "interfaces": interfaces}


def inventory():
    devices = []
    errors = []
    for device in sorted((SYSFS / "bus/usb/devices").glob("*")):
        if not BUS_ID.fullmatch(device.name):
            continue
        try:
            item = inspect_device(device)
            if item is not None:
                devices.append(item)
        except (OSError, ValueError) as error:
            # Hotplug or restricted sysfs access must not look like acceptance.
            errors.append({"bus_id": device.name, "error": type(error).__name__})
    return {"schema": 1, "kernel": os.uname().release,
            "modules": {name: module_state(name) for name in
                        ("usbip-core", "usbip-host", "vhci-hcd")},
            "devices": devices, "inspection_errors": errors}


class RequestFilter:
    """Bound control/interrupt requests before handing them to the exporter.

    USB/IP responses are trusted only because this *probe* requires authenticated
    SSH to the operator-controlled kernel endpoint. This is not the validation
    boundary for a shipping Host. Product integration must additionally validate
    response lengths against outstanding requests before reaching VHCI.
    """

    def __init__(self, device_id):
        self.device_id = device_id
        self.pending = bytearray()

    def feed(self, data):
        self.pending.extend(data)
        if len(self.pending) > QUEUE_LIMIT:
            raise ValueError("USB/IP request buffer exceeded its bound")
        accepted = bytearray()
        while len(self.pending) >= HEADER_SIZE:
            command, sequence, device, direction, endpoint = struct.unpack_from(
                ">IIIII", self.pending)
            if (command not in (1, 2) or sequence == 0 or device != self.device_id
                    or direction not in (0, 1) or endpoint > 15):
                raise ValueError("invalid USB/IP request header")
            payload_bytes = 0
            if command == 1:
                length = struct.unpack_from(">i", self.pending, 24)[0]
                packets = struct.unpack_from(">i", self.pending, 32)[0]
                if not 0 <= length <= TRANSFER_LIMIT or packets != 0:
                    raise ValueError("unsupported USB/IP transfer size/type")
                if endpoint == 0:
                    request_type = self.pending[40]
                    if (request_type & 0x60) not in (0, 0x20):
                        raise ValueError("vendor/firmware control requests are not allowed")
                    if bool(request_type & 0x80) != bool(direction):
                        raise ValueError("inconsistent control transfer direction")
                    if int.from_bytes(self.pending[46:48], "little") != length:
                        raise ValueError("inconsistent control transfer length")
                if direction == 0:
                    payload_bytes = length
            total = HEADER_SIZE + payload_bytes
            if len(self.pending) < total:
                break
            accepted.extend(self.pending[:total])
            del self.pending[:total]
        return accepted


def select_port(status):
    """Select an unused USB2-compatible port, never detach an existing device."""
    for line in status.splitlines():
        columns = line.split()
        if len(columns) >= 3 and columns[0] == "hs":
            try:
                if int(columns[2]) == 4:  # VDEV_ST_NULL in Linux usbip_common.h
                    return int(columns[1])
            except ValueError:
                continue
    raise RuntimeError("no unused VHCI USB2 port is available")


def write_attribute(path, value):
    try:
        with path.open("w") as output:
            # USB/IP's match_busid_store() preserves a trailing newline as
            # part of the device name. Match the upstream usbip tool's bytes.
            output.write(value)
    except OSError as error:
        raise OSError(error.errno, error.strerror, str(path)) from error


def notice(event, **fields):
    print(json.dumps({"event": event, **fields}), file=sys.stderr, flush=True)


@contextlib.contextmanager
def export_device(bus_id, kernel_socket):
    if not BUS_ID.fullmatch(bus_id):
        raise ValueError("invalid USB bus ID")
    device = SYSFS / "bus/usb/devices" / bus_id
    metadata = inspect_device(device)
    if (metadata is None or
            (metadata["vendor"], metadata["product"]) != ("04d8", "fa1a") or
            len(metadata["interfaces"]) != 1 or
            metadata["interfaces"][0]["class"] != 3 or
            not any(d["matches_mf"] for d in metadata["interfaces"][0]["hid_descriptors"])):
        raise RuntimeError("probe only qualifies the verified Element Mf HID layout")
    original_driver = (device / "driver").resolve(strict=True)
    if original_driver.name != "usb":
        raise RuntimeError("device is already claimed by another USB driver")
    exporter = SYSFS / "bus/usb/drivers/usbip-host"
    if not exporter.is_dir():
        raise RuntimeError("usbip-host must be available and loaded before this probe")
    device_id = (metadata["bus_number"] << 16) | metadata["device_number"]
    if metadata["speed_mbps"] != "12":
        raise RuntimeError("the initial Mf qualification requires USB full speed")
    matched = unbound = exported = False
    try:
        write_attribute(original_driver / "unbind", bus_id)
        unbound = True
        write_attribute(exporter / "match_busid", "add " + bus_id)
        matched = True
        write_attribute(exporter / "bind", bus_id)
        exported = True
        write_attribute(device / "usbip_sockfd", str(kernel_socket.fileno()))
        notice("export-ready", bus_id=bus_id, device_id=device_id, speed=2)
        yield device_id
    finally:
        with contextlib.suppress(OSError):
            kernel_socket.shutdown(socket.SHUT_RDWR)
        # Follow usbip unbind: unbind, mark the match, then rebind. The rebind
        # attribute also retires the kernel's match-table entry; rebinding the
        # ordinary USB driver alone leaves it behind.
        if exported and device.exists():
            with contextlib.suppress(OSError):
                write_attribute(exporter / "unbind", bus_id)
        if matched:
            with contextlib.suppress(OSError):
                write_attribute(exporter / "match_busid", "del " + bus_id)
        if exported and device.exists():
            write_attribute(exporter / "rebind", bus_id)
        if unbound and device.exists():
            try:
                write_attribute(original_driver / "bind", bus_id)
            except OSError:
                # The kernel may have rebound it already; verify rather than hide failure.
                if (device / "driver").resolve() != original_driver:
                    raise
        notice("export-restored", device_present=device.exists())


@contextlib.contextmanager
def attach_device(device_id, speed, kernel_socket):
    controller = SYSFS / "devices/platform/vhci_hcd.0"
    port = select_port(read_text(controller / "status"))
    write_attribute(controller / "attach",
                    f"{port} {kernel_socket.fileno()} {device_id} {speed}")
    try:
        notice("attach-ready", port=port, device_id=device_id)
        yield device_id
    finally:
        with contextlib.suppress(OSError):
            kernel_socket.shutdown(socket.SHUT_RDWR)
        with contextlib.suppress(OSError):
            write_attribute(controller / "detach", str(port))
        notice("attach-closed", port=port)


def bridge(channel, seconds, request_filter):
    """Bound each direction and stop immediately at pipe loss or the deadline."""
    incoming = bytearray()
    outgoing = bytearray()
    input_fd, output_fd = sys.stdin.fileno(), sys.stdout.fileno()
    original = {fd: os.get_blocking(fd) for fd in (input_fd, output_fd)}
    channel.setblocking(False)
    for fd in original:
        os.set_blocking(fd, False)
    counts = {"received_bytes": 0, "sent_bytes": 0}
    end = time.monotonic() + seconds
    try:
        while time.monotonic() < end:
            # No regular files are allowed here: stdin/stdout are SSH pipes.
            with selectors.DefaultSelector() as selector:
                if len(incoming) < QUEUE_LIMIT - TRANSFER_LIMIT - HEADER_SIZE:
                    selector.register(input_fd, selectors.EVENT_READ, "input")
                if outgoing:
                    selector.register(output_fd, selectors.EVENT_WRITE, "output")
                flags = selectors.EVENT_WRITE if incoming else 0
                if len(outgoing) < QUEUE_LIMIT:
                    flags |= selectors.EVENT_READ
                if flags:
                    selector.register(channel, flags, "socket")
                events = selector.select(min(1, max(0, end - time.monotonic())))
            for key, mask in events:
                try:
                    if key.data == "input":
                        data = os.read(input_fd, 4096)
                        if not data:
                            return
                        incoming.extend(request_filter.feed(data) if request_filter else data)
                        counts["received_bytes"] += len(data)
                    elif key.data == "output":
                        sent = os.write(output_fd, outgoing)
                        del outgoing[:sent]
                        counts["sent_bytes"] += sent
                    else:
                        if mask & selectors.EVENT_READ:
                            data = channel.recv(min(4096, QUEUE_LIMIT - len(outgoing)))
                            if not data:
                                return
                            outgoing.extend(data)
                        if mask & selectors.EVENT_WRITE:
                            sent = channel.send(incoming)
                            del incoming[:sent]
                except BlockingIOError:
                    continue
    finally:
        for fd, blocking in original.items():
            os.set_blocking(fd, blocking)
        notice("bridge-stopped", **counts)


def stop(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("inventory", help="read-only metadata, no serial numbers")
    export = sub.add_parser("export", help="temporarily claim the verified Mf; SSH pipes only")
    export.add_argument("--bus-id", required=True)
    export.add_argument("--allow-device-rebind", action="store_true", required=True)
    attach = sub.add_parser("attach", help="temporarily attach a virtual USB panel; SSH pipes only")
    attach.add_argument("--device-id", type=int, required=True)
    attach.add_argument("--speed", type=int, choices=[2], default=2)
    attach.add_argument("--allow-virtual-attach", action="store_true", required=True)
    for command in (export, attach):
        command.add_argument("--seconds", type=int, choices=range(1, 601), default=120,
                             metavar="1..600")
    args = parser.parse_args()
    if args.mode == "inventory":
        print(json.dumps(inventory(), indent=2))
        return 0
    if os.geteuid() != 0:
        parser.error("active probes require root")
    if sys.stdin.isatty() or sys.stdout.isatty():
        parser.error("active probes require authenticated SSH pipes, never a terminal")
    if args.mode == "attach" and not 1 <= args.device_id <= 0xFFFFFFFF:
        parser.error("invalid USB/IP device ID")
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGHUP, stop)
    kernel_socket, channel = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        context = (export_device(args.bus_id, kernel_socket) if args.mode == "export"
                   else attach_device(args.device_id, args.speed, kernel_socket))
        with context as device_id:
            bridge(channel, args.seconds,
                   RequestFilter(device_id) if args.mode == "export" else None)
    except KeyboardInterrupt:
        notice("probe-interrupted")
    except (OSError, ValueError, RuntimeError) as error:
        notice("probe-failed", error=str(error))
        return 1
    finally:
        channel.close()
        kernel_socket.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
