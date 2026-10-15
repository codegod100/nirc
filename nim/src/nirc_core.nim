## The C ABI, and nothing else.
##
## Every exported symbol is here so there is one file to read when asking what
## the Dart side can call. The logic lives under `nirc/` in ordinary Nim with
## ordinary Nim types, which is what lets the tests test the rules rather than
## the marshalling.
##
## Two conventions, both of which the bindings in `flutter/src/nirc/core/`
## wrap so no call site has to remember them:
##
## * Every returned string is the **caller's** to free, with `nirc_free`. Nim's
##   allocator is not Dart's, so a `free()` on this side of the boundary is
##   undefined behaviour rather than a leak you can live with.
## * `nirc_init` runs once before anything else. Nim's runtime needs setting up
##   and `--app:lib` does not do it for you on every platform.
##
## Answers that are not a single string come back as JSON. A struct would mean
## both sides agreeing on a memory layout, and a field added later would be a
## version skew that segfaults rather than one that fails; JSON costs a parse
## per call, which is nothing against the network round trip that produced the
## line being parsed.
##
## The UI half of this ABI — `nirc_ui_render` and `nirc_ui_dispatch` — is Nim
## owning the screens as well as the rules. The screens under it are ported
## from `common/nirc/screens/` rather than reimagined, which is the difference
## between this and the experiment that was deleted for being a facsimile.

import std/[json, tables]
import nirc/[ircparse, trace, cells, reducer, model, rooms, eintr, tree]
import nirc/conn as tr

proc nirc_init*() {.exportc, dynlib.} =
  ## Reads what the last run saved, and otherwise stays out of the way.
  ##
  ## It used to call `NimMain()`. On Linux `--app:lib` already emits a library
  ## constructor that runs Nim's module initialisers at dlopen, so calling it
  ## again ran every module's top-level code a SECOND time — which for
  ## `conn.nim` meant `outbound.open()` on channels that were already open,
  ## quietly resetting them. The reader thread then drained a different queue
  ## from the one the writer filled, and nothing this client sent ever left.
  ##
  ## So it stayed empty for a long time. What it does now is the one thing
  ## that genuinely belongs before the first frame and cannot go in
  ## `initState`, which is a `func` and touches no disk: restoring the saved
  ## server, rooms and preferences.
  ##
  ## `nirc_ui_reset` deliberately does not do this. It is the tests' entry
  ## point, and a suite that picked up whoever is signed in on the machine
  ## running it would pass or fail by accident.
  # Before anything opens a socket. The Dart VM's profiler signals every
  # thread in this process about a thousand times a second, and a syscall
  # interrupted by one fails rather than resuming unless its handler says
  # otherwise — which is why signing in reported `Interrupted system call`.
  restartableSyscalls()
  reducer.restore()

proc dup(s: string): cstring =
  ## A copy of `s` that outlives this call, for the caller to `nirc_free`.
  ## `allocShared0` and not `alloc0`: the Dart side may free it from a
  ## different thread than the one that made it.
  let n = s.len
  let p = cast[cstring](allocShared0(n + 1))
  if n > 0:
    copyMem(p, unsafeAddr s[0], n)
  p

proc nirc_free*(p: cstring) {.exportc, dynlib.} =
  ## Free what one of the functions below returned. Null is fine.
  if p != nil:
    deallocShared(p)

proc nirc_version*(): cstring {.exportc, dynlib.} =
  ## Static storage, deliberately: this one is NOT freed, and is the only
  ## exception to the rule above. It exists so a binding can check at load
  ## time that the library it found is the one it was built against.
  "0.1.0"

# ----------------------------------------------------------------- irc/parse

proc nirc_irc_parse_line*(line: cstring): cstring {.exportc, dynlib.} =
  ## An IRC line as JSON: `{raw, tags, account, prefix, command, params}`.
  ##
  ## `tags`, `account` and `prefix` are JSON null where the line carried none,
  ## which is the distinction `nirc.irc.parse` draws with nil and every caller
  ## of it depends on — a PRIVMSG from a server with no prefix is not the same
  ## line as one from a nick.
  if line == nil: return dup("null")
  let p = parseLine($line)
  var o = newJObject()
  o["raw"] = %p.raw
  o["tags"] = if p.hasTags: %p.tags else: newJNull()
  o["account"] = if p.hasAccount: %p.account else: newJNull()
  o["prefix"] = if p.hasPrefix: %p.prefix else: newJNull()
  o["command"] = %p.command
  o["params"] = %p.params
  dup($o)

proc nirc_irc_tag_value*(tags, key: cstring): cstring {.exportc, dynlib.} =
  ## One tag's value, unescaped — or **null** where the tag is absent or
  ## empty, which IRCv3 says are the same thing. Null and not "" on purpose:
  ## see `tagValue`.
  if tags == nil or key == nil: return nil
  let (v, ok) = tagValue($tags, $key)
  if ok: dup(v) else: nil

proc nirc_irc_unescape_tag*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return nil
  dup(unescapeTag($v))

proc nirc_irc_escape_tag_value*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return dup("")
  dup(escapeTagValue($v))

proc nirc_irc_nick_of*(prefix: cstring): cstring {.exportc, dynlib.} =
  if prefix == nil: return nil
  dup(nickOf($prefix))

# --------------------------------------------------------------- transport
#
# `nirc.net`'s three operations, for `nirc.net.nim` to install. This is the
# wiring that matters: the existing ClojureDart screens, cells and actions are
# untouched, and only the socket underneath them becomes Nim.
#
# Polled rather than callback-driven, for the reason the UI is: a Dart callback
# invoked from a foreign thread has to be marshalled onto the main isolate, and
# a timer on the Dart side does the same job with no mechanism at all.

proc nirc_trace*(topic, msg: cstring) {.exportc, dynlib.} =
  ## Let the Dart side log through the same facility, so one NIRC_TRACE=1 gives
  ## one interleaved story instead of two half-ones in different places.
  if topic != nil and msg != nil:
    trace($topic, $msg)

proc nirc_conn_open*(host: cstring, port: cint, tls: cint) {.exportc, dynlib.} =
  if host == nil: return
  tr.open(tr.ConnConfig(host: $host, port: port.int, tls: tls != 0))

proc nirc_conn_send*(line: cstring) {.exportc, dynlib.} =
  if line != nil: tr.send($line)

proc nirc_conn_close*() {.exportc, dynlib.} =
  tr.close()

proc nirc_conn_recv*(): cstring {.exportc, dynlib.} =
  ## The next line, or null when there is none waiting. Never blocks.
  let (ok, line) = tr.tryLine()
  if ok: dup(line) else: nil

proc nirc_conn_event*(): cstring {.exportc, dynlib.} =
  ## The next transport event — "open", "close: …", "error: …" — or null.
  let (ok, e) = tr.tryEvent()
  if ok: dup(e) else: nil


# ------------------------------------------------------------------- the UI
#
# Nim owns the state and the screens; Dart owns the pixels. The only things
# crossing are a tree going out and an event id coming back.

proc currentTree(): string =
  ## Whichever screen the state says, built only when the state moved — see
  ## `nirc/tree`. `drain` first, so the tree Dart gets is built after every
  ## line that had arrived when it asked — that is the whole of the polling
  ## model, and why there is no callback into Dart.
  discard refresh()
  treeJson

proc nirc_ui_render*(): cstring {.exportc, dynlib.} =
  ## The current screen as a widget tree, in JSON.
  ##
  ## Not pure: it drains the socket's queue first, so two calls with no
  ## dispatch between can differ when a line arrived in the gap. That is how
  ## the room fills, and it is why the renderer polls.
  dup(currentTree())

proc nirc_ui_dispatch*(event: cstring): cstring {.exportc, dynlib.} =
  ## Apply an event and answer with the tree it produced.
  ##
  ## One call rather than dispatch-then-render, and not to save a crossing: it
  ## makes the pair atomic, so there is no window in which Dart could render a
  ## state nothing asked for.
  if event != nil:
    try:
      dispatch(parseJson($event))
    except JsonParsingError:
      discard
  dup(currentTree())

proc nirc_ui_input*(event: cstring) {.exportc, dynlib.} =
  ## Apply an event and answer with nothing: a keystroke in a field whose
  ## text the renderer already has. See `ui.entry` for which those are.
  if event != nil: input($event)

proc nirc_ui_poll*(): cstring {.exportc, dynlib.} =
  ## The tree, for a renderer asking because time passed rather than because
  ## anything happened. Same work as render; named for what the caller means.
  dup(currentTree())

proc nirc_ui_demo*() {.exportc, dynlib.} =
  ## Fill a room with a representative conversation, for a test that wants to
  ## lay the chat screen out without a server.
  ##
  ## It exists because the chat screen is the one a script could not reach: a
  ## GUI on Wayland cannot be clicked, so every automated check stopped at the
  ## room list and the biggest screen in the app went out unlaid-out. The
  ## content is chosen to be awkward on purpose — a long unbroken URL, a very
  ## long word, an image, reactions, a reply, a system line, an edited line —
  ## because a layout bug is about what does not fit.
  app = initState()
  app.formNick = "me"
  app.rooms.ensureRoom("#test")
  var r = app.rooms["#test"]
  r.joined = true
  r.users = {"me": "", "alice": "@", "bob": ""}.toTable
  r.topic = "a room"
  let t0 = 1_700_000_000_000'i64
  r.messages = @[
    Message(id: "1", frm: "*", text: "me joined #test", at: t0, system: true),
    Message(id: "2", frm: "alice", text: "hello there", at: t0 + 1000),
    Message(id: "3", frm: "bob",
            text: "see https://example.com/a/very/long/path/that/will/not/wrap/anywhere/at/all?q=1 for more",
            at: t0 + 2000),
    Message(id: "4", frm: "alice",
            text: "Supercalifragilisticexpialidociousssssssssssssssssssssssssssssssssssss",
            at: t0 + 3000),
    Message(id: "5", frm: "me", text: "a picture", at: t0 + 4000,
            imageUrl: "https://example.com/a.png"),
    Message(id: "6", frm: "bob", text: "answering you", at: t0 + 5000,
            replyTo: "5"),
    Message(id: "7", frm: "me", text: "edited line", at: t0 + 6000,
            edited: true,
            reactions: @[Reaction(emoji: "👍", nicks: @["me", "alice"]),
                         Reaction(emoji: "🎉", nicks: @["bob"])]),
    # A different day, so a heading has to land between them.
    Message(id: "8", frm: "alice", text: "next day", at: t0 + 200_000_000)]
  app.rooms["#test"] = r

  # Somewhere else, so the chat list has more than one room in it.
  #
  # Awkward on purpose, like the rest: a long bot line that has to be cut,
  # and a short one that must not look different for it.
  app.rooms.ensureRoom("#builds")
  var other = app.rooms["#builds"]
  other.joined = true
  other.messages = @[
    Message(id: "o1", frm: "builder", text: "build 4812 passed in 3m12s",
            at: t0 + 100_000),
    Message(id: "o2", frm: "builder",
            text: "**Result**: 50/50 announcements collected in ~12s, and the rest of a sentence that has to be cut somewhere sensible.",
            at: t0 + 200_000)]
  app.rooms["#builds"] = other

  # A third room, and a busy one.
  app.rooms.ensureRoom("#busy")
  var busy = app.rooms["#busy"]
  busy.joined = true
  for i in 1 .. 12:
    busy.messages.add Message(id: "b" & $i, frm: "carol",
                              text: "line " & $i & " of a long day",
                              at: t0 + 300_000 + i.int64 * 1000)
  app.rooms["#busy"] = busy

  app.current = "#test"
  app.screen = scChat
  app.status = "Connected as me"

proc nirc_ui_reset*() {.exportc, dynlib.} =
  tr.close()
  app = initState()
