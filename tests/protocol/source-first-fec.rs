// Compile against the exact retained RaptorQ rlib used by the transport.
#[path = "../../third_party/kyber-kymux/kyproto/src/protocol/driver/av/source_first.rs"]
mod source_first;

#[test]
fn measure_keyframe_preparation() {
    use std::{hint::black_box, time::Instant};
    for size in [100_000usize, 1_100_123, 1_600_013] {
        let data: Vec<_> = (0..size).map(|i| (i * 73 ^ (i >> 9)) as u8).collect();
        let oti = raptorq::ObjectTransmissionInformation::with_defaults(size as u64, 1280);
        let repairs =
            ((size.div_ceil(oti.symbol_size() as usize) as f32 * 0.3).ceil() as u32).max(2);
        let mut original_us = 0;
        let mut first_source_ns = 0;
        let mut source_us = 0;
        let mut total_us = 0;
        // Warm each path, then alternate. The baseline is the pinned library's
        // prepare-all API, not a second production sender. This measures CPU
        // preparation only, not actual QUIC delivery or Client presentation.
        for trial in 0..21 {
            let start = Instant::now();
            black_box(raptorq::Encoder::new(&data, oti).get_encoded_packets(repairs));
            let old = start.elapsed().as_micros();
            let start = Instant::now();
            let mut sources = source_first::source_packets(&data, &oti);
            black_box(sources.next().expect("missing first source symbol"));
            let first = start.elapsed().as_nanos();
            for packet in sources {
                black_box(packet);
            }
            let source = start.elapsed().as_micros();
            let encoder = raptorq::Encoder::new(&data, oti);
            for block in encoder.get_block_encoders() {
                black_box(block.repair_packets(0, repairs));
            }
            let total = start.elapsed().as_micros();
            if trial > 0 {
                original_us += old;
                first_source_ns += first;
                source_us += source;
                total_us += total;
            }
        }
        println!(
            "source_first size={size} trials=20 baseline_ready_us={} first_source_ready_ns={} originals_prepare_us={} total_prepare_us={}",
            original_us / 20,
            first_source_ns / 20,
            source_us / 20,
            total_us / 20
        );
    }
}
