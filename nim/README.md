# The Nim core

The program. It owns the state, the screens and the IRC connection, and the
widget tree the screens emit is painted in Nim too:
`kit/` walks it into nimkit widgets, on GTK or in a page.

```
src/nirc_core.nim        the C ABI: every exported symbol, and nothing else
src/nirc/ui.nim          the widget tree, in the screens' own tag vocabulary
src/nirc/cells.nim       every piece of state the screens read
src/nirc/reducer.nim     every event they can send, and what it does
src/nirc/model.nim       what a message and a room are
src/nirc/rooms.nim       the list and the read marker
src/nirc/members.nim     who is in a channel, and what the server says of them
src/nirc/conn.nim        the socket, the TLS, the line framing
src/nirc/ircparse.nim    the IRC wire format
src/nirc/handshake.nim   CAP negotiation and SASL PLAIN
src/nirc/multiline.nim   draft/multiline batches, put back together
src/nirc/commands.nim    /join, /msg, /whois and the rest
src/nirc/emoji.nim       1,884 emoji — generated, see below
src/nirc/glyphs.nim      a line split into words and pictures
src/nirc/clock.nim       server time in the reader's own zone
src/nirc/store.nim       what survives a restart
src/nirc/screens/        connect, chats, chat, discover, settings

kit/nirckit/render.nim   the tag vocabulary, as nimkit widgets, keyed
kit/nirckit/theme.nim    the palette, as a GTK CSS sheet and a web one
kit/nirc_desktop.nim     the GTK host, built as ../build/nirc
web/nirc/                the browser's conn and store, by search path
web/nirc_app.nim         the browser app: the seam, the renderer, nimkit's DOM
web/nirc_web.nim         the seam alone (`globalThis.nirc`), for the node tests
vendor/nimkit/          nimkit, vendored from nandi-conda/webby, with nirc's
                        additions; GTK 3 and web backends, no Android
```

`nim.cfg` puts `vendor/nimkit` and `kit` on the search path for every compile
here. The core and its tests import neither; they are there so no recipe has
to spell them out. Changes to nimkit are made in `vendor/nimkit` — it is nirc's
copy now, and the additions (pictures, wrapping rows, the caret, `reveal`,
`onFollow`, `onWindowSize`, GTK's bottom-up `resizeUp`) are not upstream.

## The ABI

The app no longer goes through it: the desktop links the core directly and
the page calls `globalThis.nirc`. It still builds, as `pixi run build lib`, and
`nirc_ui_demo` in it is what the desktop's `NIRC_DEMO=1` opens on.

Strings in, strings out, and JSON where the answer is not a single string —
deliberately, against a struct-based ABI: a struct means both sides agreeing
on a memory layout, and a field added later is a version skew that segfaults
instead of failing.

Two rules, both of which cost a segfault to rediscover:

* Every string the core returns is the **caller's** to free, with `nirc_free`.
  Nim's allocator is not the caller's.
* `nirc_init` exists and does nothing. It used to call `NimMain`, and on Linux
  `--app:lib` already runs the module initialisers from a library constructor
  — so calling it again ran every module's top-level code a second time, which
  for `conn.nim` meant `open()` on channels that were already open.

## Things that will bite

* **Nothing is shared with the socket threads.** There are two — one reader,
  one writer — and they speak only in channels. `recvLine(timeout)` does not
  time out on a TLS socket, so a single thread cannot both wait for the server
  and notice what the client wants to say.
* **`--mm:orc`, not refc.** refc gives each thread its own GC heap, so the
  `Socket` the two threads share is a ref from another heap and dereferencing
  it segfaults.
* **Every intra-package import says `nirc/…`.** `import conn` and
  `import nirc/conn` name the same file by two paths and Nim compiles it twice,
  giving two sets of globals and two states.
* **`emoji.nim` is generated.** It was `tools/emoji2nim.py` reading the
  ClojureDart catalogue, which is gone; regenerating it now means going back to
  Unicode's `emoji-test.txt` and filtering to what the Twemoji pack draws.
```bash
pixi run test nim              # the whole suite
pixi run test nim tircparse    # one file
pixi run test web              # the JavaScript build, under node
pixi run test desktop          # the GTK app compiled: nimkit and the renderer agree
pixi run build lib             # libnirccore.so into build/nim
```

## What is not here

Edits (there is no ratified IRCv3 edit), file uploads (no standard either),
avatars and link previews (both need a service beside the IRC server), and
`did:`-anything. nirc began as frq, a client for freeq, and those were freeq's.
