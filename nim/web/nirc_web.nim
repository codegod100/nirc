## The core, for a browser.
##
## `nirc_core.nim` is the other one. That file is the only thing that knows
## about C; this is the only thing that knows about JavaScript, and the two
## have the same job: own the state and the screens, and hand a widget tree
## to whatever draws it.
##
## The seam is different because the host is. Across FFI a string is a pointer
## somebody has to free, and `nirc_free` says so; here a string is a string.
## What is the same is the shape — a tree out, an event id back — and the
## polling, because the socket is somebody else's and nothing calls in.
##
## The platform modules underneath are chosen by search path: `nim/web/nirc`
## comes before `nim/src/nirc`, so `nirc/conn` is the WebSocket queue rather
## than the socket threads, `nirc/store` is localStorage rather than files,
## and so on. The shared code imports the same names either way and never
## learns which host it is on.

import std/[json, strutils, tables]
import nirc/[cells, model, reducer, rooms, trace, tree]
import nirc/conn as tr

var shownTree: cstring = ""
  ## `treeJson` as a JavaScript string, made once per tree. Turning half a
  ## megabyte of Nim string into one is most of a frame on its own, and a
  ## poll that found nothing new used to pay it ten times a second.

proc currentTree(): cstring =
  ## Whichever screen the state says, built only when the state moved — see
  ## `nirc/tree`.
  if refresh(): shownTree = treeJson.cstring
  shownTree

# ----------------------------------------------------------------- the seam
#
# Everything below is called from JavaScript and nothing else. `exportc` with
# a `nirc` prefix rather than Nim's mangled names, so the host can call them by
# the names written here.

proc nircInit(payload: cstring) {.exportc.} =
  ## Once, before anything else: what the last visit saved.
  restore()
  discard payload

proc nircRender(): cstring {.exportc.} = currentTree()
  ## The current screen as a widget tree, in JSON.

proc nircDispatch(event: cstring): cstring {.exportc.} =
  ## Apply an event and answer with the tree it produced — one call, so there
  ## is no window in which the host could draw a state nothing asked for.
  try:
    dispatch(parseJson($event))
  except CatchableError as e:
    trace("dispatch", "!! " & e.msg)
  currentTree()

proc nircInput(event: cstring) {.exportc.} = input($event)
  ## Apply an event and answer with nothing: a keystroke in a field whose
  ## text the host already has. See `ui.entry` for which those are.

# --------------------------------------------------------------- the socket
#
# The host owns it. These four are the whole of the transport seam, and they
# are the two the tests already use plus the two a real connection needs.

proc nircWanted(): cstring {.exportc.} =
  ## Where the core is asking to be connected, as JSON, or empty where it is
  ## not asking. The host reads this after a dispatch and opens the socket.
  let cfg = tr.wanted()
  if cfg.host.len == 0: return "".cstring
  ($(%*{"host": cfg.host, "port": cfg.port, "tls": cfg.tls})).cstring

proc nircFeed(line: cstring) {.exportc.} = tr.feed($line)
  ## A line the server sent.

proc nircPump() {.exportc.} = drain()
  ## Answer what has arrived, without building a screen nobody is looking at.
  ##
  ## `render` drains too, but it is reached from a Dart timer, and a browser
  ## throttles timers in a tab that is not showing -- to once a minute, after
  ## a few minutes hidden. A PING that waited for one was answered late or not
  ## at all, and the server closed the connection for it. The host calls this from
  ## the socket's `onmessage`, which a hidden tab still runs on time.

proc nircSocketEvent(e: cstring) {.exportc.} = tr.event($e)
  ## "open", or "close: why", or "error: why".

proc nircTakeOutbound(): cstring {.exportc.} =
  ## Everything the core wants to say, newline-separated, taken as it is read.
  ## One call rather than one per line: a registration is four lines and this
  ## is a crossing each.
  var lines: seq[string]
  while true:
    let (ok, line) = tr.tryOutbound()
    if not ok: break
    lines.add line
  lines.join("\n").cstring

# ------------------------------------------------------------------- the rest

proc nircTrace(on: bool) {.exportc.} = trace.enabled = on
  ## Tracing has no environment to be switched on from here, so the console
  ## switches it: `nircTrace(true)`.

proc nircDemo() {.exportc.} =
  ## The same representative room `nirc_core.nirc_ui_demo` fills, for looking at
  ## the screens without a server.
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
    Message(id: "3", frm: "bob", text: "answering", at: t0 + 2000,
            replyTo: "2"),
    Message(id: "4", frm: "me", text: "a line of my own", at: t0 + 3000)]
  app.rooms["#test"] = r
  app.current = "#test"
  app.screen = scChat
  app.status = "Connected as me"

# The host reaches these by name, so they are put where a name can be reached
# from: a `<script>` tag's globals are the browser's, and a module wrapper's
# are nobody's. One object rather than a scattering of globals, and the same
# object under node, which is what the smoke test drives.
{.emit: """
globalThis.nirc = {
  init: nircInit,
  render: nircRender,
  dispatch: nircDispatch,
  input: nircInput,
  wanted: nircWanted,
  feed: nircFeed,
  pump: nircPump,
  socketEvent: nircSocketEvent,
  takeOutbound: nircTakeOutbound,
  trace: nircTrace,
  demo: nircDemo,
};
""".}
