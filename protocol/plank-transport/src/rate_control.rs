// SPDX-License-Identifier: AGPL-3.0-or-later

//! PLANK's rate policy at the Kynet/Quinn ownership boundary.
//!
//! KyProto remains responsible for media packetization and RaptorQ. This
//! module turns the requested encoder rate into a FEC-inclusive wire budget
//! and supplies a Host Quinn controller whose window does not collapse on
//! isolated repairable loss. Its budget has a 1 Gbps floor; Quinn alone schedules
//! transmission. Encoder rate, FEC and bounded queues are unchanged.

use quinn_proto::RttEstimator;
use quinn_proto::congestion::{Controller, ControllerFactory, ControllerMetrics};
use std::any::Any;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

const MIN_VIDEO_BITRATE_BPS: u64 = 10_000_000;
const FEC_AND_PACKET_SCALE_NUMERATOR: u64 = 27;
const FEC_AND_PACKET_SCALE_DENOMINATOR: u64 = 20;
const AUDIO_AND_CONTROL_RESERVE_BPS: u64 = 1_000_000;
const MIN_WINDOW_PACKETS: u64 = 64;
const STEADY_WINDOW_NUMERATOR: u64 = 3;
const STEADY_WINDOW_DENOMINATOR: u64 = 2;
const MAX_WINDOW_RTT: Duration = Duration::from_millis(100);
const INITIAL_WINDOW_RTT: Duration = Duration::from_millis(200);
const SEND_BUDGET_FLOOR_BPS: u64 = 1_000_000_000;

fn video_to_wire_bps(video_bps: u64) -> u64 {
    video_bps
        .saturating_mul(FEC_AND_PACKET_SCALE_NUMERATOR)
        .div_ceil(FEC_AND_PACKET_SCALE_DENOMINATOR)
        .saturating_add(AUDIO_AND_CONTROL_RESERVE_BPS)
}

fn window_for_rate(rate_bps: u64, rtt: Duration, mtu: u16) -> u64 {
    let rtt_nanos = rtt.min(MAX_WINDOW_RTT).as_nanos().max(1);
    let bdp_bytes = (rate_bps as u128)
        .saturating_mul(rtt_nanos)
        .div_ceil(8_000_000_000_u128);
    let target = bdp_bytes
        .saturating_mul(STEADY_WINDOW_NUMERATOR as u128)
        .div_ceil(STEADY_WINDOW_DENOMINATOR as u128)
        .min(u64::MAX as u128) as u64;
    target.max(MIN_WINDOW_PACKETS.saturating_mul(mtu as u64))
}

/// Shared requested rate and Host controller budget for one media connection.
#[derive(Debug)]
pub struct TransportRatePolicy {
    requested_video_bps: AtomicU64,
    active_video_bps: AtomicU64,
    active_peak_video_bps: AtomicU64,
    repairable_congestion_events: AtomicU64,
    persistent_congestion_events: AtomicU64,
}

impl TransportRatePolicy {
    pub fn new(requested_video_bps: u64) -> Arc<Self> {
        let requested_video_bps = requested_video_bps.max(MIN_VIDEO_BITRATE_BPS);
        Arc::new(Self {
            requested_video_bps: AtomicU64::new(requested_video_bps),
            active_video_bps: AtomicU64::new(requested_video_bps),
            active_peak_video_bps: AtomicU64::new(requested_video_bps),
            repairable_congestion_events: AtomicU64::new(0),
            persistent_congestion_events: AtomicU64::new(0),
        })
    }

    pub fn requested_video_bps(&self) -> u64 {
        self.requested_video_bps.load(Ordering::Acquire)
    }

    pub fn active_video_bps(&self) -> u64 {
        self.active_video_bps.load(Ordering::Acquire)
    }

    pub fn active_wire_bps(&self) -> u64 {
        let budget = video_to_wire_bps(self.active_peak_video_bps.load(Ordering::Acquire));
        budget.max(SEND_BUDGET_FLOOR_BPS)
    }

    pub fn set_requested_video_bps(&self, requested_video_bps: u64, peak_video_bps: u64) {
        let requested_video_bps = requested_video_bps.max(MIN_VIDEO_BITRATE_BPS);
        let peak_video_bps = peak_video_bps.max(requested_video_bps);
        self.requested_video_bps
            .store(requested_video_bps, Ordering::Release);
        self.active_video_bps
            .store(requested_video_bps, Ordering::Release);
        self.active_peak_video_bps
            .store(peak_video_bps, Ordering::Release);
    }
}

#[derive(Clone)]
struct PlankRateController {
    policy: Arc<TransportRatePolicy>,
    current_mtu: u16,
    last_rtt: Duration,
    window: u64,
    bandwidth_estimate_bps: u64,
}

impl PlankRateController {
    fn new(policy: Arc<TransportRatePolicy>, current_mtu: u16) -> Self {
        let initial_window =
            window_for_rate(policy.active_wire_bps(), INITIAL_WINDOW_RTT, current_mtu);
        Self {
            policy,
            current_mtu,
            last_rtt: INITIAL_WINDOW_RTT,
            window: initial_window,
            bandwidth_estimate_bps: 0,
        }
    }

    fn update_window(&mut self, rtt: Duration) {
        self.last_rtt = rtt;
        self.window = window_for_rate(self.policy.active_wire_bps(), rtt, self.current_mtu);
    }
}

impl Controller for PlankRateController {
    fn on_ack(
        &mut self,
        now: Instant,
        sent: Instant,
        bytes: u64,
        _app_limited: bool,
        rtt: &RttEstimator,
    ) {
        let delivery_time = now.saturating_duration_since(sent);
        if !delivery_time.is_zero() {
            self.bandwidth_estimate_bps = (bytes as u128)
                .saturating_mul(8_000_000_000)
                .checked_div(delivery_time.as_nanos())
                .unwrap_or_default()
                .min(u64::MAX as u128) as u64;
        }
        self.update_window(rtt.get());
    }

    fn on_congestion_event(
        &mut self,
        _now: Instant,
        _sent: Instant,
        is_persistent_congestion: bool,
        _lost_bytes: u64,
    ) {
        let counter = if is_persistent_congestion {
            &self.policy.persistent_congestion_events
        } else {
            &self.policy.repairable_congestion_events
        };
        counter.fetch_add(1, Ordering::Relaxed);
    }

    fn on_mtu_update(&mut self, new_mtu: u16) {
        self.current_mtu = new_mtu;
        self.update_window(self.last_rtt);
    }

    fn window(&self) -> u64 {
        self.window
    }

    fn metrics(&self) -> ControllerMetrics {
        let mut metrics = ControllerMetrics::default();
        metrics.congestion_window = self.window;
        metrics.pacing_rate = Some(self.policy.active_wire_bps());
        metrics.bandwidth_estimate = Some(self.bandwidth_estimate_bps);
        metrics
    }

    fn clone_box(&self) -> Box<dyn Controller> {
        Box::new(self.clone())
    }

    fn initial_window(&self) -> u64 {
        self.window
    }

    fn into_any(self: Box<Self>) -> Box<dyn Any> {
        self
    }
}

/// Constructs one PLANK rate controller per Quinn path.
pub struct PlankRateControllerFactory {
    policy: Arc<TransportRatePolicy>,
}

impl PlankRateControllerFactory {
    pub fn new(policy: Arc<TransportRatePolicy>) -> Arc<Self> {
        eprintln!("PLANK sender: controller-budget-floor-bps=1000000000");
        Arc::new(Self { policy })
    }
}

impl ControllerFactory for PlankRateControllerFactory {
    fn build(self: Arc<Self>, _now: Instant, current_mtu: u16) -> Box<dyn Controller> {
        Box::new(PlankRateController::new(self.policy.clone(), current_mtu))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_budget_includes_fixed_raptorq_and_packet_overhead() {
        assert_eq!(video_to_wire_bps(100_000_000), 136_000_000);
        assert_eq!(video_to_wire_bps(150_000_000), 203_500_000);
    }

    #[test]
    fn host_send_policy_does_not_change_encoder_target() {
        let policy = TransportRatePolicy::new(50_000_000);
        policy.set_requested_video_bps(50_000_000, 100_000_000);
        assert_eq!(policy.requested_video_bps(), 50_000_000);
        assert_eq!(policy.active_video_bps(), 50_000_000);
        assert_eq!(policy.active_wire_bps(), 1_000_000_000);
    }

    #[test]
    fn rate_floor_survives_slider_changes_without_capping_higher_rates() {
        let policy = TransportRatePolicy::new(150_000_000);
        for (requested, peak) in [
            (10_000_000, 15_000_000),
            (150_000_000, 225_000_000),
            (1_000_000_000, 1_500_000_000),
        ] {
            policy.set_requested_video_bps(requested, peak);
            assert_eq!(policy.active_video_bps(), requested);
            assert_eq!(policy.requested_video_bps(), requested);
            let wire = video_to_wire_bps(peak);
            assert_eq!(policy.active_wire_bps(), wire.max(SEND_BUDGET_FLOOR_BPS));
        }
    }

    #[test]
    fn controller_window_uses_selected_budget_and_stays_rtt_bounded() {
        let policy = TransportRatePolicy::new(100_000_000);
        let mut controller = PlankRateController::new(policy, 1_344);
        controller.update_window(Duration::from_millis(20));
        assert_eq!(controller.window(), 3_750_000);
        controller.update_window(Duration::from_secs(10));
        assert_eq!(controller.window(), 18_750_000);
        controller.update_window(Duration::from_micros(1));
        assert_eq!(controller.window(), MIN_WINDOW_PACKETS * 1_344);
    }

    #[test]
    fn steady_window_is_rate_and_rtt_derived() {
        assert_eq!(
            window_for_rate(200_000_000, Duration::from_millis(20), 1_344),
            750_000
        );
        assert_eq!(
            window_for_rate(200_000_000, Duration::from_micros(100), 1_344),
            MIN_WINDOW_PACKETS * 1_344
        );
    }

    #[test]
    fn explicit_peak_rate_change_updates_the_controller_budget() {
        let policy = TransportRatePolicy::new(100_000_000);
        policy.set_requested_video_bps(150_000_000, 225_000_000);
        assert_eq!(policy.requested_video_bps(), 150_000_000);
        assert_eq!(policy.active_video_bps(), 150_000_000);
        assert_eq!(policy.active_wire_bps(), 1_000_000_000);
        policy.set_requested_video_bps(150_000_000, 1_000_000_000);
        assert_eq!(policy.active_video_bps(), 150_000_000);
        assert_eq!(policy.active_wire_bps(), 1_351_000_000);
    }

    #[test]
    fn repairable_random_loss_does_not_collapse_the_window() {
        let policy = TransportRatePolicy::new(150_000_000);
        let factory = PlankRateControllerFactory::new(policy);
        let now = Instant::now();
        let mut controller = factory.build(now, 1_344);
        let initial_window = controller.window();
        for sequence in 0..500 {
            controller.on_congestion_event(
                now + Duration::from_millis(sequence),
                now,
                false,
                1_344,
            );
        }
        assert_eq!(controller.window(), initial_window);
    }
}
