# Lyrimuse Release Qualification & UX Benchmark Report

**Date:** 2026-09-17T05:57:29Z
**Status:** ✅ RELEASE QUALIFIED (All Invariants Passed)

## 1. Menu Bar Slot Stability & Anti-Jitter

| Metric | Baseline (Naive) | Production (`MenuBarSlotFloor`) | Target | Status |
|---|---|---|---|---|
| Total Rebuild Count | 28 | 9 | Minimum Necessary | ✅ Passed |
| Within-Song Shrinks | 13 | 0 | 0 (Strict Monotonic) | ✅ Passed |
| Fake Pause Collapses (< 8s) | 3 | 0 | 0 (Geometry Hold) | ✅ Passed |
| Rebuild Reduction | - | 67.9% | > 50% Reduction | ✅ Passed |

**Key Invariants Verified:**
- Slot width only expands monotonically within a song (`trackKey = title + "\u{1F}" + artist`).
- Reset occurs strictly across song boundaries.
- Fabricated and temporary pauses (< 8.0s) maintain geometry without collapsing the menu bar icon slot.
- Sticky settle window (0.12s) prevents premature rebuilds on provisional targets.

---

## 2. Sync Engine Tick Latency (20Hz & 60Hz)

| Workload | Avg Latency | P50 Latency | P95 Latency | P99 Latency | Max Latency | Frame Drops | Target (< 0.2ms) |
|---|---|---|---|---|---|---|---|
| **20Hz Clock** (50ms interval) | 0.0051 ms | 0.0053 ms | 0.0055 ms | 0.0071 ms | 0.0441 ms | 0 | ✅ Passed |
| **60Hz Clock** (16.67ms interval) | 0.0069 ms | 0.0053 ms | 0.0057 ms | 0.0158 ms | 5.9437 ms | 0 | ✅ Passed |

---

## 3. Enrich Cache Lookup Performance

| Tier | Strategy | Throughput | Avg Latency | P95 Latency | Max Latency | Match Accuracy | Status |
|---|---|---|---|---|---|---|---|
| **Tier 1** | Exact `artist\|title\|album` hash match | 38873 ops/s | 23.829 µs | 30.500 µs | 19338.791 µs | 100.00% | ✅ Passed |
| **Tier 2** | Case / whitespace loose match | 27973 ops/s | 34.066 µs | 49.333 µs | 14293.584 µs | 100.00% | ✅ Passed |
| **Tier 3** | Mismatched / empty album fallback | 25743 ops/s | 37.352 µs | 52.042 µs | 214.125 µs | 100.00% | ✅ Passed |

---

## 4. Conclusion
All automated benchmarks verify that the implementation satisfies the menu bar slot stability invariants, high-frequency tick latency budget (< 0.2ms), and multi-tier enrich cache lookup performance required for production release.