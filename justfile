# Four verbs over one tree.
#
# There is no nix here. `tools/toolchain.sh` fetches Nim as a sha256-pinned
# tarball into `.toolchain/`, and every recipe below runs inside the
# environment that script prints.
#
# What the host still brings: a C compiler (Nim shells out to one), OpenSSL
# (nim.cfg is `-d:ssl`), git, curl, python3, and for the desktop, GTK 3 and
# pkg-config. `test web` wants node.
#
#   just build TARGET      desktop web lib core-js
#   just run TARGET        desktop web
#   just test SUITE        all nim web desktop
#   just tools ...         the toolchain itself

set shell := ["bash", "-euo", "pipefail", "-c"]

# Every recipe is a `#!` script. Without this, "$@" is empty in one of them —
# just interpolates into a shebang recipe rather than handing it argv.
set positional-arguments

root := justfile_directory()
tc := justfile_directory() / "tools/toolchain.sh"

default:
    @just --list

# The toolchain, directly: `just tools versions`,
# `just tools exec -- nim --version`.
[doc('the toolchain itself: versions, exec -- CMD')]
tools *args:
    #!/usr/bin/env bash
    cd "{{root}}"
    exec "{{tc}}" "$@"

# Build a target.
#
#   desktop    the app on GTK, as build/nirc: the core, and nimkit painting it
#   web        the same, in a browser, as build/web: the core and its
#              renderer compiled by `nim js`, beside the page in web/
#   lib        the core alone, as build/nim/libnirccore.so
#   core-js    the core alone, as build/web/nirc_core.js
#
# There used to be an APK, and a Flutter renderer over both of the first two.
# The APK went with ClojureDart and the renderer with Flutter: nimkit draws
# the same widget tree on GTK and in a page, so there is one language left.
[doc('build a target: desktop web lib core-js')]
build target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _desktop ;;
        web)     just _web-bundle ;;
        lib)     just _nim-lib ;;
        core-js) just _nim-js ;;
        *)       echo "usage: just build [desktop|web|lib|core-js]" >&2; exit 1 ;;
    esac

# Build a target and start it.
#
#   NIRC_TRACE=1        every line in and out
#   NIRC_AUTOCONNECT=1  press Connect at startup, for a window a script cannot
#                      click; NIRC_NICK overrides the nickname
#   NIRC_DEMO=1         open on a representative room, no server
#   NIRC_THEME=dark     or light; otherwise the desktop's own
[doc('build the app and start it: desktop web')]
run target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        # Nim resolves OpenSSL through dynlib at run time; without the host
        # library on the loader path `newContext` dies in a SIGSEGV that says
        # nothing about SSL.
        desktop) just _desktop
                 export LD_LIBRARY_PATH="${NIRC_OPENSSL_LIB:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                 exec build/nirc ;;
        web)     just _web-bundle
                 exec python3 tools/webserve.py 8000 build/web ;;
        *)       echo "usage: just run [desktop|web]" >&2; exit 1 ;;
    esac

# Test a suite.
#
#   nim      the Nim core. No GTK and no browser — a rule about the IRC wire
#            format is checkable in a second.
#   web      the JavaScript build of the same core, driven as a browser
#            drives it, and the page's own app compiled. Needs node.
#   desktop  the GTK app compiled, which is the check that nimkit and the
#            renderer still agree. Needs GTK's headers, not a display.
#   just test              all of them
#   just test nim tircparse    one Nim file
[doc('run a suite: all nim web desktop')]
test suite="all" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift
    case "{{suite}}" in
        all)     just test nim && just test web && just test desktop ;;
        nim)     just _nim-test "$@" ;;
        web)     just _nim-js
                 just _app-js
                 exec node nim/web/test/smoke.js build/web/nirc_core.js ;;
        desktop) just _desktop ;;
        *)       echo "usage: just test [all|nim|web|desktop]" >&2; exit 1 ;;
    esac

# The web bundle: the page in web/, and the app compiled beside it.
#
# Copied rather than built into: web/ is source, and build/web is what a
# server serves — `just run web` here, or any static host.
[private]
_web-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    rm -rf build/web
    mkdir -p build/web
    cp -r web/. build/web/
    just _app-js
    echo "built build/web"

# The app for a page: the core, its renderer and nimkit's web backend, as one
# script. The main module lives under `nim/web`, and Nim resolves
# command-line search paths from that directory. `../src` is the shared tree
# and `.` is the web tree; the later path wins, so every module under
# `nim/web/nirc` shadows the one beside it in `nim/src/nirc`. Thus `nirc/conn` is
# a queue the host fills rather than two socket threads, and the shared code
# above them never learns which host it is on.
[private]
_app-js:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/web"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim js -d:release --hints:off \
            --path:../src --path:. --out:"'"$out"'/nirc.js" web/nirc_app.nim
        printf "built %s (%s)\n" "'"$out"'/nirc.js" \
            "$(gzip -9c "'"$out"'/nirc.js" | wc -c | awk "{printf \"%d KB gzipped\", \$1/1024}")"'

# The core alone as JavaScript, for the node tests: the same seam the page
# uses, with no renderer and no DOM.
[private]
_nim-js:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/web"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim js -d:release --hints:off \
            --path:../src --path:. --out:"'"$out"'/nirc_core.js" web/nirc_web.nim
        printf "built %s (%s)\n" "'"$out"'/nirc_core.js" \
            "$(gzip -9c "'"$out"'/nirc_core.js" | wc -c | awk "{printf \"%d KB gzipped\", \$1/1024}")"'

[private]
_nim-lib:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/nim"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim c --app:lib --mm:orc -d:release --hints:off \
            --path:src --out:"'"$out"'/libnirccore.so" src/nirc_core.nim
        echo "built '"$out"'/libnirccore.so"
        nm -D --defined-only "'"$out"'/libnirccore.so" | grep " T nirc_" || true'

[private]
_nim-test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        if [ -n "${1:-}" ]; then
            exec nim c -r --hints:off --path:src "tests/$1.nim"
        fi
        for t in tests/t*.nim; do
            echo "== $t"
            nim c -r --hints:off --path:src "$t"
        done' _ "$@"

# The desktop app, as one binary. nimkit's GTK backend takes its flags from
# pkg-config, so GTK's headers are all it needs from the host.
[private]
_desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    mkdir -p build
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim c -d:release --hints:off --out:"'"{{root}}"'/build/nirc" kit/nirc_desktop.nim
        echo "built '"{{root}}"'/build/nirc"'
