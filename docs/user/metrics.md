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
   agent's configuration directory and restart Telegraf. Keep its existing
   InfluxDB URL, organization, bucket and token. Do not add a second duplicate
   output. Keep `omit_hostname = false` so Telegraf adds the local `host` tag.
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

## Grafana

Import [PLANK sessions](../../packaging/metrics/plank-influxql.json), then select
the existing **InfluxQL** data source in the dashboard's data-source selector.
The existing InfluxDB 2 database/retention-policy mapping must point to the
bucket receiving Telegraf data. An already working InfluxQL data source needs
no new database, Flux data source or duplicate bucket.

Filters select the local machine, remote workstation UUID and Host/Client role.
`slot_id` distinguishes multiple bookmarks for the same workstation. The Host
uses the fixed slot `host`. These stable IDs avoid a new series for each
reconnection. Hostname is Telegraf's local machine name; it is never overwritten
with the remote workstation's name. Version and connection start time are fields,
not tags. Configure machine naming/privacy through Telegraf as for system metrics.

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
