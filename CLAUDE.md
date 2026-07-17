# questlog: agent notes

## Invariants

- A root-level .tm is either a copy vendored from ../teatotal or a module authored here, and the two carry opposite rules: a vendored copy is a pure copy, so keep it synced to ../teatotal's latest and land any change there first; an authored module has its home here, so changes land here, and where another project vendors it, re-vendor it there in the same act so the copies never diverge. Each module's header names its home; read it before editing.

## Verifying GUI changes

questlog is a Tcl/Tk app launched with `./questlog` (it runs under `tclsh9.0`). Verify visual or behavioural changes on a headless Xvfb display, never the user's real `DISPLAY=:0`: launching on :0 puts windows over the user's work where they may click or close them, and ImageMagick `import`'s X11 grab is unreliable under this machine's XWayland :0 (it returns an empty image and fails with "missing an image filename"). On a private Xvfb server `import` works.

Xvfb must be installed for headless verification to work (`apt install xvfb`). Tk 9 needs the XKEYBOARD extension at display open; this machine's Xvnc/Xtightvnc omits it, so Tk fails on it with a bare "couldn't connect to display" even while plain X clients (xdpyinfo, xterm) connect fine, and Xorg.wrap's console-user policy blocks Xdummy.

Run the Bash tool with its sandbox disabled for the capture (the sandbox blocks `import`'s X connection):

```
Xvfb :99 -screen 0 1500x1150x24 >/tmp/xvfb.log 2>&1 & XVFB=$!; sleep 2
DISPLAY=:99 ./questlog >/tmp/ql.log 2>&1 & APP=$!
for i in $(seq 1 24); do WID=$(DISPLAY=:99 xdotool search --name questlog|head -1); [ -n "$WID" ] && break; sleep .5; done
sleep 2
DISPLAY=:99 import -window root out.png       # whole virtual screen; crop to $WID geometry if wanted
# ...drive via send, re-capture...
kill $APP $XVFB
```

A boot smoke check needs no interaction: `DISPLAY=:99 timeout 4 ./questlog` self-terminates (exit 124 means it ran the full window without crashing). Pin the display: a bare invocation inherits the caller's `DISPLAY` and flashes the window on :0.

Drive the UI with Tk `send`, not `xdotool` synthetic input (clicks and keystrokes are silently dropped under XWayland). On :99 the app is the only interp, registered as appname `questlog`; reach a live object through it, for example: `echo 'send questlog {set o [lindex [info class instances ::questlog::ui::Toolbar] 0]; $o begin_edit file; update}; exit' | DISPLAY=:99 wish9.0`.

Run the test suite the same way. Some tests `package require Tk`, so run them on :99 (or with no DISPLAY, where they skip) rather than letting them flash windows on :0.

Cleanup: kill only the PIDs you launched. Never `pkill wish9.0` or `tclsh9.0` by name: the user's own questlog runs as `tclsh9.0 ./questlog`, and a blanket pkill kills it.

Tcl 9 removed tilde expansion: `open`/`file` on a `~/...` path fails (or opens a literal `./~` path) rather than reaching the home directory. Build paths with `$env(HOME)` or `file home` in tests and drivers.
