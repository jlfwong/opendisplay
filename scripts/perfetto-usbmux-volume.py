#!/usr/bin/env python3
"""Aggregate usbmux LogPackets into Perfetto counter tracks (no re-record).

Reads an OpenDisplay session JSON (usbmuxEvents) and an existing Perfetto export,
drops the 14k+ discrete usbmux instant events, and adds time-bucketed counter
series for packet volume and in-flight bytes so ui.perfetto.dev shows line charts.

Usage:
  python3 scripts/perfetto-usbmux-volume.py /tmp/opendisplay-trace-5E006181.perfetto.json
  python3 scripts/perfetto-usbmux-volume.py trace.perfetto.json --bucket-ms 50
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

PID = 1
TID_USBMUX_TOTAL = 401
TID_USBMUX_APP = 402
TID_USBMUX_BULK = 403
TID_USBMUX_HB = 404
TID_USBMUX_INFLIGHT = 405
TID_INPUT_WIRE = 406

USBMUX_INSTANT_TID = 4
INPUT_BASE = 1_000_000

INFLIGHT_RE = re.compile(r"\s(\d+)/(\d+)\s+A\s")


def min_origin_ms(session: dict[str, Any]) -> float:
    candidates: list[float] = [session["startedAtMs"]]
    for key in ("macSpans", "ipadSpans"):
        for span in session.get(key) or []:
            candidates.append(span["startMs"])
    for ev in session.get("usbmuxEvents") or []:
        candidates.append(ev["timeMs"])
    return min(candidates)


def usbmux_category(ev: dict[str, Any]) -> str:
    sport, dport = ev.get("sport"), ev.get("dport")
    if sport == 9002 or dport == 9002:
        return "hb"
    if sport == 9000 or dport == 9000:
        return "app"
    if sport in (3, 61031) or dport in (3, 61031):
        return "bulk"
    return "other"


def inflight_bytes(ev: dict[str, Any]) -> int | None:
    if ev.get("len") is not None:
        return int(ev["len"])
    m = INFLIGHT_RE.search(ev.get("raw", ""))
    return int(m.group(1)) if m else None


def aggregate_usbmux(
    events: list[dict[str, Any]], origin_ms: float, bucket_ms: float
) -> dict[int, dict[str, float]]:
    buckets: dict[int, dict[str, float]] = defaultdict(
        lambda: {
            "in_total": 0,
            "out_total": 0,
            "in_app": 0,
            "out_app": 0,
            "in_bulk": 0,
            "out_bulk": 0,
            "in_hb": 0,
            "out_hb": 0,
            "inflight_max": 0,
        }
    )
    for ev in events:
        b = int((ev["timeMs"] - origin_ms) // bucket_ms)
        row = buckets[b]
        direction = ev.get("direction", "")
        cat = usbmux_category(ev)
        if direction == "in":
            row["in_total"] += 1
            if cat == "app":
                row["in_app"] += 1
            elif cat == "bulk":
                row["in_bulk"] += 1
            elif cat == "hb":
                row["in_hb"] += 1
            inflight = inflight_bytes(ev)
            if inflight is not None:
                row["inflight_max"] = max(row["inflight_max"], inflight)
        elif direction == "out":
            row["out_total"] += 1
            if cat == "app":
                row["out_app"] += 1
            elif cat == "bulk":
                row["out_bulk"] += 1
            elif cat == "hb":
                row["out_hb"] += 1
    return buckets


def aggregate_input_wire(
    mac_spans: list[dict[str, Any]], origin_ms: float, bucket_ms: float
) -> dict[int, float]:
    buckets: dict[int, float] = defaultdict(float)
    for span in mac_spans:
        if span.get("phase") != "input.wire":
            continue
        start = span["startMs"]
        end = span["endMs"]
        dur_ms = end - start
        if dur_ms <= 0:
            continue
        b_start = int((start - origin_ms) // bucket_ms)
        b_end = int((end - origin_ms) // bucket_ms)
        for b in range(b_start, b_end + 1):
            buckets[b] = max(buckets[b], dur_ms)
    return buckets


def counter_event(
    ts_us: float, tid: int, name: str, values: dict[str, float]
) -> dict[str, Any]:
    return {
        "name": name,
        "cat": "usbmux",
        "ph": "C",
        "ts": ts_us,
        "pid": PID,
        "tid": tid,
        "args": {k: int(v) if v == int(v) else v for k, v in values.items()},
    }


def thread_name(tid: int, label: str) -> dict[str, Any]:
    return {
        "name": "thread_name",
        "cat": "__metadata",
        "ph": "M",
        "ts": 0,
        "pid": PID,
        "tid": tid,
        "args": {"name": label},
    }


def build_counter_events(
    usbmux_buckets: dict[int, dict[str, float]],
    wire_buckets: dict[int, float],
    origin_ms: float,
    bucket_ms: float,
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = [
        thread_name(TID_USBMUX_TOTAL, "usbmux pkts (all)"),
        thread_name(TID_USBMUX_APP, "usbmux pkts (:9000 app)"),
        thread_name(TID_USBMUX_BULK, "usbmux pkts (61031↔3 bulk)"),
        thread_name(TID_USBMUX_HB, "usbmux pkts (:9002 hb)"),
        thread_name(TID_USBMUX_INFLIGHT, "usbmux IN inflight bytes (max/bucket)"),
        thread_name(TID_INPUT_WIRE, "input.wire max ms (bucket)"),
    ]
    all_bucket_ids = sorted(set(usbmux_buckets) | set(wire_buckets))
    for b in all_bucket_ids:
        ts_us = (b * bucket_ms + bucket_ms / 2) * 1000
        u = usbmux_buckets.get(b)
        if u and (u["in_total"] or u["out_total"]):
            events.append(
                counter_event(
                    ts_us,
                    TID_USBMUX_TOTAL,
                    "usbmux.total",
                    {"in": u["in_total"], "out": u["out_total"]},
                )
            )
            if u["in_app"] or u["out_app"]:
                events.append(
                    counter_event(
                        ts_us,
                        TID_USBMUX_APP,
                        "usbmux.app",
                        {"in": u["in_app"], "out": u["out_app"]},
                    )
                )
            if u["in_bulk"] or u["out_bulk"]:
                events.append(
                    counter_event(
                        ts_us,
                        TID_USBMUX_BULK,
                        "usbmux.bulk",
                        {"in": u["in_bulk"], "out": u["out_bulk"]},
                    )
                )
            if u["in_hb"] or u["out_hb"]:
                events.append(
                    counter_event(
                        ts_us,
                        TID_USBMUX_HB,
                        "usbmux.hb",
                        {"in": u["in_hb"], "out": u["out_hb"]},
                    )
                )
            if u["inflight_max"]:
                events.append(
                    counter_event(
                        ts_us,
                        TID_USBMUX_INFLIGHT,
                        "usbmux.inflight",
                        {"max_bytes": u["inflight_max"]},
                    )
                )
        wire_max = wire_buckets.get(b, 0)
        if wire_max > 0:
            events.append(
                counter_event(
                    ts_us,
                    TID_INPUT_WIRE,
                    "input.wire",
                    {"max_ms": round(wire_max, 2)},
                )
            )
    return events


def strip_usbmux_instants(events: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    kept: list[dict[str, Any]] = []
    removed = 0
    for ev in events:
        if ev.get("tid") == USBMUX_INSTANT_TID and ev.get("ph") == "i":
            removed += 1
            continue
        if ev.get("tid") == USBMUX_INSTANT_TID and ev.get("ph") == "M":
            removed += 1
            continue
        kept.append(ev)
    return kept, removed


def resolve_session_path(perfetto_path: Path, session_path: Path | None) -> Path:
    if session_path is not None:
        return session_path
    stem = perfetto_path.name
    if stem.endswith(".perfetto.json"):
        stem = stem[: -len(".perfetto.json")]
    elif stem.endswith(".json"):
        stem = stem[: -len(".json")]
    for candidate in (
        perfetto_path.with_name(f"{stem}.session.json"),
        perfetto_path.parent / f"{stem}.session.json",
    ):
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        f"No session JSON found for {perfetto_path}; pass --session explicitly"
    )


def transform(
    perfetto_path: Path,
    session_path: Path | None,
    bucket_ms: float,
    keep_instants: bool,
) -> Path:
    session_path = resolve_session_path(perfetto_path, session_path)
    with perfetto_path.open() as f:
        trace = json.load(f)
    with session_path.open() as f:
        session = json.load(f)

    usbmux = session.get("usbmuxEvents") or []
    if not usbmux:
        raise SystemExit(f"No usbmuxEvents in {session_path}")

    origin_ms = float(trace.get("metadata", {}).get("origin_ms") or min_origin_ms(session))
    usbmux_buckets = aggregate_usbmux(usbmux, origin_ms, bucket_ms)
    wire_buckets = aggregate_input_wire(session.get("macSpans") or [], origin_ms, bucket_ms)
    counter_events = build_counter_events(usbmux_buckets, wire_buckets, origin_ms, bucket_ms)

    trace_events = trace.get("traceEvents") or []
    if not keep_instants:
        trace_events, removed = strip_usbmux_instants(trace_events)
    else:
        removed = 0

    trace_events.extend(counter_events)
    metadata = dict(trace.get("metadata") or {})
    metadata["usbmux_layout"] = "counter_buckets"
    metadata["usbmux_bucket_ms"] = str(int(bucket_ms))
    metadata["usbmux_instant_events_removed"] = str(removed)
    metadata["usbmux_counter_buckets"] = str(len(usbmux_buckets))

    out_path = perfetto_path.with_name(
        perfetto_path.name.replace(".perfetto.json", ".volume.perfetto.json")
        if ".perfetto.json" in perfetto_path.name
        else f"{perfetto_path.stem}.volume.json"
    )
    out = {"metadata": metadata, "traceEvents": trace_events}
    with out_path.open("w") as f:
        json.dump(out, f, indent=2, sort_keys=True)
    return out_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("perfetto", type=Path, help="Existing .perfetto.json export")
    parser.add_argument(
        "--session",
        type=Path,
        default=None,
        help="Session JSON with usbmuxEvents (default: sibling .session.json)",
    )
    parser.add_argument(
        "--bucket-ms",
        type=float,
        default=20.0,
        help="Time bucket width in ms (default: 20)",
    )
    parser.add_argument(
        "--keep-instants",
        action="store_true",
        help="Keep original usbmux instant events (noisy)",
    )
    args = parser.parse_args()

    if not args.perfetto.exists():
        raise SystemExit(f"Not found: {args.perfetto}")

    out = transform(args.perfetto, args.session, args.bucket_ms, args.keep_instants)
    print(f"Wrote {out}")
    print("Open in https://ui.perfetto.dev — look for usbmux pkts / inflight / input.wire counter tracks.")


if __name__ == "__main__":
    main()
