## Every event the screens can send, and every line the server sends, and what
## each does to the state.
##
## Event ids are strings with a `:`-separated argument, because that is what
## crosses the FFI in a prop. `room.open:#test` rather than a structured
## payload: the alternative is a second serialisation to define and version,
## for arguments that are always one string.

import std/[algorithm, json, options, sequtils, strutils, tables]
import std/sets
import nirc/[cells, model, rooms, reactions, trace, ircparse, clock,
            handshake, textruns, members, store, complete, commands]
import nirc/multiline as ml
import nirc/conn as tr

proc split2(id: string): (string, string) =
  ## `"room.open:#test"` → `("room.open", "#test")`. The argument may itself
  ## contain colons — a reaction event carries an id and an emoji — so only
  ## the first is a separator.
  let i = id.find(':')
  if i < 0: (id, "") else: (id[0 ..< i], id[i + 1 .. ^1])

var
  creds: Credentials
    ## What this connection signs in with, settled before the socket opens.
  caps: HashSet[string]
    ## What the server has ACKed so far, threaded through `handshake.step`.
  offeredCaps: HashSet[string]
    ## CAP LS fragments accumulated until the server sends the final one.
  landed: bool
    ## Whether this run has already been put back where it left off. A flag
    ## and not a check of the screen, because 001 arrives once per connection
    ## and a reader who went back to the room list should not be thrown into
    ## a room by a reconnect.
  registered: bool
    ## Whether the connection now open got as far as 001, and so whether its
    ## ending is a drop worth answering with a reconnect rather than a dial
    ## that failed. Cleared by Disconnect, so a reader who asked to leave is
    ## not dialled back in.
  nickTries: int
    ## How many times registration has been refused a nick. Each refusal
    ## tries the nick with another `_`, a few times, before giving up.
  wantedNick: string
    ## The nick the reader asked for, which a refusal is a variation on.

proc setError(msg: string) =
  app.error = msg
  app.hasError = true

const historyLimit = 100
  ## How many lines of backlog to ask a room for.

func hasCap(name: string): bool =
  {.cast(noSideEffect).}:
    name in caps

proc supportsHistory(): bool =
  "draft/chathistory" in caps or "chathistory" in caps

proc rememberRooms(force = false)
  ## Declared here because `openRoom` is above it and calls it — the file is
  ## ordered by what the reader does, not by what calls what.

proc send(line: string) =
  traced("out"): redact(line)
  tr.send(line)

proc openRoom(name: string) =
  app.rooms.ensureRoom(name)
  var r = app.rooms[name]
  r.accessed = nowMs()
  app.rooms[name] = r
  if app.current != name: app.peopleBucket = 0
  app.current = name
  app.screen = scChat
  app.atPresent = true
  # Opening a room is reading it: the marker moves to the newest line here.
  app.rooms[name] = app.rooms[name].markRead
  rememberRooms()

proc restoreRooms() =
  ## The rooms of earlier runs, in the order they were last used.
  ##
  ## Empty buffers, not memberships: the list of rooms is the part worth
  ## keeping and the messages in them come from the server. Inserted oldest
  ## first, so the table's own order matches the list the reader last saw.
  let saved = loadRooms()
  if saved.len == 0: return
  for i in countdown(saved.high, 0):
    let r = saved[i]
    if app.rooms.hasKey(r.name) or r.name.isStatus: continue
    var ch = initRoom(r.name)
    ch.accessed = r.accessed
    ch.lastReadId = r.lastReadId
    ch.lastReadAt = if r.lastReadAt > 0: r.lastReadAt else: nowMs()
    app.rooms[r.name] = ch
  trace("store", $saved.len & " rooms remembered")

proc restorePrefs() =
  ## The display toggles that are a standing answer rather than a passing
  ## one. The people panel on a narrow window is not among them: there it is
  ## the pane rather than beside it, and a saved "on" would open every room on
  ## a list of names.
  let prefs = loadPrefs()
  app.hideJoinPart = prefs.getOrDefault("hideJoinPart", app.hideJoinPart)
  app.hideChatList = prefs.getOrDefault("hideChatList", app.hideChatList)
  app.hideUsers = prefs.getOrDefault("hideUsers", app.hideUsers)

proc rememberPrefs() =
  discard savePrefs({"hideJoinPart": app.hideJoinPart,
                     "hideChatList": app.hideChatList,
                     "hideUsers": app.hideUsers}.toTable)

proc rememberServer() =
  discard saveServer(SavedServer(host: app.formHost.strip(),
                                 port: app.formPort.strip(),
                                 tls: app.formTls, nick: app.formNick.strip(),
                                 account: app.formAccount.strip(),
                                 channels: app.formChannels.strip()))

var
  multilines: ml.Assembler
    ## The `draft/multiline` batches this connection has open — see
    ## `nirc/multiline`.

var
  roomsSavedAt: int64 = 0
  roomsWritten: string

proc roomsDigest(): string =
  ## Exactly the fields the file holds, so "nothing changed" means nothing
  ## the file would show changed.
  for name, r in app.rooms:
    if name.isStatus: continue
    result.add name & "\x1f" & $r.accessed & "\x1f" & r.lastReadId &
               "\x1f" & $r.lastReadAt & "\x1e"

proc rememberRooms(force = false) =
  ## Write the room list out, at most every five seconds. `force` is for the
  ## moments there may not be a next chance — leaving a room, disconnecting.
  let now = nowMs()
  if not force and now - roomsSavedAt < 5000: return
  let digest = roomsDigest()
  if digest == roomsWritten: return
  roomsSavedAt = now
  roomsWritten = digest
  var keep = initOrderedTable[string, Room]()
  for name, r in app.rooms:
    if not name.isStatus: keep[name] = r
  discard saveRooms(keep)

proc restore*() =
  ## What a previous run left on disk, back in the state: where to connect,
  ## what you were in, and how you like it. Any of them may be missing.
  restoreRooms()
  restorePrefs()
  let (saved, had) = loadServer()
  if not had: return
  app.formHost = saved.host
  if saved.port.len > 0: app.formPort = saved.port
  app.formTls = saved.tls
  if saved.nick.len > 0: app.formNick = saved.nick
  app.formAccount = saved.account
  app.formChannels = saved.channels
  trace("store", "a saved server: " & saved.host)

proc parsePort(): int =
  try: parseInt(app.formPort.strip())
  except ValueError: (if app.formTls: 6697 else: 6667)

proc openSocket() =
  ## The connection itself.
  caps = initHashSet[string]()
  offeredCaps = initHashSet[string]()
  app.caps = @[]
  app.account = ""
  nickTries = 0
  wantedNick = app.formNick.strip()
  app.connecting = true
  let host = app.formHost.strip()
  app.status =
    if host.contains("://"): "Connecting to " & host & "…"
    else: "Connecting to " & host & ":" & app.formPort.strip() &
          (if app.formTls: " over TLS" else: "") & "…"
  tr.open(tr.ConnConfig(host: host, port: parsePort(), tls: app.formTls))

proc connectNow() =
  if app.formHost.strip().len == 0:
    setError("A server is required."); return
  if app.formNick.strip().len == 0:
    setError("A nickname is required."); return
  if app.formNick.strip().contains(' '):
    setError("A nickname cannot contain spaces."); return
  if app.formAccount.strip().len > 0 and app.formSaslPassword.len == 0:
    setError("Signing in to an account needs its password."); return
  app.hasError = false
  creds = Credentials(account: app.formAccount.strip(),
                      password: app.formSaslPassword)
  rememberServer()
  openSocket()

proc reconnects(): bool =
  ## Whether a dropped connection is dialled again by itself. In the browser
  ## the socket is a WebSocket a proxy closes after a quiet spell, and a tab
  ## left open is expected to still be in its rooms.
  when defined(js): true
  else: false

proc disconnect() =
  rememberRooms(force = true)
  registered = false
  tr.close()
  app.connecting = false
  app.screen = scConnect
  app.status = "Not connected"

proc echoLine(room, line: string, action = false, replyTo = "") =
  ## Our own line on screen now. Where `echo-message` was negotiated the
  ## server sends it back with its msgid and this copy adopts it; where it was
  ## not, this copy is the only one there will ever be.
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  var m = Message(frm: app.formNick, text: line, at: nowMs(), action: action,
                  localId: "local-" & $r.messages.len,
                  pending: hasCap("echo-message"))
  m.imageUrl = firstImageUrl(line)
  m.replyTo = replyTo
  r.messages.add m
  app.rooms[room] = r.markRead

proc localNote(room, line: string) =
  ## Something this client says to its reader, in the room they are looking
  ## at. Not `note`: that one drops a line it has seen before, and the answer
  ## to a second `/help` is the same as to the first.
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  r.messages.add Message(frm: "nirc", text: line, at: nowMs(), system: true)
  app.rooms[room] = r.markRead

proc statusNote(line: string, at: int64 = 0) =
  ## The server's own words, into the status buffer.
  if line.strip.len == 0: return
  app.rooms.ensureRoom(statusRoom)
  var r = app.rooms[statusRoom]
  r.joined = true
  r.messages.add Message(frm: "server", text: line,
                         at: if at > 0: at else: nowMs(), system: true)
  # Kept short: a MOTD a day for a month is a long buffer nobody scrolls.
  if r.messages.len > 1000: r.messages = r.messages[^1000 .. ^1]
  r.lastActivity = nowMs()
  app.rooms[statusRoom] = r

proc dispatch*(event: JsonNode)
  ## Forward, because `/markread` is the button typed and sends its event.

proc runCommand(c: Command) =
  ## A `/` line, carried out. See `commands` for what each one is.
  case c.kind
  of ckNone: discard
  of ckUsage: setError(c.text)
  of ckJoin:
    app.rooms.ensureRoom(c.target)
    var r = app.rooms[c.target]
    r.joining = true
    app.rooms[c.target] = r
    send("JOIN " & c.target & (if c.text.len > 0: " " & c.text else: ""))
    openRoom(c.target)
  of ckPart:
    if c.target.isChannel:
      send("PART " & c.target & (if c.text.len > 0: " :" & c.text else: ""))
    if app.rooms.hasKey(c.target):
      app.rooms.del(c.target)
      rememberRooms(force = true)
      if app.current == c.target:
        app.current = ""
        app.screen = scChats
  of ckMsg:
    send("PRIVMSG " & c.target & " :" & c.text)
    echoLine(c.target, c.text)
  of ckQuery:
    openRoom(c.target)
    if c.text.len > 0:
      send("PRIVMSG " & c.target & " :" & c.text)
      echoLine(c.target, c.text)
  of ckMe:
    if c.target.len == 0 or c.target.isStatus:
      setError("Open a conversation to do that in.")
      return
    send("PRIVMSG " & c.target & " :" & actionLine(c.text))
    echoLine(c.target, c.text, action = true)
  of ckNick:
    # Settled when the server's NICK comes back, which renames us everywhere;
    # a refusal is a 433 and says so.
    send("NICK " & c.target)
  of ckTopic:
    if c.text.len > 0:
      send("TOPIC " & c.target & " :" & c.text)
    else:
      let topic = if app.rooms.hasKey(c.target): app.rooms[c.target].topic
                  else: ""
      if app.current.len > 0:
        localNote(app.current,
                  if topic.len > 0: "Topic for " & c.target & ": " & topic
                  else: "No topic is set for " & c.target & ".")
      send("TOPIC " & c.target)
  of ckWhois:
    send("WHOIS " & c.target)
    app.profileViewing = ProfileView(has: true, nick: c.target)
  of ckList:
    app.listPending = @[]
    app.listing322 = true
    send("LIST" & (if c.text.len > 0: " " & c.text else: ""))
    app.screen = scDiscover
  of ckQuit:
    send("QUIT" & (if c.text.len > 0: " :" & c.text else: ""))
    disconnect()
  of ckHelp:
    if app.current.len == 0:
      setError("Commands: " & commandNames().join(" "))
    else:
      for line in helpLines(): localNote(app.current, line)
  of ckMarkRead:
    dispatch(%*{"id": "rooms.mark-read"})
  of ckRaw:
    send(c.text)

proc sendDraft() =
  let raw = app.draft.strip()
  if raw.isCommand:
    let c = parseCommand(raw, app.current)
    # A mistake keeps the line, so the reader can mend it rather than retype.
    if c.kind != ckUsage: app.draft = ""
    app.tab = TabState()
    runCommand(c)
    return
  let text = unescapeSlash(raw)
  if text.len == 0 or app.current.len == 0: return
  # The status buffer is the server itself: what is typed there is a raw line.
  if app.current.isStatus:
    send(text)
    statusNote("→ " & text)
    app.draft = ""
    return
  var replyTo = ""
  if app.replyingTo.has:
    replyTo = app.replyingTo.id
    # A local id is never sent: the server has no such line. And a reply tag
    # is a client tag, which a server without message-tags would refuse.
    if replyTo.startsWith("local-") or not hasCap("message-tags"):
      send("PRIVMSG " & app.current & " :" & text)
    else:
      send("@+draft/reply=" & replyTo & " PRIVMSG " & app.current &
           " :" & text)
    app.replyingTo = ReplyTarget()
  else:
    # A line the server would cut is sent as several. 512 bytes is the whole
    # line, prefix and all, so 400 of text leaves room for the server's own.
    let lines = text.splitLines
    for l in lines:
      var rest = l
      while rest.len > 400:
        var cut = 400
        while cut > 0 and (rest[cut].ord and 0xC0) == 0x80: dec cut
        send("PRIVMSG " & app.current & " :" & rest[0 ..< cut])
        echoLine(app.current, rest[0 ..< cut])
        rest = rest[cut .. ^1]
      if rest.len > 0:
        send("PRIVMSG " & app.current & " :" & rest)
        echoLine(app.current, rest)
    app.draft = ""
    return

  echoLine(app.current, text, replyTo = replyTo)
  app.draft = ""

proc sendReaction(mid, emoji: string) =
  ## A reaction added or taken away: `+draft/react` on a TAGMSG that names
  ## the line with `+draft/reply`, which is how every client that shows
  ## reactions sends them. Taking one away is `+draft/unreact`, which fewer
  ## clients read; where they do not, the pill simply stays for them.
  if not hasCap("message-tags"):
    setError("This server does not carry reactions (no message-tags).")
    return
  let m = app.currentRoom.messageById(mid)
  let on = if m.isSome: not m.get.mine(emoji, app.formNick) else: true
  let tag = if on: "+draft/react=" else: "+draft/unreact="
  send("@" & tag & escapeTagValue(emoji) & ";+draft/reply=" & mid &
       " TAGMSG " & app.current)
  app.rooms.updateReaction(app.current, mid, emoji, app.formNick, on)

var draftRevs = 0
  ## Never reset, so a fresh state's revision is one the renderer has not
  ## already seen.

proc apply(event: JsonNode)

proc dispatch*(event: JsonNode) =
  ## `apply`, and a new `draftRev` where it rewrote the draft. A keystroke is
  ## the one event that changes the draft without one: the renderer already
  ## has that text, because the reader typed it there.
  let before = app.draft
  apply(event)
  if app.draft != before and event{"id"}.getStr() != "draft.change":
    inc draftRevs
    app.draftRev = draftRevs

proc apply(event: JsonNode) =
  let raw = event{"id"}.getStr()
  let value = event{"value"}.getStr()
  let (id, arg) = split2(raw)

  traced "event": "→ " & raw &
    (if value.len > 0 and not id.contains("password"): " value=" & value.escape
     else: "")

  case id
  # ------------------------------------------------------------ the form
  of "host.change": app.formHost = value
  of "port.change": app.formPort = value
  of "nick.change": app.formNick = value
  of "server-password.change": app.formServerPassword = value
  of "account.change": app.formAccount = value
  of "sasl-password.change": app.formSaslPassword = value
  of "channels.change": app.formChannels = value

  of "tls.toggle":
    app.formTls = not app.formTls
    # The port follows the tick where it was one of the two usual ones.
    let p = app.formPort.strip()
    if p in ["6697", "6667", ""]:
      app.formPort = if app.formTls: "6697" else: "6667"

  # --------------------------------------------------------- the connection
  of "connect": connectNow()

  of "cancel", "disconnect":
    if registered: send("QUIT :nirc")
    disconnect()

  of "error.dismiss":
    app.error = ""
    app.hasError = false

  # ------------------------------------------------------------- navigation
  of "screen.connect": app.screen = scConnect
  of "screen.chats": app.screen = scChats
  of "screen.dms": app.screen = scDms
  of "screen.discover":
    app.screen = scDiscover
    if app.listing.len == 0 and not app.listing322 and registered:
      app.listPending = @[]
      app.listing322 = true
      send("LIST")
  of "screen.settings": app.screen = scSettings

  of "list.refresh":
    if registered:
      app.listPending = @[]
      app.listing322 = true
      send("LIST")

  of "room.open": openRoom(arg)
  of "rooms.mark-read":
    app.rooms.markAllRead()
    rememberRooms(force = true)

  of "room.join":
    if arg.len > 0:
      app.rooms.ensureRoom(arg)
      var r = app.rooms[arg]
      r.joining = true
      app.rooms[arg] = r
      send("JOIN " & arg)
      openRoom(arg)

  of "room.leave":
    if app.rooms.hasKey(arg):
      if arg.isChannel: send("PART " & arg)
      app.rooms.del(arg)
      rememberRooms(force = true)
      if app.current == arg:
        app.current = ""
        app.screen = scChats

  of "join":
    # `@nick` opens a DM, which needs no JOIN — there is nothing to be in.
    let want = app.joinInput.strip()
    if want.len > 0:
      if want.startsWith("@"):
        openRoom(want[1 .. ^1])
      else:
        let name = if want.isChannel: want else: "#" & want
        app.rooms.ensureRoom(name)
        send("JOIN " & name)
        openRoom(name)
      app.joinInput = ""

  of "join-input.change": app.joinInput = value
  of "search.change": app.search = value
  of "search.clear": app.search = ""

  # ---------------------------------------------------------- chat chrome
  of "chat-list.toggle":
    app.hideChatList = not app.hideChatList
    rememberPrefs()
  of "users.toggle":
    if app.wide:
      app.hideUsers = not app.hideUsers
      rememberPrefs()
    else:
      app.showUsers = not app.showUsers
  of "join-part.toggle":
    app.hideJoinPart = not app.hideJoinPart
    rememberPrefs()
  of "jump.present":
    app.atPresent = true
    app.jumpTick += 1

  # Where the reader is in the backlog, as the renderer sees it: a scroll
  # offset belongs to the thing doing the scrolling.
  of "present.left": app.atPresent = false
  of "people.scroll":
    app.peopleBucket = try: max(0, parseInt(arg)) except ValueError: 0
  of "present.back": app.atPresent = true

  of "window.size":
    # `<width>x<height>`, in the value where the renderer puts it, or after
    # the colon where a test or a console types it.
    let spec = if value.len > 0: value else: arg
    let x = spec.find('x')
    if x > 0:
      let w = try: parseInt(spec[0 ..< x]) except ValueError: 0
      let h = try: parseInt(spec[x + 1 .. ^1]) except ValueError: 0
      if w > 0 and h > 0:
        app.windowWidth = w
        app.windowHeight = h

  # ------------------------------------------------------------ the compose
  of "draft.change":
    app.draft = value
    app.tab = TabState()
  of "draft.complete":
    # Tab. `value` is the caret as the host counts it; `arg` is "back" for
    # Shift-Tab. The nicks are this room's, whoever spoke last first.
    let room = app.currentRoom
    var users: seq[string]
    for nick in room.users.keys: users.add nick
    if room.name.dm and room.name notin users:
      users.add room.name
    var spoke: seq[string]
    for m in room.messages[max(0, room.messages.len - 500) .. ^1]:
      spoke.add m.frm
    var channels: seq[string]
    for name in app.rooms.keys:
      if name.isChannel: channels.add name
    let caret =
      if value.len == 0: app.draft.len
      else: byteOffset(app.draft, (try: parseInt(value) except ValueError: 0))
    let t = tabComplete(app.draft, caret, byRecency(users, spoke, app.formNick),
                        channels, app.tab, back = arg == "back",
                        commands = commandNames())
    app.tab = t
    if t.active: app.draft = t.text
  of "send": sendDraft()

  of "reply.to":
    let m = app.currentRoom.messageById(arg)
    if m.isSome:
      app.replyingTo = ReplyTarget(has: true, id: arg, frm: m.get.frm,
                                   text: m.get.text)
  of "reply.cancel": app.replyingTo = ReplyTarget()

  of "redact":
    # Unsending, where the server offers `draft/message-redaction`. The line
    # goes when the server relays the REDACT back, or stays and a FAIL says
    # why.
    if arg.len > 0 and hasCap("draft/message-redaction") and
       not arg.startsWith("local-"):
      send("REDACT " & app.current & " " & arg)

  # -------------------------------------------------------------- reactions
  of "react.open":
    app.reacting = ReactTarget(has: true, room: app.current, id: arg)
    app.emojiSearch = ""
    app.emojiGroup = ""
  of "react.close":
    app.reacting = ReactTarget()
    app.emojiSearch = ""
    app.emojiGroup = ""

  of "emoji.search.change": app.emojiSearch = value
  of "emoji.group": app.emojiGroup = arg

  of "react.pick":
    if app.reacting.has and arg.len > 0:
      sendReaction(app.reacting.id, arg)
    app.reacting = ReactTarget()
    app.emojiSearch = ""
    app.emojiGroup = ""

  of "react.toggle":
    let (mid, emoji) = split2(arg)
    if mid.len > 0 and emoji.len > 0:
      sendReaction(mid, emoji)

  of "goto":
    app.jumpTo = arg
    app.highlight = arg

  of "jump.done":
    # The renderer, saying it has scrolled there. The highlight stays, since
    # that is what says "this is the one you asked for".
    app.jumpTo = ""

  of "profile.open":
    # `nick` or `nick:anything`; WHOIS fills the panel as it answers.
    let (nick, _) = split2(arg)
    if nick.len > 0:
      app.profileViewing = ProfileView(has: true, nick: nick)
      if registered: send("WHOIS " & nick)

  of "profile.close": app.profileViewing = ProfileView()

  of "profile.message":
    if arg.len > 0:
      app.profileViewing = ProfileView()
      runCommand(Command(kind: ckQuery, target: arg))

  of "lightbox":
    app.lightbox = Lightbox(has: true, url: arg, path: arg)
  of "lightbox.close": app.lightbox = Lightbox()

  of "quit": discard   # the host's business; the tree only says it was asked

  else:
    trace("event", "!! no handler for " & raw.escape & " — ignored")

# ------------------------------------------------------------------- drain
#
# The socket's output, turned into state. Called before a render, so the tree
# the renderer gets is built after every line that had arrived when it asked.

proc note(room: string, m: Message) =
  # A wire record with no words is not a chat line.
  if m.text.strip.len == 0: return
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  # Before the duplicate check: a replay of lines we already hold is still a
  # replay, and still means the server has sent this room's backlog.
  if not m.system: r.heard = true
  if seenMessage(r.messages, m.id, m.frm, m.text, app.formNick):
    app.rooms[room] = r
    return
  # A history replay may arrive after live traffic. Keep the server's
  # chronology rather than the socket's arrival order.
  var insertAt = r.messages.len
  if m.at > 0:
    for i in countdown(r.messages.high, 0):
      if r.messages[i].at <= m.at:
        insertAt = i + 1
        break
      insertAt = i
  r.messages.insert(m, insertAt)
  r.lastActivity = nowMs()
  app.rooms[room] = r.recount(app.formNick)

proc whoisOf(nick: string): Whois =
  app.whois.getOrDefault(nick, Whois())

proc setWhois(nick: string, w: Whois) =
  app.whois[nick] = w

proc isupport(tokens: seq[string]) =
  ## 005: what the server is. Only the parts a screen depends on.
  for t in tokens:
    let eq = t.find('=')
    let (k, v) = if eq < 0: (t, "") else: (t[0 ..< eq], t[eq + 1 .. ^1])
    case k
    of "CHANTYPES":
      if v.len > 0:
        app.chanTypes = v
        chanPrefixes = v
    of "NETWORK":
      app.network = v
    else: discard

proc welcome() =
  ## 001: we are in. Rejoin what the reader had open, and what the form asks.
  app.connecting = false
  registered = true
  app.status = "Connected as " & app.formNick &
               (if app.network.len > 0: " on " & app.network else: "")
  app.screen = scChats
  var asked: seq[string]
  for name, _ in app.rooms:
    if name.isChannel: asked.add name
  for c in app.formChannels.split({',', ' '}):
    let c = c.strip()
    if c.len == 0: continue
    let name = if c.isChannel: c else: "#" & c
    if name notin asked:
      asked.add name
      app.rooms.ensureRoom(name)
  # One JOIN per channel rather than a comma list: a key-less list is fine on
  # every server, but a refused one then refuses exactly one.
  for name in asked: send("JOIN " & name)

  if not landed:
    landed = true
    let last = app.rooms.lastVisited
    if last.len > 0: openRoom(last)

proc drain*() =
  while true:
    let (ok, e) = tr.tryEvent()
    if not ok: break
    trace("status", e)
    if e == "open":
      # The client speaks first in IRC. CAP before registration, the order the
      # server expects. What comes back is answered by `handshake.step`.
      caps = initHashSet[string]()
      offeredCaps = initHashSet[string]()
      multilines.reset()
      send("CAP LS 302")
      if app.formServerPassword.len > 0:
        send("PASS :" & app.formServerPassword)
      send("NICK " & app.formNick.strip())
      send("USER " & app.formNick.strip() & " 0 * :nirc")
      app.status = "Registering…"
    elif (e.startsWith("error:") or e.startsWith("close:")) and
         registered and reconnects():
      registered = false
      trace("conn", "dropped; reconnecting: " & e)
      openSocket()
    elif e.startsWith("error:"):
      registered = false
      app.connecting = false
      setError(e[6 .. ^1].strip())
      app.status = "Not connected"
      app.screen = scConnect
    elif e.startsWith("close:"):
      let wasIn = registered
      registered = false
      app.connecting = false
      app.status = "Disconnected"
      if wasIn:
        for name in toSeq(app.rooms.keys):
          var r = app.rooms[name]
          r.joined = false
          app.rooms[name] = r
      else:
        app.screen = scConnect

  while true:
    let (ok, line) = tr.tryLine()
    if not ok: break
    trace("in", line)
    # A multiline batch is held until it closes and comes out as one
    # message; at most one line comes out of any line that goes in.
    let whole = multilines.feed(parseLine(line))
    if whole.len == 0: continue
    let p = whole[0]

    if p.command == "PING":
      send("PONG :" & (if p.params.len > 0: p.params[^1] else: ""))
      continue

    let (tagMs, hasTime) = parseTimeTag(p.tags)
    let at = if hasTime: tagMs else: nowMs()
    let msgid = block:
      let (v, ok2) = tagValue(p.tags, "msgid")
      if ok2: v else: ""

    if p.command in ["CAP", "AUTHENTICATE", "900", "902", "903", "904", "905",
                     "906", "907", "908"]:
      let st = step(creds, caps, offeredCaps, p)
      caps = st.caps
      offeredCaps = st.offered
      app.caps = toSeq(caps.items)
      for l in st.send: send(l)
      case p.command
      of "900":
        # `<nick> <nick!user@host> <account> :You are now logged in as …`
        if p.params.len >= 3: app.account = p.params[2]
      of "903":
        app.status = "Signed in" &
                     (if app.account.len > 0: " as " & app.account else: "")
        trace("auth", "SASL accepted")
      of "902", "904", "905", "906", "908":
        let why = if p.params.len >= 2: p.params[^1].strip() else: ""
        setError("Sign-in refused — connected without an account." &
                 (if why.len > 0: " (" & why & ")" else: ""))
        trace("auth", "SASL refused: " & $p.params)
      else: discard
      continue

    case p.command
    of "001":
      # The first parameter is what the server calls us, which is not always
      # what we asked for: a nick refused and retried, or an account-bound
      # server that settled a SASL login on the account's nick.
      if p.params.len >= 1 and p.params[0].len > 0 and p.params[0] != "*":
        app.formNick = p.params[0]
      welcome()
      if p.params.len >= 2: statusNote(p.params[^1], at)

    of "005":
      if p.params.len >= 3:
        isupport(p.params[1 .. ^2])

    of "PRIVMSG", "NOTICE":
      if p.params.len >= 2:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        let fromServer = p.prefix.len == 0 or not p.prefix.contains('!')
        let toMe = cmpIgnoreCase(target, app.formNick) == 0
        # A message to us rather than to a channel belongs in a buffer named
        # for the sender: the target is our own nick and is nobody's room.
        # Our own line to someone else, echoed back, belongs in theirs.
        var room =
          if target.isChannel: target
          elif target.len > 0 and target[0] in {'@', '+', '%'} and
               target[1 .. ^1].isChannel: target[1 .. ^1]
          elif cmpIgnoreCase(who, app.formNick) == 0: target
          else: who
        if p.command == "NOTICE" and not target.isChannel and
           (fromServer or target == "*" or
            (toMe and not app.rooms.hasKey(who))):
          # A notice from the server, or one to us from someone we have no
          # conversation with (NickServ, ChanServ): the status buffer, where
          # it is read rather than starting a DM nobody asked for.
          statusNote((if fromServer: "" else: "-" & who & "- ") &
                     p.params[^1], at)
          continue
        if fromServer and not target.isChannel:
          statusNote(p.params[^1], at)
          continue
        let (said0, isAction) = ctcpAction(p.params[^1])
        let said = stripFormatting(said0)
        # Any other CTCP (VERSION, PING) is a query for the client, not a line.
        if p.params[^1].startsWith("\x01") and not isAction:
          let body = p.params[^1].strip(chars = {'\x01'})
          if p.command == "PRIVMSG":
            let (verb, rest) = block:
              let sp = body.find(' ')
              if sp < 0: (body, "") else: (body[0 ..< sp], body[sp + 1 .. ^1])
            case verb.toUpperAscii
            of "VERSION":
              send("NOTICE " & who & " :\x01VERSION nirc\x01")
            of "PING":
              send("NOTICE " & who & " :\x01PING " & rest & "\x01")
            else: discard
            statusNote("CTCP " & verb & " from " & who, at)
          continue

        # Our own line coming back is the copy we already showed, with the
        # msgid the server gave it — not a new message.
        if cmpIgnoreCase(who, app.formNick) == 0 and app.rooms.hasKey(room):
          var r = app.rooms[room]
          let adopted = r.adoptEcho(who, said, msgid, at,
                                    if p.hasAccount: p.account else: "")
          if adopted:
            app.rooms[room] = r
            continue

        var m = Message(id: msgid, frm: who, text: said, at: at,
                        action: isAction)
        if p.command == "NOTICE" and not target.isChannel and said.len > 0:
          m.text = "-" & who & "- " & said
        if p.hasAccount: m.account = p.account
        m.imageUrl = firstImageUrl(m.text)
        let (rep, hasRep) = block:
          let (v, ok2) = tagValue(p.tags, "+reply")
          if ok2: (v, true) else: tagValue(p.tags, "+draft/reply")
        if hasRep: m.replyTo = rep
        note(room, m)

    of "TAGMSG":
      # A message with tags and nothing said: here, a reaction.
      if p.params.len >= 1:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        let room =
          if target.isChannel: target
          elif cmpIgnoreCase(who, app.formNick) == 0: target
          else: who
        let (on, isReact) = tagValue(p.tags, "+draft/react")
        let (off, isUnreact) = tagValue(p.tags, "+draft/unreact")
        let (mid, hasMid) = tagValue(p.tags, "+draft/reply")
        if hasMid and mid.len > 0:
          if isReact and on.len > 0:
            app.rooms.updateReaction(room, mid, on, who, true)
          elif isUnreact and off.len > 0:
            app.rooms.updateReaction(room, mid, off, who, false)

    of "REDACT":
      # `REDACT <target> <msgid> [:reason]` — the line is gone, for everybody.
      if p.params.len >= 2:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        let room =
          if target.isChannel: target
          elif cmpIgnoreCase(who, app.formNick) == 0: target
          else: who
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          r.messages.keepItIf(not it.answersTo(p.params[1]))
          app.rooms[room] = r

    of "JOIN":
      if p.params.len >= 1:
        let room = p.params[0]
        app.rooms.ensureRoom(room)
        var r = app.rooms[room]
        let who = nickOf(p.prefix)
        if cmpIgnoreCase(who, app.formNick) == 0:
          r.joined = true
          r.joining = false
          # Whatever follows before 366 is this join's backlog, if any.
          r.heard = false
        elif not r.users.hasKey(who):
          r.users[who] = ""
        app.rooms[room] = r
        note(room, Message(frm: "*", text: who & " joined " & room,
                           at: at, system: true))

    of "PART":
      let who = nickOf(p.prefix)
      if p.params.len >= 1 and app.rooms.hasKey(p.params[0]):
        let room = p.params[0]
        var r = app.rooms[room]
        r.users.del(who)
        if cmpIgnoreCase(who, app.formNick) == 0: r.joined = false
        app.rooms[room] = r
        let why = if p.params.len >= 2: " (" & p.params[^1] & ")" else: ""
        note(room, Message(frm: "*", text: who & " left" & why, at: at,
                           system: true))

    of "KICK":
      if p.params.len >= 2 and app.rooms.hasKey(p.params[0]):
        let room = p.params[0]
        let gone = p.params[1]
        var r = app.rooms[room]
        r.users.del(gone)
        if cmpIgnoreCase(gone, app.formNick) == 0: r.joined = false
        app.rooms[room] = r
        let why = if p.params.len >= 3: " (" & p.params[^1] & ")" else: ""
        note(room, Message(frm: "*", text: nickOf(p.prefix) & " kicked " &
                           gone & why, at: at, system: true))

    of "QUIT":
      # A QUIT names no room: it is every room that person was in.
      let who = nickOf(p.prefix)
      let why = if p.params.len >= 1: " (" & p.params[^1] & ")" else: ""
      for name in toSeq(app.rooms.keys):
        var r = app.rooms[name]
        if r.users.hasKey(who):
          r.users.del(who)
          app.rooms[name] = r
          note(name, Message(frm: "*", text: who & " quit" & why, at: at,
                             system: true))

    of "NICK":
      # Somebody is called something else now — including us.
      let who = nickOf(p.prefix)
      let fresh = if p.params.len >= 1: p.params[^1] else: ""
      if who.len > 0 and fresh.len > 0:
        for name in toSeq(app.rooms.keys):
          var r = app.rooms[name]
          if r.users.renameUser(who, fresh):
            app.rooms[name] = r
            note(name, Message(frm: "*", text: who & " is now " & fresh,
                               at: at, system: true))
        if app.rooms.hasKey(who) and not app.rooms.hasKey(fresh):
          # A DM follows the person.
          var r = app.rooms[who]
          r.name = fresh
          app.rooms.del(who)
          app.rooms[fresh] = r
          if app.current == who: app.current = fresh
        if cmpIgnoreCase(who, app.formNick) == 0:
          app.formNick = fresh
          if app.status.startsWith("Connected"):
            app.status = "Connected as " & fresh &
                         (if app.network.len > 0: " on " & app.network else: "")
          trace("auth", "the server calls us " & fresh)

    of "353":
      # NAMES, into the PENDING list. It arrives over as many lines as it
      # takes and ends with 366.
      if p.params.len >= 2:
        let room = p.params[^2]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          var names: seq[string]
          for entry in p.params[^1].split(' '):
            # userhost-in-names: `@nick!user@host`, and the list wants nicks.
            let bang = entry.find('!')
            names.add(if bang > 0: entry[0 ..< bang] else: entry)
          r.namesAcc.withNames(names.join(" "))
          app.rooms[room] = r

    of "366":
      # End of NAMES: the pending list becomes the list.
      if p.params.len >= 2:
        let room = p.params[^2]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          if r.namesAcc.len > 0:
            r.users = r.namesAcc
            r.namesAcc.clear()
          app.rooms[room] = r
          # The only moment this client knows a room has fully arrived. A
          # server that keeps history but did not replay any on JOIN is asked
          # for it.
          if not r.heard and supportsHistory():
            send("CHATHISTORY LATEST " & room & " * " & $historyLimit)

    of "MODE":
      # A channel MODE, for the letters that change how someone is listed.
      if p.params.len >= 2 and p.params[0].isChannel:
        let room = p.params[0]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          r.users.withMode(p.params[1], p.params[2 .. ^1])
          app.rooms[room] = r

    of "TOPIC":
      if p.params.len >= 2 and app.rooms.hasKey(p.params[0]):
        var r = app.rooms[p.params[0]]
        r.topic = p.params[^1]
        app.rooms[p.params[0]] = r
        note(p.params[0], Message(frm: "*", text: nickOf(p.prefix) &
                                  " set the topic: " & p.params[^1],
                                  at: at, system: true))

    of "331":
      if p.params.len >= 2 and app.rooms.hasKey(p.params[^2]):
        var r = app.rooms[p.params[^2]]
        r.topic = ""
        app.rooms[p.params[^2]] = r

    of "332":
      if p.params.len >= 2 and app.rooms.hasKey(p.params[^2]):
        var r = app.rooms[p.params[^2]]
        r.topic = p.params[^1]
        app.rooms[p.params[^2]] = r

    # ------------------------------------------------------------- WHOIS
    of "311":
      # `<me> <nick> <user> <host> * :<realname>`
      if p.params.len >= 6:
        var w = whoisOf(p.params[1])
        w.user = p.params[2]
        w.host = p.params[3]
        w.realname = p.params[^1]
        setWhois(p.params[1], w)
    of "312":
      if p.params.len >= 3:
        var w = whoisOf(p.params[1])
        w.server = p.params[2]
        setWhois(p.params[1], w)
    of "317":
      if p.params.len >= 3:
        var w = whoisOf(p.params[1])
        let secs = try: parseInt(p.params[2]) except ValueError: -1
        if secs >= 0:
          w.idle = if secs < 60: $secs & "s"
                   elif secs < 3600: $(secs div 60) & "m"
                   else: $(secs div 3600) & "h " & $((secs mod 3600) div 60) & "m"
        setWhois(p.params[1], w)
    of "319":
      if p.params.len >= 3:
        var w = whoisOf(p.params[1])
        w.channels = p.params[^1].strip()
        setWhois(p.params[1], w)
    of "330":
      if p.params.len >= 3:
        var w = whoisOf(p.params[1])
        w.account = p.params[2]
        setWhois(p.params[1], w)
    of "301":
      if p.params.len >= 3:
        var w = whoisOf(p.params[1])
        w.away = p.params[^1]
        setWhois(p.params[1], w)
    of "401":
      # No such nick: say so in the panel rather than asking forever.
      if p.params.len >= 2 and app.profileViewing.has and
         cmpIgnoreCase(app.profileViewing.nick, p.params[1]) == 0:
        setWhois(p.params[1], Whois(away: "not on the server right now"))
      else:
        statusNote("⚠ " & p.params[1 .. ^1].join(" "), at)
    of "318": discard

    # -------------------------------------------------------------- LIST
    of "321":
      app.listPending = @[]
      app.listing322 = true
    of "322":
      if p.params.len >= 3:
        let users = try: parseInt(p.params[2]) except ValueError: 0
        app.listPending.add ListEntry(name: p.params[1], users: users,
                                      topic: if p.params.len >= 4: p.params[^1]
                                             else: "")
    of "323":
      app.listing322 = false
      app.listing = app.listPending
      app.listing.sort(proc (a, b: ListEntry): int = cmp(b.users, a.users))
      app.listPending = @[]

    of "FAIL":
      # IRCv3 standard replies: `FAIL <command> <code> [context…] :<why>`.
      let why = if p.params.len >= 3: p.params[^1].strip() else: ""
      if p.params.len >= 2:
        setError(p.params[0] & " refused" &
                 (if why.len > 0: " — " & why else: "") &
                 " (" & p.params[1] & ").")
      trace("fail", $p.params)

    of "432", "433", "436", "437":
      # Nickname refused. Before registration the connection is waiting on
      # us, so try a variation; after it, the old nick stands and it is said.
      if not registered and nickTries < 4:
        inc nickTries
        app.formNick = wantedNick & repeat('_', nickTries)
        send("NICK " & app.formNick)
      else:
        setError("That nickname is taken or invalid" &
                 (if p.params.len >= 2: ": " & p.params[1] else: "") & ".")
        if not registered: app.connecting = false

    of "464":
      setError("The server refused the password.")

    of "465", "ERROR":
      let why = if p.params.len >= 1: p.params[^1] else: ""
      statusNote(p.command & " " & why, at)
      if not registered: setError(why)

    of "471", "473", "474", "475", "403", "405", "477", "489":
      # Could not join, and the room the reader just opened says why.
      let room = if p.params.len >= 2: p.params[1] else: ""
      let why = if p.params.len >= 1: p.params[^1] else: ""
      if room.len > 0 and app.rooms.hasKey(room):
        var r = app.rooms[room]
        r.joining = false
        app.rooms[room] = r
        note(room, Message(frm: "*", text: "Cannot join: " & why, at: at,
                           system: true))
      else:
        statusNote(room & " " & why, at)

    of "PONG", "BATCH", "352", "315", "333", "329", "324", "376":
      discard

    else:
      # Numerics nobody above reads — the MOTD, LUSERS, a 4xx — are the
      # server talking to the reader, so they go where the reader can see
      # them. Anything else is traced.
      if p.command.len == 3 and p.command[0] in Digits:
        let text = if p.params.len >= 2: p.params[1 .. ^1].join(" ")
                   else: p.params.join(" ")
        if p.command[0] in {'4', '5'}: statusNote("⚠ " & text, at)
        else: statusNote(text, at)
      else:
        trace("skip", p.command & " " & $p.params)

  # A line arriving moves the marker in the room being looked at, and closing
  # the window is not a moment this client gets told about — so the saving
  # happens as it goes, throttled, rather than at an end that may never come.
  rememberRooms()
