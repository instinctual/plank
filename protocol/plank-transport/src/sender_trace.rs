// SPDX-License-Identifier: AGPL-3.0-or-later
//! Bounded sender diagnostic, flushed once after worker join, never per frame.
use kynet::sender_timing::{Measurements, ns};
use std::{
    io::{BufWriter, Write},
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

const CAPACITY: usize = 8192;
const WINDOW: Duration = Duration::from_secs(120);

#[derive(Default)]
pub(super) struct Trace(Mutex<Option<Buffer>>);

struct Buffer {
    origin: Instant,
    wall_ns: u128,
    rows: Vec<Row>,
    flushed: bool,
}

pub(super) struct Start {
    at: Instant,
    offset_ns: u64,
    queue_ns: u64,
}

pub(super) struct Frame {
    pub number: u64,
    pub key: bool,
    pub bytes: usize,
    pub depth: usize,
    pub wire_bps: u64,
    pub drops: u64,
}

struct Row {
    start: Start,
    frame: Frame,
    send_ns: u64,
    failed: bool,
    measurements: Measurements,
}

impl Trace {
    pub(super) fn begin(&self, enqueued: Instant) -> Option<Start> {
        let mut guard = self.0.lock().unwrap();
        let buffer = guard.get_or_insert_with(|| Buffer {
            origin: Instant::now(),
            wall_ns: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            rows: Vec::with_capacity(CAPACITY),
            flushed: false,
        });
        let at = Instant::now();
        if buffer.flushed || buffer.rows.len() == CAPACITY || at - buffer.origin > WINDOW {
            return None;
        }
        Some(Start {
            at,
            offset_ns: ns(at - buffer.origin),
            queue_ns: ns(at - enqueued),
        })
    }

    pub(super) fn finish(
        &self,
        start: Start,
        frame: Frame,
        failed: bool,
        measurements: Measurements,
    ) {
        let send_ns = ns(start.at.elapsed());
        let mut guard = self.0.lock().unwrap();
        if let Some(buffer) = guard.as_mut()
            && !buffer.flushed
            && buffer.rows.len() < CAPACITY
        {
            buffer.rows.push(Row {
                start,
                frame,
                send_ns,
                failed,
                measurements,
            });
        }
    }

    pub(super) fn flush(&self) {
        let mut guard = self.0.lock().unwrap();
        let Some(buffer) = guard.as_mut() else { return };
        if buffer.flushed {
            return;
        }
        buffer.flushed = true;
        let mut out = BufWriter::new(std::io::stderr().lock());
        let _ = writeln!(
            out,
            "PLANK sender-timing begin wall_unix_ns={} rows={} capacity={} window_s=120 units=ns",
            buffer.wall_ns,
            buffer.rows.len(),
            CAPACITY
        );
        let _ = writeln!(
            out,
            "PLANK sender-timing columns=frame,key,bytes,dequeue_ns,queue_ns,depth,wire_bps,queue_drops,send_ns,fec_total_ns,fec_copy_ns,fec_encoder_ns,fec_repair_ns,quinn_ns,quinn_max_ns,datagrams,datagram_bytes,failed"
        );
        for row in buffer.rows.drain(..) {
            let f = row.frame;
            let m = row.measurements;
            let _ = writeln!(
                out,
                "PLANK sender-timing {},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
                f.number,
                u8::from(f.key),
                f.bytes,
                row.start.offset_ns,
                row.start.queue_ns,
                f.depth,
                f.wire_bps,
                f.drops,
                row.send_ns,
                m.fec_total_ns,
                m.fec_copy_ns,
                m.fec_encoder_ns,
                m.fec_repair_ns,
                m.quinn_ns,
                m.quinn_max_ns,
                m.datagrams,
                m.datagram_bytes,
                u8::from(row.failed)
            );
        }
        let _ = writeln!(out, "PLANK sender-timing end");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounded_and_expiring() {
        let trace = Trace::default();
        for number in 0..CAPACITY {
            let start = trace.begin(Instant::now()).unwrap();
            trace.finish(
                start,
                Frame {
                    number: number as u64,
                    key: false,
                    bytes: 1,
                    depth: 0,
                    wire_bps: 1,
                    drops: 0,
                },
                false,
                Measurements::default(),
            );
        }
        assert!(trace.begin(Instant::now()).is_none());
        let mut guard = trace.0.lock().unwrap();
        let buffer = guard.as_mut().unwrap();
        buffer.rows.clear();
        buffer.origin -= WINDOW + Duration::from_secs(1);
        drop(guard);
        assert!(trace.begin(Instant::now()).is_none());
    }

    #[tokio::test]
    async fn contexts_are_isolated_across_suspension() {
        let first = kynet::sender_timing::measure(async {
            kynet::sender_timing::update(|m| m.datagrams = 7);
            tokio::task::yield_now().await;
            kynet::sender_timing::update(|m| m.datagrams += 1);
            42
        });
        let second = kynet::sender_timing::measure(async {
            kynet::sender_timing::update(|m| m.datagrams = 3);
            tokio::task::yield_now().await;
        });
        let ((answer, a), (_, b)) = tokio::join!(first, second);
        assert_eq!(answer, 42);
        assert_eq!(a.datagrams, 8);
        assert_eq!(b.datagrams, 3);
        assert!(!kynet::sender_timing::active());
        kynet::sender_timing::update(|_| panic!("outside context"));
    }
}
