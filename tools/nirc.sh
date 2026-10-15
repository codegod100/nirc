#!/usr/bin/env bash
# Build, run and test nirc. pixi supplies everything this calls — Nim, a C
# compiler, OpenSSL, GTK 3, pkg-config, node and python — so run it through
# the tasks in pixi.toml:
#
#   pixi run build [desktop|web|lib|core-js]
#   pixi run start [desktop|web]
#   pixi run test  [all|nim|web|desktop] [tests/<file> stem]
#
# Running it outside pixi works too, given those tools on PATH.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

gz() { gzip -9c "$1" | wc -c | awk '{printf "%d KB gzipped", $1/1024}'; }

# The app for a page: the core, its renderer and nimkit's web backend, as one
# script. The main module lives under `nim/web`, and Nim resolves
# command-line search paths from that directory. `../src` is the shared tree
# and `.` is the web tree; the later path wins, so every module under
# `nim/web/nirc` shadows the one beside it in `nim/src/nirc`.
app_js() {
    local out="$root/build/web"
    mkdir -p "$out"
    (cd nim && nim js -d:release --hints:off \
        --path:../src --path:. --out:"$out/nirc.js" web/nirc_app.nim)
    echo "built $out/nirc.js ($(gz "$out/nirc.js"))"
}

# The core alone as JavaScript, for the node tests: the same seam the page
# uses, with no renderer and no DOM.
core_js() {
    local out="$root/build/web"
    mkdir -p "$out"
    (cd nim && nim js -d:release --hints:off \
        --path:../src --path:. --out:"$out/nirc_core.js" web/nirc_web.nim)
    echo "built $out/nirc_core.js ($(gz "$out/nirc_core.js"))"
}

# The page in web/, and the app compiled beside it. Copied rather than built
# into: web/ is source, and build/web is what a server serves.
web_bundle() {
    rm -rf build/web
    mkdir -p build/web
    cp -r web/. build/web/
    app_js
    echo "built build/web"
}

lib() {
    local out="$root/build/nim"
    mkdir -p "$out"
    (cd nim && nim c --app:lib --mm:orc -d:release --hints:off \
        --path:src --out:"$out/libnirccore.so" src/nirc_core.nim)
    echo "built $out/libnirccore.so"
}

# The desktop app, as one binary. nimkit's GTK backend takes its flags from
# pkg-config, so GTK's headers are all it needs.
desktop() {
    mkdir -p build
    (cd nim && nim c -d:release --hints:off --out:"$root/build/nirc" \
        kit/nirc_desktop.nim)
    echo "built $root/build/nirc"
}

nim_test() {
    cd nim
    if [ -n "${1:-}" ]; then
        exec nim c -r --hints:off --path:src "tests/$1.nim"
    fi
    for t in tests/t*.nim; do
        echo "== $t"
        nim c -r --hints:off --path:src "$t"
    done
}

cmd="${1:-}"; shift || true
case "$cmd" in
    build)
        case "${1:-desktop}" in
            desktop) desktop ;;
            web)     web_bundle ;;
            lib)     lib ;;
            core-js) core_js ;;
            *) echo "usage: pixi run build [desktop|web|lib|core-js]" >&2; exit 1 ;;
        esac ;;
    start)
        case "${1:-desktop}" in
            # Nim resolves OpenSSL through dynlib at run time; it has to be on
            # the loader path, or `newContext` dies in a SIGSEGV that says
            # nothing about SSL.
            desktop) desktop
                     if [ -n "${CONDA_PREFIX:-}" ]; then
                         export LD_LIBRARY_PATH="$CONDA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                     fi
                     exec build/nirc ;;
            web)     web_bundle
                     exec python3 tools/webserve.py "${PORT:-8000}" build/web ;;
            *) echo "usage: pixi run start [desktop|web]" >&2; exit 1 ;;
        esac ;;
    test)
        suite="${1:-all}"; shift || true
        case "$suite" in
            all)     "$0" test nim && "$0" test web && "$0" test desktop ;;
            nim)     nim_test "$@" ;;
            web)     core_js
                     app_js
                     exec node nim/web/test/smoke.js build/web/nirc_core.js ;;
            desktop) desktop ;;
            *) echo "usage: pixi run test [all|nim|web|desktop]" >&2; exit 1 ;;
        esac ;;
    *) echo "usage: tools/nirc.sh build|start|test ..." >&2; exit 1 ;;
esac
