#!/usr/bin/env bash
#
# Build the self-contained single-file questlog image: an executable that runs
# on a host with no Tcl installed. It stubs `zipfs mkimg` on a from-source Tcl 9
# whose libtcl/libtk are statically linked and whose script library is embedded,
# so the result links only libc and the platform GUI substrate (X11 on Linux).
#
# Stages, all from source so nothing is inherited from the build host's Tcl:
#   1. static Tcl 9   (--disable-shared --enable-zipfs)
#   2. static Tk 9    (--disable-shared, against that Tcl)
#   3. static Thread  (--disable-shared); a binary extension, so it cannot live
#                     in zipfs and must be linked into the interpreter
#   4. a custom wish  (zipfs/appinit.c) linking the three, registering Tk and
#                     Thread as static libraries
#   5. a runtime tree (tcl_library/, tk_library/, embedded tcllib json) handed
#                     to zipfs/build.tcl, which stages questlog's payload and
#                     folds everything onto the custom wish.
#
# Build dependencies:
#   Linux (Debian/Ubuntu names; the CI workflow installs them):
#     build-essential libx11-dev libxext-dev libxft-dev libfontconfig1-dev \
#     libxss-dev zlib1g-dev curl
#   macOS: the Xcode command-line tools (cc, make) and curl, both present on
#     GitHub macOS runners. Tk builds against the system Aqua frameworks.
#
# Usage:
#   zipfs/build-selfcontained.sh            # builds dist/questlog-<ver>-linux-<arch>
#   BUILD_DIR=/path zipfs/build-selfcontained.sh
#
# Shares stages 1-4 with the AppImage (#9): the from-source static interpreter
# is the same; the AppImage adds the X11 .so closure and desktop integration.

set -euo pipefail

# Dependency versions. Tcl/Tk track the same release; Thread and tcllib are the
# current releases compatible with Tcl 9.
TCL_VER="${TCL_VER:-9.0.2}"
TK_VER="${TK_VER:-9.0.2}"
THREAD_VER="${THREAD_VER:-3.0.1}"
TCLLIB_VER="${TCLLIB_VER:-2.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/questlog-selfcontained.XXXXXX")}"
SRC="$BUILD_DIR/src"
STAGE="$BUILD_DIR/interp"      # install prefix for the from-source interpreter
RUNTIME="$BUILD_DIR/runtime"   # script-library tree overlaid into the image
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
OS="$(uname -s)"
CC="${CC:-cc}"

mkdir -p "$SRC" "$STAGE" "$RUNTIME"
echo "build dir: $BUILD_DIR"

fetch() {
    # fetch URL OUTFILE — download and verify it untars
    local url="$1" out="$2"
    curl -fsSL --retry 3 -o "$SRC/$out" "$url"
    tar tzf "$SRC/$out" >/dev/null
}

echo "== fetching sources =="
fetch "https://prdownloads.sourceforge.net/tcl/tcl${TCL_VER}-src.tar.gz"      "tcl.tar.gz"
fetch "https://prdownloads.sourceforge.net/tcl/tk${TK_VER}-src.tar.gz"        "tk.tar.gz"
fetch "https://prdownloads.sourceforge.net/tcl/thread${THREAD_VER}.tar.gz"    "thread.tar.gz"
fetch "https://prdownloads.sourceforge.net/tcllib/tcllib-${TCLLIB_VER}.tar.gz" "tcllib.tar.gz"
for f in tcl tk thread tcllib; do tar xzf "$SRC/$f.tar.gz" -C "$SRC"; done

TCL_SRC="$SRC/tcl${TCL_VER}"
TK_SRC="$SRC/tk${TK_VER}"
THREAD_SRC="$SRC/thread${THREAD_VER}"
TCLLIB_SRC="$SRC/tcllib-${TCLLIB_VER}"

echo "== 1. static Tcl =="
( cd "$TCL_SRC/unix"
  ./configure --disable-shared --enable-zipfs --prefix="$STAGE"
  make -j"$JOBS"
  make install )

echo "== 2. static Tk =="
# macOS Tk renders through Aqua (Cocoa frameworks), Linux Tk through X11/Xft.
if [ "$OS" = "Darwin" ]; then
    TK_CONFIG_FLAGS="--enable-aqua"
else
    TK_CONFIG_FLAGS="--enable-xft --enable-xss"
fi
( cd "$TK_SRC/unix"
  ./configure --disable-shared $TK_CONFIG_FLAGS \
      --with-tcl="$TCL_SRC/unix" --prefix="$STAGE"
  make -j"$JOBS"
  make install )

echo "== 3. static Thread =="
( cd "$THREAD_SRC"
  ./configure --disable-shared --with-tcl="$TCL_SRC/unix" --prefix="$STAGE"
  make -j"$JOBS" )
THREAD_A="$(echo "$THREAD_SRC"/*thread${THREAD_VER}.a)"
[ -f "$THREAD_A" ] || { echo "static Thread lib not found" >&2; exit 1; }

echo "== 4. custom wish =="
# Link specs (X11/font libs, zlib, pthread) come from the generated config so
# they track what Tk was actually built against.
# shellcheck disable=SC1091
. "$STAGE/lib/tclConfig.sh"
# shellcheck disable=SC1091
. "$STAGE/lib/tkConfig.sh"
WISH="$BUILD_DIR/questlog-wish"
$CC -o "$WISH" "$REPO_ROOT/zipfs/appinit.c" \
    -I"$STAGE/include" \
    "$STAGE/lib/libtcl9tk${TK_VER%.*}.a" \
    "$STAGE/lib/libtcl${TCL_VER%.*}.a" \
    "$THREAD_A" \
    "$STAGE/lib/libtclstub.a" \
    $TK_LIBS
# The image must carry no Tcl/Tk/Thread shared dependency.
if [ "$OS" = "Darwin" ]; then
    deps="$(otool -L "$WISH")"
else
    deps="$(ldd "$WISH")"
fi
if echo "$deps" | grep -Eiq 'libtcl|libtk9|libthread'; then
    echo "wish unexpectedly links a Tcl/Tk/Thread shared library:" >&2
    echo "$deps" >&2
    exit 1
fi

echo "== 5. runtime tree + image =="
# The static install embeds its script library only in the zip appended to the
# stock tclsh, not on disk, so the authoritative library trees are the source
# library/ dirs (which is what got zipped). Embed tcllib json under the
# interpreter library so every fresh worker interp resolves it on auto_path.
cp -a "$TCL_SRC/library" "$RUNTIME/tcl_library"
cp -a "$TK_SRC/library"  "$RUNTIME/tk_library"
mkdir -p "$RUNTIME/tcl_library/json"
cp "$TCLLIB_SRC"/modules/json/*.tcl "$RUNTIME/tcl_library/json/"

QUESTLOG_WISH="$WISH" QUESTLOG_RUNTIME="$RUNTIME" \
    "$STAGE/bin/tclsh${TCL_VER%.*}" "$REPO_ROOT/zipfs/build.tcl"

echo "done. Keep \$BUILD_DIR for reuse, or rm -rf $BUILD_DIR"
