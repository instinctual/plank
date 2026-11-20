#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Portable safety/fragmentation checks for the non-shipping hardware probe."""
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("tangent_probe", ROOT / "probes/linux/tangent-usbip.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
DEVICE_ID = 0x00010002


def submit(sequence=1, direction=1, endpoint=1, length=15, setup=None):
    header = struct.pack(">IIIII Iiiii", 1, sequence, DEVICE_ID, direction, endpoint,
                         0, length, 0, 0, 0)
    return header + (setup or bytes(8))


class RequestTests(unittest.TestCase):
    def test_every_fragment_boundary_preserves_reports(self):
        incoming = submit() + submit(sequence=2, direction=0, length=64) + bytes(range(64))
        for split in range(len(incoming) + 1):
            parser = probe.RequestFilter(DEVICE_ID)
            output = parser.feed(incoming[:split]) + parser.feed(incoming[split:])
            self.assertEqual(output, incoming)
            self.assertFalse(parser.pending)

    def test_one_byte_fragments_and_consecutive_control_requests(self):
        # GET_DESCRIPTOR(device), SET_CONFIGURATION(1), then interrupt IN.
        wire = (submit(endpoint=0, length=18, setup=bytes.fromhex("8006000100001200"))
                + submit(sequence=2, endpoint=0, direction=0, length=0,
                         setup=bytes.fromhex("0009010000000000")) + submit(sequence=3))
        parser = probe.RequestFilter(DEVICE_ID)
        self.assertEqual(b"".join(parser.feed(bytes([b])) for b in wire), wire)

    def test_reject_firmware_commands_before_any_bytes_reach_kernel(self):
        wire = submit(endpoint=0, direction=0, length=0,
                      setup=bytes.fromhex("4054000031580000"))
        with self.assertRaisesRegex(ValueError, "firmware"):
            probe.RequestFilter(DEVICE_ID).feed(wire)

    def test_lengths_and_isochronous_transfers_are_bounded(self):
        for length in (-1, 4097, 0x7FFFFFFF):
            with self.assertRaisesRegex(ValueError, "size/type"):
                probe.RequestFilter(DEVICE_ID).feed(submit(length=length))
        wire = bytearray(submit())
        struct.pack_into(">i", wire, 32, 100)
        with self.assertRaisesRegex(ValueError, "size/type"):
            probe.RequestFilter(DEVICE_ID).feed(wire)

    def test_header_identity_and_control_consistency(self):
        for offset, value in ((0, 3), (4, 0), (8, DEVICE_ID + 1), (12, 2), (16, 16)):
            wire = bytearray(submit())
            struct.pack_into(">I", wire, offset, value)
            with self.assertRaises(ValueError):
                probe.RequestFilter(DEVICE_ID).feed(wire)
        for setup in ("0006000100001200", "800600010000ff7f"):
            with self.assertRaises(ValueError):
                probe.RequestFilter(DEVICE_ID).feed(
                    submit(endpoint=0, length=18, setup=bytes.fromhex(setup)))

    def test_unlink_and_bounded_backlog(self):
        unlink = struct.pack(">IIIIII", 2, 2, DEVICE_ID, 0, 0, 1) + bytes(24)
        self.assertEqual(probe.RequestFilter(DEVICE_ID).feed(unlink), unlink)
        with self.assertRaisesRegex(ValueError, "buffer"):
            probe.RequestFilter(DEVICE_ID).feed(bytes(probe.QUEUE_LIMIT + 1))


class InventoryTests(unittest.TestCase):
    def test_sysfs_bus_identifier_has_no_trailing_newline(self):
        with tempfile.TemporaryDirectory() as directory:
            attribute = Path(directory) / "match_busid"
            probe.write_attribute(attribute, "add 1-4")
            self.assertEqual(attribute.read_bytes(), b"add 1-4")

    def test_select_only_unused_usb2_port(self):
        status = "hub port sta spd dev sockfd local_busid\n"
        status += "hs 0000 006 002 00010002 10 1-1\nss 0008 004 000 0 0 0-0\n"
        with self.assertRaises(RuntimeError):
            probe.select_port(status)
        self.assertEqual(probe.select_port(status + "hs 0001 004 000 0 0 0-0\n"), 1)

    def test_metadata_matches_mf_without_serial_or_other_devices(self):
        with tempfile.TemporaryDirectory() as directory:
            device = Path(directory) / "1-4"
            interface = device / "1-4:1.0"
            hid = interface / "0003:04D8:FA1A.0001"
            hid.mkdir(parents=True)
            fields = {"idVendor": "04d8", "idProduct": "fa1a",
                      "product": "KnobX1 Element-Mf transport", "busnum": "1",
                      "devnum": "2", "speed": "12", "serial": "DO-NOT-EXPORT"}
            for name, value in fields.items():
                (device / name).write_text(value)
            (interface / "bInterfaceNumber").write_text("00")
            (interface / "bInterfaceClass").write_text("03")
            (hid / "report_descriptor").write_bytes(probe.MF_DESCRIPTOR)
            data = probe.inspect_device(device)
            self.assertNotIn("DO-NOT-EXPORT", str(data))
            self.assertTrue(data["interfaces"][0]["hid_descriptors"][0]["matches_mf"])
            for product, model in [("fa1c","Tk"),("fa1e","Kb"),("fa1f","Bt")]:
                (device / "idProduct").write_text(product)
                (device / "product").write_text("element-" + model)
                self.assertEqual(probe.inspect_device(device)["product"], product)
            (device / "idProduct").write_text("1234")
            (device / "product").write_text("Unrelated USB device")
            self.assertIsNone(probe.inspect_device(device))

    def test_import_failure_never_detaches_someone_elses_port(self):
        with patch.object(probe, "read_text", return_value="hs 0002 004 0 0 0 0-0"), \
                patch.object(probe, "write_attribute", side_effect=OSError("busy")) as write:
            with self.assertRaises(OSError):
                with probe.attach_device(DEVICE_ID, 2, type("Socket", (), {"fileno": lambda _: 42})()):
                    self.fail("failed attachment must not enter the context")
            self.assertEqual(write.call_count, 1)
            self.assertEqual(write.call_args.args[0].name, "attach")

    def test_completed_import_closes_only_its_socket(self):
        channel = Mock()
        channel.fileno.return_value = 42
        with patch.object(probe, "read_text", return_value="hs 0002 004 0 0 0-0"), \
                patch.object(probe, "write_attribute") as write, patch.object(probe, "notice"):
            with probe.attach_device(DEVICE_ID, 2, channel):
                pass
        channel.shutdown.assert_called_once()
        self.assertEqual([c.args[0].name for c in write.call_args_list], ["attach"])

    def test_export_restores_original_driver_after_partial_setup_failure(self):
        metadata = {"vendor": "04d8", "product": "fa1a", "bus_number": 1,
                    "device_number": 2, "speed_mbps": "12",
                    "interfaces": [{"class": 3, "hid_descriptors": [{"matches_mf": True}]}]}
        for fail_on in ("export-bind", "socket", None):
            with self.subTest(fail_on=fail_on), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                device = root / "bus/usb/devices/1-4"
                original = root / "bus/usb/drivers/usb"
                exporter = root / "bus/usb/drivers/usbip-host"
                for path in (device, original, exporter):
                    path.mkdir(parents=True)
                (device / "driver").symlink_to(original, target_is_directory=True)
                writes = []

                def write(path, value):
                    writes.append((path, value))
                    if ((fail_on == "export-bind" and path == exporter / "bind") or
                            (fail_on == "socket" and path.name == "usbip_sockfd")):
                        raise OSError("injected setup failure")

                channel = Mock()
                channel.fileno.return_value = 42
                with patch.object(probe, "SYSFS", root), \
                        patch.object(probe, "inspect_device", return_value=metadata), \
                        patch.object(probe, "write_attribute", side_effect=write), \
                        patch.object(probe, "notice"):
                    if fail_on:
                        with self.assertRaises(OSError):
                            with probe.export_device("1-4", channel):
                                self.fail("failed setup must not enter the context")
                    else:
                        with probe.export_device("1-4", channel) as device_id:
                            self.assertEqual(device_id, DEVICE_ID)
                self.assertIn((exporter / "match_busid", "del 1-4"), writes)
                self.assertEqual(writes[-1], (original / "bind", "1-4"))
                if fail_on != "export-bind":
                    self.assertLess(writes.index((exporter / "unbind", "1-4")),
                                    writes.index((exporter / "match_busid", "del 1-4")))
                    self.assertIn((exporter / "rebind", "1-4"), writes)
                channel.shutdown.assert_called_once()

    def test_reject_bus_path_traversal_before_any_sysfs_access(self):
        for bus_id in ("../1-4", "/sys/bus/usb/devices/1-4", "1-4\n1-3", "1-4:1.0"):
            with self.assertRaises(ValueError), patch.object(probe, "inspect_device") as inspect:
                with probe.export_device(bus_id, Mock()):
                    self.fail("invalid selection")
            inspect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
