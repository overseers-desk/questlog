# Startup latency instrument

Measures how long the GUI takes to show its first row in the session list, and whether the event loop stays responsive while the list fills. This file defines the acceptance gate for startup work: first row <= 1.0s from process launch, read off screenshots. Frames are the accepted evidence because a self-reported timer misses failure modes (it can print "loaded" while the loader that would print it has died).

The instrument launches the real app, which reads the operator's live `~/.claude/projects` (resolved via `lib/path.tcl`'s `projects_root`, i.e. the home directory of whoever runs it). The corpus is live: it grows between runs and differs across accounts and machines, so absolute numbers travel poorly. Compare before/after pairs taken close together on the same host, not one machine's number against another's.

Host contention inflates the numbers: concurrent Claude Code sessions on the same machine write into the corpus and compete for CPU and disk during a run. There is one known residual stall either way: a single roughly 1.2s pause near the end of the pass (around the 9.5s mark on this corpus), from one heavy file's scan. It appears in every measured configuration and does not affect the first-row reading.

## Running

```
./measure.sh            # results in a fresh /tmp dir; path printed
./measure.sh /tmp/run1  # or name the dir
```

Needs Xvfb, ImageMagick `import`, and wish9.0. Run it twice per change; the numbers are stable to ~0.1s. If invoking through a sandboxed shell, disable the sandbox for the run (it blocks `import`'s X connection).

## Reading the output

- The frame-change timeline lists each moment the screen content changed (seconds after launch, PNG byte size). The window maps at the first jump from the blank-screen size; the first row is the next jump. Confirm by opening the named frame: the row region is the left column under the Session/Date header bar.
- The "ping round-trips over 150ms" list shows how long the event loop took to answer. A healthy loop answers in ~0ms; multi-second round-trips mean the loop was blocked and clicks would have sat unprocessed that long.

## Current behaviour

Measured with this instrument on 2026-07-17:

| Event | Time from launch |
|---|---|
| Window mapped | 0.33-0.42s |
| First row visible | 0.78-0.85s on a busy host, 0.79-0.83s on a quiet one |
| Rows | stream in as the scan progresses |

The cost column keeps filling for tens of seconds after the first rows appear, which is expected. The scan coroutine yields every 20 files (`scan_yield_files` in `config.tcl`) and each chunk boundary paints what it added (`update idletasks` in `on_scan_progress`, `ui/app.tcl`), so the list stays live throughout.

## Why the instrument exists

Before the fix, `scan_yield_files` was 200: the scan blocked the event loop in 2-3s chunks and the first row waited 10.1-10.2s behind them. Shrinking the chunks was not enough on its own: without the chunk-boundary paint, a busy host let queued cost-worker events defer the first paint to 1.15-1.25s even though the loop answered pings in ~300ms.
