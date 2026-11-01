#!/usr/bin/env python3

"""Analyze opt-in PLANK client audio/video clock telemetry."""

from __future__ import annotations

import argparse
import math
import re
import sys
from dataclasses import dataclass


AUDIO_PATTERN = re.compile(
    r"PLANK A/V audio clock: media=(\d+) submit=(\d+) "
    r"queue=(-?\d+) device=(-?\d+) pending=(-?\d+) frame=(\d+)"
    r"(?: correction=(-?\d+) skipped=(\d+) raw=(\d+)"
    r"(?: catchup=(-?\d+))?)?"
)
VIDEO_PATTERN = re.compile(
    r"PLANK A/V video clock: media=(\d+) render=(\d+) "
    r"queue=(\d+) renderer=(\d+)"
)
TICK_WRAP = 1 << 32


@dataclass
class Point:
    """One media-clock sample and its estimated client presentation time."""

    media_ms: int
    presentation_ms: int


def unwrap_ticks(raw_ticks: list[int]) -> list[int]:
    """Expand wrapping 32-bit monotonic millisecond ticks."""

    output: list[int] = []
    epoch = 0
    previous = raw_ticks[0]
    for ticks in raw_ticks:
        if ticks < previous and previous - ticks > TICK_WRAP // 2:
            epoch += TICK_WRAP
        output.append(epoch + ticks)
        previous = ticks
    return output


def latest_segment(points: list[Point]) -> list[Point]:
    """Keep the most recent session, detected by a media-clock reset."""

    start = 0
    for index in range(1, len(points)):
        if points[index].media_ms < points[index - 1].media_ms:
            start = index
    return points[start:]


def percentile(values: list[float], percent: int) -> float:
    """Return the nearest-rank percentile."""

    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, math.ceil(len(ordered) * percent / 100))
    return ordered[rank - 1]


def clock_series(points: list[Point], warmup_ms: int) -> list[tuple[float, float]]:
    """Return client elapsed time and clock error after warmup."""

    initial_presentation = points[0].presentation_ms
    retained = [
        point
        for point in points
        if point.presentation_ms - initial_presentation >= warmup_ms
    ]
    if len(retained) < 2:
        raise ValueError("fewer than two telemetry samples remain after warmup")
    first = retained[0]
    return [
        (
            float(point.presentation_ms - first.presentation_ms),
            float(
                (point.presentation_ms - first.presentation_ms)
                - (point.media_ms - first.media_ms)
            ),
        )
        for point in retained
    ]


def interpolate(series: list[tuple[float, float]], elapsed_ms: float) -> float:
    """Linearly interpolate clock error at a client elapsed time."""

    for index in range(1, len(series)):
        before = series[index - 1]
        after = series[index]
        if elapsed_ms <= after[0]:
            span = after[0] - before[0]
            if span == 0:
                return after[1]
            fraction = (elapsed_ms - before[0]) / span
            return before[1] + fraction * (after[1] - before[1])
    return series[-1][1]


def linear_slope(series: list[tuple[float, float]]) -> float:
    """Return the least-squares clock-error slope in milliseconds per millisecond."""

    mean_elapsed = sum(point[0] for point in series) / len(series)
    mean_error = sum(point[1] for point in series) / len(series)
    denominator = sum((point[0] - mean_elapsed) ** 2 for point in series)
    if denominator == 0:
        return 0.0
    return sum(
        (point[0] - mean_elapsed) * (point[1] - mean_error)
        for point in series
    ) / denominator


def parse_log(
    lines: list[str],
) -> tuple[list[Point], list[Point], list[Point], list[int], int | None]:
    """Parse audio and video samples from PLANK Client log lines."""

    audio_raw: list[
        tuple[int, int, int, int | None, int | None, int | None, int | None]
    ] = []
    video_raw: list[tuple[int, int]] = []
    for line in lines:
        audio = AUDIO_PATTERN.search(line)
        if audio:
            base = [int(value) for value in audio.groups()[:6]]
            media, submit, queued, device, _pending, frame = base
            correction = int(audio.group(7)) if audio.group(7) is not None else None
            skipped = int(audio.group(8)) if audio.group(8) is not None else None
            raw_media = int(audio.group(9)) if audio.group(9) is not None else None
            catchup = int(audio.group(10)) if audio.group(10) is not None else None
            if queued >= 0 and device >= 0:
                audio_raw.append(
                    (
                        media,
                        submit,
                        max(queued - frame, 0) + device,
                        correction,
                        skipped,
                        raw_media,
                        catchup,
                    )
                )
            continue
        video = VIDEO_PATTERN.search(line)
        if video:
            media, render, _queued, _renderer = map(int, video.groups())
            video_raw.append((media, render))

    if not audio_raw or not video_raw:
        raise ValueError("log does not contain both audio and video telemetry")

    audio_session_start = 0
    for index in range(1, len(audio_raw)):
        if audio_raw[index][0] < audio_raw[index - 1][0]:
            audio_session_start = index
    audio_raw = audio_raw[audio_session_start:]

    audio_ticks = unwrap_ticks([sample[1] for sample in audio_raw])
    video_ticks = unwrap_ticks([sample[1] for sample in video_raw])
    audio_points = [
        Point(sample[0], ticks + sample[2])
        for sample, ticks in zip(audio_raw, audio_ticks)
    ]
    video_points = [
        Point(sample[0], ticks)
        for sample, ticks in zip(video_raw, video_ticks)
    ]
    raw_audio_points = [
        Point(sample[5], ticks)
        for sample, ticks in zip(audio_raw, audio_ticks)
        if sample[5] is not None
    ]
    corrections = [sample[3] for sample in audio_raw if sample[3] is not None]
    skipped_values = [sample[4] for sample in audio_raw if sample[4] is not None]
    catchup_corrections = [
        sample[6] for sample in audio_raw if sample[6] is not None
    ]
    skipped_blocks = max(skipped_values) if skipped_values else None
    return (
        audio_points,
        latest_segment(video_points),
        raw_audio_points,
        corrections,
        skipped_blocks,
        catchup_corrections,
    )


def main() -> int:
    """Run the command-line telemetry analysis."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", help="Moonlight log file, or - for standard input")
    parser.add_argument("--warmup-seconds", type=float, default=10.0)
    parser.add_argument("--min-duration-seconds", type=float, default=0.0)
    parser.add_argument("--max-relative-drift-ms", type=float)
    parser.add_argument("--max-projected-relative-drift-ms-per-hour", type=float)
    parser.add_argument("--max-skipped-audio-blocks", type=int)
    args = parser.parse_args()

    if args.warmup_seconds < 0 or args.min_duration_seconds < 0:
        parser.error("durations cannot be negative")
    if args.max_relative_drift_ms is not None and args.max_relative_drift_ms < 0:
        parser.error("relative drift limit cannot be negative")
    if (
        args.max_projected_relative_drift_ms_per_hour is not None
        and args.max_projected_relative_drift_ms_per_hour < 0
    ):
        parser.error("projected relative drift limit cannot be negative")
    if args.max_skipped_audio_blocks is not None and args.max_skipped_audio_blocks < 0:
        parser.error("skipped audio block limit cannot be negative")
    try:
        if args.log == "-":
            lines = sys.stdin.readlines()
        else:
            with open(args.log, encoding="utf-8", errors="replace") as log_file:
                lines = log_file.readlines()
        (
            audio_points,
            video_points,
            raw_audio_points,
            corrections,
            skipped_audio_blocks,
            catchup_corrections,
        ) = parse_log(lines)
        audio_clock = clock_series(audio_points, round(args.warmup_seconds * 1000))
        video_clock = clock_series(video_points, round(args.warmup_seconds * 1000))
        raw_audio_clock = (
            clock_series(raw_audio_points, round(args.warmup_seconds * 1000))
            if raw_audio_points
            else []
        )
    except (OSError, ValueError) as error:
        print(f"telemetry analysis failed: {error}", file=sys.stderr)
        return 1

    duration_ms = min(audio_clock[-1][0], video_clock[-1][0])
    audio_error = interpolate(audio_clock, duration_ms)
    video_error = interpolate(video_clock, duration_ms)
    relative_drift_ms = audio_error - video_error
    endpoint_projection = (
        relative_drift_ms * 3_600_000 / duration_ms if duration_ms else 0.0
    )
    audio_fit = [point for point in audio_clock if point[0] <= duration_ms]
    video_fit = [point for point in video_clock if point[0] <= duration_ms]
    audio_slope = linear_slope(audio_fit)
    video_slope = linear_slope(video_fit)
    relative_slope = audio_slope - video_slope
    fitted_relative_drift_ms = relative_slope * duration_ms
    projected_drift = relative_slope * 3_600_000
    audio_jitter = [
        abs(audio_clock[index][1] - audio_clock[index - 1][1])
        for index in range(1, len(audio_clock))
    ]
    video_jitter = [
        abs(video_clock[index][1] - video_clock[index - 1][1])
        for index in range(1, len(video_clock))
    ]

    print(f"audio_samples={len(audio_clock)}")
    print(f"video_samples={len(video_clock)}")
    print(f"measurement_duration_seconds={duration_ms / 1000:.3f}")
    print(f"audio_clock_jitter_p95_ms={percentile(audio_jitter, 95):.3f}")
    print(f"video_clock_jitter_p95_ms={percentile(video_jitter, 95):.3f}")
    print(f"relative_av_drift_ms={relative_drift_ms:.3f}")
    print(f"fitted_relative_av_drift_ms={fitted_relative_drift_ms:.3f}")
    print(f"audio_clock_rate_error_ms_per_hour={audio_slope * 3_600_000:.3f}")
    print(f"video_clock_rate_error_ms_per_hour={video_slope * 3_600_000:.3f}")
    if raw_audio_clock:
        raw_audio_fit = [point for point in raw_audio_clock if point[0] <= duration_ms]
        print(
            "raw_audio_clock_rate_error_ms_per_hour="
            f"{linear_slope(raw_audio_fit) * 3_600_000:.3f}"
        )
    else:
        print("raw_audio_clock_rate_error_ms_per_hour=not_reported")
    if corrections:
        print(f"audio_correction_ppm_final={corrections[-1]}")
        print(f"audio_correction_ppm_min={min(corrections)}")
        print(f"audio_correction_ppm_max={max(corrections)}")
    else:
        print("audio_correction_ppm_final=not_reported")
        print("audio_correction_ppm_min=not_reported")
        print("audio_correction_ppm_max=not_reported")
    print(
        "audio_blocks_skipped="
        f"{skipped_audio_blocks if skipped_audio_blocks is not None else 'not_reported'}"
    )
    if catchup_corrections:
        print(f"audio_backlog_correction_ppm_final={catchup_corrections[-1]}")
        print(f"audio_backlog_correction_ppm_max={max(catchup_corrections)}")
    else:
        print("audio_backlog_correction_ppm_final=not_reported")
        print("audio_backlog_correction_ppm_max=not_reported")
    print(f"projected_relative_av_drift_ms_per_hour={projected_drift:.3f}")
    print(
        "endpoint_projected_relative_av_drift_ms_per_hour="
        f"{endpoint_projection:.3f}"
    )
    print("absolute_av_offset=not_measured")

    if duration_ms < args.min_duration_seconds * 1000:
        print("av_sync_gate=fail (insufficient duration)")
        return 1
    if (
        args.max_relative_drift_ms is not None
        and abs(relative_drift_ms) > args.max_relative_drift_ms
    ):
        print("av_sync_gate=fail (relative drift)")
        return 1
    if (
        args.max_projected_relative_drift_ms_per_hour is not None
        and abs(projected_drift) > args.max_projected_relative_drift_ms_per_hour
    ):
        print("av_sync_gate=fail (projected relative drift)")
        return 1
    if (
        args.max_skipped_audio_blocks is not None
        and (
            skipped_audio_blocks is None
            or skipped_audio_blocks > args.max_skipped_audio_blocks
        )
    ):
        print("av_sync_gate=fail (skipped audio blocks)")
        return 1
    print("av_sync_gate=pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
