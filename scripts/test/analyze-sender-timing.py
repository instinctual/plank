#!/usr/bin/env python3
"""Summarize the last complete numeric PLANK sender trace (no payload data)."""
import argparse
import json
import statistics
from pathlib import Path


def read_trace(text):
    complete = None
    current = None
    for line in text.splitlines():
        if line.startswith("PLANK sender-timing begin "):
            header = dict(item.split("=", 1) for item in line.split()[3:])
            current = {"header": header, "columns": None, "rows": []}
        elif current is not None and line.startswith("PLANK sender-timing columns="):
            current["columns"] = line.split("=", 1)[1].split(",")
        elif current is not None and line == "PLANK sender-timing end":
            if current["columns"] is None or len(current["rows"]) != int(current["header"]["rows"]):
                raise ValueError("Incomplete or mismatched sender trace")
            complete = current
            current = None
        elif current is not None and line.startswith("PLANK sender-timing "):
            values = list(map(int, line[len("PLANK sender-timing "):].split(",")))
            if current["columns"] is None or len(values) != len(current["columns"]):
                raise ValueError("Sender trace column mismatch")
            current["rows"].append(dict(zip(current["columns"], values)))
    if complete is None:
        raise ValueError("No complete sender trace; disconnect to flush it")
    return complete


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    return {"mean": round(statistics.mean(values), 4),
            "p95": round(values[(95 * (len(values) - 1)) // 100], 4),
            "max": round(values[-1], 4)}


def summarize(trace):
    rows = trace["rows"]
    groups = {}
    for name, selected in (("all", rows), ("key", [r for r in rows if r["key"]]),
                           ("delta", [r for r in rows if not r["key"]])):
        groups[name] = {"frames": len(selected)}
        if not selected:
            continue
        groups[name]["bytes"] = distribution([r["bytes"] for r in selected])
        groups[name]["milliseconds"] = {
            key: distribution([r[key] / 1e6 for r in selected])
            for key in trace["columns"] if key.endswith("_ns") and key != "dequeue_ns"
        }
        groups[name]["totals_ms"] = {
            key: round(sum(r[key] for r in selected) / 1e6, 4)
            for key in ("send_ns", "fec_copy_ns", "fec_encoder_ns", "fec_repair_ns",
                        "quinn_ns")
        }
    return {"header": trace["header"], "groups": groups,
            "wire_bps_values": sorted({r["wire_bps"] for r in rows}),
            "queue_drops_at_last_dequeue": rows[-1]["queue_drops"] if rows else 0,
            "failed_submissions": sum(r["failed"] for r in rows),
            "slowest_frames": sorted(rows, key=lambda r: r["send_ns"], reverse=True)[:12],
            "notes": ["Elapsed wall times, not CPU time or delivery/ACK time.",
                      "FEC total includes Quinn calls; do not sum nested totals.",
                      "Quinn call time includes its lock and submission work; not a pure mutex measurement.",
                      "Queue drops sampled at dequeue; terminal/cancelled frame can be absent."]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(read_trace(args.log.read_text())), indent=2))
