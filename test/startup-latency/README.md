# Startup latency instrument

Measures how long the GUI takes to show its first row in the session list, and whether the event loop stays responsive while the list fills. This file defines the acceptance gate for startup work: first row <= 1.0s from process launch, read off screenshots. Frames are the accepted evidence because a self-reported timer misses failure modes (it can print "loaded" while the loader that would print it has died).

## Running

```
./measure.sh            # results in a fresh /tmp dir; path printed
./measure.sh /tmp/run1  # or name the dir
```

Needs Xvfb, ImageMagick `import`, and wish9.0. Run it twice per change; the numbers are stable to ~0.1s. If invoking through a sandboxed shell, disable the sandbox for the run (it blocks `import`'s X connection).

## Reading the output

- The frame-change timeline lists each moment the screen content changed (seconds after launch, PNG byte size). The window maps at the first jump from the blank-screen size; the first row is the next jump. Confirm by opening the named frame: the row region is the left column under the Session/Date header bar.
- The "ping round-trips over 150ms" list shows how long the event loop took to answer. A healthy loop answers in ~0ms; multi-second round-trips mean the loop was blocked and clicks would have sat unprocessed that long.

## Baseline (2026-07-17, corpus of 3,944 sessions, 757 in the default 1-week window)

| Event | Time from launch |
|---|---|
| Window mapped | 0.33s |
| First row visible | 10.1-10.2s |
| Event loop | blocked in 2-3s chunks until the fill |

All rows landed in a single repaint; the cost column then streamed for a further 30s or so, which is expected. The block came from the scan coroutine's chunk size (200 files x ~13ms per file) and its 1ms resume timer starving Tk's idle-priority repaints.
