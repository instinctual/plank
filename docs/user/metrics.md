# PLANK metrics with Telegraf, InfluxDB 2 and Grafana

PLANK can send application statistics to an existing local Telegraf agent.
Telegraf's built-in `inputs.socket_listener` parses Influx line protocol and its
existing `outputs.influxdb_v2` handles authenticated delivery and buffering.
There is no database library, token, HTTP request or remote metrics listener
inside PLANK. The feature is disabled by default on every platform.

## Enable collection

1. Install/run Telegraf separately on each machine to be monitored. Linux Hosts
   and Clients can reuse their existing agent and system metrics. Macs need their
   own agent; the PLANK installer does not install or start Telegraf.
2. Add [inputs.plank.conf](../../packaging/metrics/inputs.plank.conf) to that
   agent's configuration directory and restart Telegraf. Configure its InfluxDB
   output for the intended metrics bucket, using a bucket-scoped write token.
   Reuse an existing output if it already points there; do not add a duplicate.
   Keep `omit_hostname = false` so Telegraf adds the local `host` tag.
3. Enable PLANK collection in `/etc/plank/host.conf` and/or
   `/etc/plank/client.conf`, then restart that product:

   ```ini
   [metrics]
   metrics_enabled = true
   metrics_port = 28991
   metrics_interval_seconds = 1
   ```

The three keys and full comments ship in all configuration templates. Client
upgrades add missing defaults/comments without replacing administrator values.
Host upgrades preserve custom configuration; add this section when enabling it.
The destination is always IPv4 `127.0.0.1`. The allowed port range is 1024–65535;
the interval is 1–60 whole seconds. Match the port in Telegraf. One listener can
receive from both products and from multiple Client sessions on that machine.
No firewall opening or special capability is needed. Invalid optional metrics
values disable collection without preventing a session.

If system metrics already go to a different bucket, retain that destination.
Add a separate `outputs.influxdb_v2` using the application-metrics destination
and `namepass = ["plank_transport", "plank_client_video", "plank_session"]`.
Add the same list as `namedrop` on the original output so application metrics
are not duplicated there. Keep tokens in the administrator-managed Telegraf
configuration, not PLANK configuration or the repository. The supplied input
also accepts only these three measurement names.

## Grafana

Import [PLANK sessions](../../packaging/metrics/plank-influxql.json), then select
the **InfluxQL** data source in the dashboard's data-source selector.
Its InfluxDB 2 database/retention-policy mapping must point to the bucket
receiving Telegraf data. Reuse an existing working data source, or create a
dedicated one for a new bucket. For example, a `plank` bucket can be mapped to
the InfluxQL database `plank-db` and retention-policy name `autogen`; the
bucket's retention setting controls data expiry. Give Grafana a separate
read-only token for that bucket. A new destination does not move or delete
historical data in older buckets. No Flux migration is required.

The **Hosts** and **Clients** menus list machine names from Telegraf's `host`
tag, limited to the corresponding PLANK product. Each menu filters only that
product's queries. There is no separate Role menu or bookmark/UUID grouping.
Measurements from multiple bookmarks on the same machine share its charts;
existing mean, maximum and sum functions determine their aggregation.

Telegraf's optional global `nodetype` tag serves a different purpose: grouping
system metrics by the machine's primary use. For example, use `plank-host` or
`plank-client` for Host workstations and Client appliances. That fixed machine
classification does not replace the application's `role`; a machine running
both products can still appear in both session menus. Keep system-dashboard
filters aligned with the node labels configured on the endpoints.

The ten performance panels and two tablet-activity views use Grafana's visual InfluxQL editor. Fields,
functions, filters and grouping are editable through its controls. FEC uses the
Math control to retain the source-count-weighted percentage. Every query uses
`fill(none)`, so empty time buckets are omitted. Legends use Table mode with
Last non-null values. Video/audio graphs select Host sending and Client receiving
counters. Host Encoder Target has its own panel showing the configured target
for the selected Hosts.

The observation, event, statistics-age and application-queue panels are omitted
from the main view. Their underlying telemetry remains available for diagnosis.
This dashboard change does not remove fields or identity tags from existing
exporters or stored data; it avoids using those tags to split displayed series.

The dashboard displays local browser time. PLANK timestamps observations with
Unix wall time but calculates rates with monotonic elapsed time. Keep endpoint
clocks synchronized for correlation between machines. Telegraf's flush interval
and jitter delay dashboard delivery independently of the one-second sampling;
for example, a 5s flush interval with 10s jitter delivers batches roughly 5–15s
apart. The dashboard's 5s refresh does not make those batches arrive earlier.

## Measurements and interpretation

| Measurement | Contents |
| --- | --- |
| `plank_transport` | RTT, encoded video/audio payload rates, cumulative transport counters, interval drops, sampled queue depths, Client FEC loss, stream format/resolution, Host processing timing |
| `plank_client_video` | Actual decoder statistics windows: network/decode/render FPS, timing, network/render/overflow frame drops, hardware-decoder flag |
| `plank_session` | Transport created, ready, stopped or failed events |

Counters ending in `_total` reset at each transport connection. Fields ending in
`_interval` are changes since the previous exported sample; PLANK rejects a
counter decrease instead of producing a spike. Rate fields use the same actual
elapsed interval. The first observation establishes a baseline and omits rates.
Decoder windows accumulate raw counts and timing sums until export, even when
the configured export interval is longer than one second. They are consumed
once, not repeated at subsequent exports.

## Wacom pen activity

Ubuntu Client 1.4.12 and newer adds aggregate Wacom activity to `plank_transport`
when metrics are enabled. Both raw-HID forwarding and the normalized pen path
are covered, for sessions to Linux or macOS Hosts. macOS Client and local
workstation tablet use are not included in this first implementation.

Recording occurs only while PLANK session input is active and focused. It
counts decoded pen-position changes (including hover and eraser use) and tip-down
transitions. Repeated identical reports, touch, ExpressKeys, battery/status
traffic, and state restored after reconnect are excluded. Coordinates, pressure
values, device identifiers and strokes are never passed to the metrics exporter.

| Field | Meaning |
| --- | --- |
| `pen_observed` | A pen source is currently being observed; false means unavailable, not measured inactivity |
| `pen_motion_events_interval` | Position-change reports since the previous exported observation |
| `pen_tip_down_events_interval` | Tip-down transitions during that interval |
| `pen_last_activity_age_seconds` | Monotonic time since the last observed movement or tip-down; absent until activity occurs |
| `pen_activity_state` | `0`: unavailable; `1`: observed idle; `2`: movement or tip-down within the preceding minute |

The current activity tiles repeat for the selected Clients. Each uses the most
active reported state in the latest 30-second collection window, allowing for
Telegraf batching and multiple PLANK sessions on one Client. The history uses
ten-second windows and disconnects gaps longer than 30 seconds instead of
carrying a previous active state indefinitely. Queries retain `fill(none)`.
Normal shutdown emits an unavailable state; an abrupt process or collector
failure is represented by missing recent data. Use the one-second sampling
default for these views. Longer configured sampling intervals can leave gaps.

Green **Tablet active**, gray **Tablet idle**, and **No data** describe observed
tablet interaction, not productivity, attendance or whether an application
processed the input. Keyboard/mouse use and reviewing footage can occur without
pen movement. No activity is fabricated when observation is unsupported or fails.

Important distinctions:

- Video loss before/after FEC measures missing/unrecovered **source symbols**
  counted by RaptorQ. Repair symbols are excluded. The dashboard weights chart
  intervals by source count; it does not export the toolbar's ten-second peak.
  No source symbols means unknown/not applicable, not a measured 0% loss.
- QUIC packet loss includes transport traffic; it is a separate counter.
  Application queue drops are local evictions, not inferred WAN loss.
  Network-dropped frames and residual FEC symbols are different units.
- Encoded bitrate excludes FEC, QUIC and IP overhead. Encoder target is a policy
  value, not a guarantee of produced bitrate. No bandwidth is inferred from it.
- RTT is not glass-to-glass latency. Host processing metadata uses each capture/
  encoder path's existing boundaries; it is not a new separate capture or GPU
  encode timer. Unknown/zero Host timing samples are omitted. Clamped timing
  samples are counted in `processing_clamped_interval`.
- Audio packet rates/queues describe encoded Host-to-Client audio. They do not
  measure device starvation, A/V drift, microphone or camera performance.
- Queue depths are instantaneous samples; short bursts can occur between them.
  Inspect interval drop counters too. Client statistics age increases when no
  decoder window is published, including on an unchanged desktop.
- `ready` means QUIC transport ready, not that login, capture or rendering has
  completed. A process crash may prevent the final session event. Check the last
  observation's time rather than treating a historical `connected=true` as live.

All measurements use `role`, `workstation_id` and `slot_id` tags plus Telegraf's
existing tags. No account names, addresses, credentials, input values, clipboard
contents, captured pixels or audio samples are emitted. Administrators control
who can read the existing metrics database and its endpoint identifiers.

## Runtime and failure behavior

The exporter uses the transport's existing statistics task. There is no new
sampling thread, remote HTTP/DNS work, disk spool or retry queue. Host frame
callbacks update a bounded accumulator; Client windows use a retained handle
independent of the endpoint lifetime. Busy observation locks drop a metrics
observation rather than delaying media. Formatting and nonblocking localhost UDP
sends occur outside application/queue locks.

Each datagram is bounded to 4096 bytes. An unavailable or slow collector cannot
delay teardown or reject a connection. `export_errors_total` reports detectable
socket/serialization errors; `observation_drops_total` reports accumulator
contention. UDP can also drop silently, so neither is proof of complete delivery.
This is operational telemetry, not an audit trail. Telegraf owns the separate
remote-delivery buffer. No automatic kernel tuning is applied.

Disable `metrics_enabled` and restart the product to stop emission. A Client
with no transport session sends nothing. Telegraf, its existing system inputs,
and any other PLANK process sharing its listener remain independent.

## Validation

Run the Rust metrics tests and the isolated real-parser fixture:

```bash
cargo test --locked --manifest-path protocol/plank-transport/Cargo.toml --lib metrics::tests::
python3 scripts/test/test-metrics-telegraf.py --telegraf /path/to/telegraf
```

The second command uses a temporary loopback listener and file output, never
production configuration or a database write. Hosted Linux transport CI can
fetch the checksum-pinned Telegraf test binary with `--download-test-agent`.
The C ABI loopback fixture exercises media and teardown with metrics disabled
and with a collector that does not read. Hosted compilation/parser tests do not
replace installed-session performance or end-to-end Grafana acceptance.

References: [Telegraf socket listener](https://docs.influxdata.com/telegraf/v1/input-plugins/socket_listener/),
[Influx parser](https://docs.influxdata.com/telegraf/v1/data_formats/input/influx/),
[Grafana InfluxDB configuration](https://grafana.com/docs/grafana/latest/datasources/influxdb/configure/).
