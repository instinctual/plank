#!/usr/bin/env python3
"""Test the real exporter through Telegraf, using only temporary local output.

--download-test-agent fetches one checksum-pinned Linux test binary, never
installs a package/service or reads production Telegraf/InfluxDB configuration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
VERSION = "1.40.3"
SHA256 = "cbb95c43303db6e75e129a4eb8888ab1468009e61f6615e64a1cb82f50b0f4ce"


def test_agent():
    folder = ROOT / "build/metrics-telegraf/telegraf"
    folder.mkdir(parents=True, exist_ok=True)
    archive = folder / "telegraf.tar.gz"
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        subprocess.run(["curl", "--fail", "--silent", "--show-error", "--max-time", "120",
                        "-o", str(archive),
                        f"https://dl.influxdata.com/telegraf/releases/telegraf-{VERSION}_linux_amd64.tar.gz"], check=True)
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == SHA256, "Telegraf checksum mismatch"
    binary = folder / "telegraf"
    with tarfile.open(archive) as source:
        members = [m for m in source.getmembers() if m.isfile() and m.name.endswith("/usr/bin/telegraf")]
        assert len(members) == 1
        binary.write_bytes(source.extractfile(members[0]).read())
    binary.chmod(0o755)
    return str(binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--telegraf", default=os.environ.get("TELEGRAF"))
    parser.add_argument("--download-test-agent", action="store_true")
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    binary = test_agent() if args.download_test_agent else args.telegraf or shutil.which("telegraf")
    if not binary:
        parser.error("supply --telegraf or --download-test-agent; no system service is modified")
    with tempfile.TemporaryDirectory(prefix="plank-metrics-") as temporary:
        folder = Path(temporary)
        fixture, output, logfile = folder / "source.lp", folder / "received.json", folder / "agent.log"
        env = dict(os.environ, PLANK_METRICS_FIXTURE_OUTPUT=str(fixture))
        command = ["cargo", "test", "--locked", "--offline", "--manifest-path",
                   str(ROOT / "protocol/plank-transport/Cargo.toml"), "--lib"]
        if args.release:
            command += ["--release"]
        command += ["metrics::tests::telegraf_fixture_serialization", "--", "--exact"]
        result = subprocess.run(command, env=env, check=True, capture_output=True, text=True)
        assert "1 passed" in result.stdout and fixture.exists(), "required fixture did not run"
        lines = fixture.read_bytes().splitlines()
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        template = (ROOT / "packaging/metrics/inputs.plank.conf").read_text()
        template = template.replace("127.0.0.1:28991", f"127.0.0.1:{port}")
        config = folder / "agent.conf"
        config.write_text('[agent]\n interval="1s"\n flush_interval="100ms"\n flush_jitter="0s"\n'
                          ' hostname="test-agent"\n omit_hostname=false\n' + template +
                          '\n[[outputs.file]]\n files=[' + json.dumps(str(output)) + ']\n data_format="json"\n')
        with logfile.open("w") as log:
            agent = subprocess.Popen([binary, "--config", str(config)], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 15
            while "Listening on" not in logfile.read_text():
                assert agent.poll() is None, logfile.read_text()
                assert time.monotonic() < deadline, "Telegraf did not start its isolated listener"
                time.sleep(0.05)
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                for line in lines:
                    sender.sendto(line, ("127.0.0.1", port))
            records = []
            while len(records) < len(lines):
                assert agent.poll() is None, logfile.read_text()
                assert time.monotonic() < deadline, logfile.read_text()
                if output.exists():
                    records = [json.loads(line) for line in output.read_text().splitlines() if line.strip()]
                time.sleep(0.05)
            assert len(records) == len(lines)
            assert {r["name"] for r in records} == {"plank_transport", "plank_client_video", "plank_session"}
            assert all(r["tags"]["host"] == "test-agent" for r in records)
            assert all(r["tags"]["workstation_id"] == "workstation-test" for r in records)
            assert all(r["timestamp"] > 1_700_000_000 for r in records)
            host = next(r["fields"] for r in records if "host_processing_mean_ms" in r["fields"])
            assert host["video_send_mbps"] == 150 and host["video_send_fps"] == 60
            assert host["capture_source"] == "native x11,=\\ test"
            assert host["host_processing_mean_ms"] == 3 and host["host_processing_max_ms"] == 3.5
            media = next(r["fields"] for r in records if r["name"] == "plank_client_video")
            assert media["hardware_decoder"] is True and media["decode_ms"] == 2
            assert "E!" not in logfile.read_text(), logfile.read_text()
            print(f"PASS: {len(records)} real PLANK datagrams parsed by Telegraf; no database writes")
        finally:
            agent.terminate()
            try:
                agent.wait(timeout=5)
            except subprocess.TimeoutExpired:
                agent.kill()
                agent.wait()


if __name__ == "__main__":
    main()
