## The screens, as pure functions of the state.
##
## These are the tests the ClojureDart screens never had and could not easily
## have: a screen there is hiccup over cells a host installs, so exercising one
## means standing up a host. Here it is a function from a record to a tree.

import std/[json, sequtils, strutils, tables, unicode, unittest]
import nirc/[ui, cells, model]
import nirc/screens/connect as cs
import nirc/screens/settings as ss
import nirc/screens/chat as cht
import nirc/screens/chats as ch
import nirc/[rooms, members]

proc find*(node: Node, tag: string): seq[Node] =
  if node.isNil: return
  if node.tag == tag: result.add node
  for c in node.children: result.add c.find(tag)

proc labels(node: Node, tag: string): seq[string] =
  node.find(tag).mapIt(it.props{"label"}.getStr())

proc keys(node: Node, tag: string): seq[string] =
  node.find(tag).mapIt(it.props{"key"}.getStr())

suite "the connect screen":
  setup:
    var s = initState()

  test "is a page with the title and the transport note":
    let t = cs.connectScreen(s)
    check t.tag == "page"
    check "nirc" in t.labels("title")
    check cs.transportNote in t.labels("dim-label")

  test "the fields holding an identifier ask to be taken as typed":
    # A phone keyboard puts a space after a full stop, because a full stop
    # ends a sentence -- and is also the middle of `irc.libera.chat`.
    let fields = cs.connectScreen(s).find("entry")
    check fields.len > 0
    for e in fields:
      check e.props{"verbatim"}.getBool() == true

  test "is pure — twice with no change is the same tree":
    check $cs.connectScreen(s).toJson == $cs.connectScreen(s).toJson

  test "asks for a server, a nick, channels and an optional account":
    let t = cs.connectScreen(s)
    for k in ["host", "port", "nick", "channels", "account", "sasl-password",
              "server-password"]:
      check k in t.keys("entry")
    check "Account (optional)" in t.labels("title-2")

  test "the password fields hide what is typed, and nothing else does":
    for e in cs.connectScreen(s).find("entry"):
      let key = e.props{"key"}.getStr()
      check e.props{"password"}.getBool() == key.endsWith("password")

  test "the error note keeps its place whether or not there is an error":
    # The bug the stable wrapper exists for: a renderer matching children by
    # position would patch the header into a card when the error appeared.
    let before = cs.connectScreen(s).children.mapIt(it.tag)
    s.hasError = true
    s.error = "nope"
    check cs.connectScreen(s).children.mapIt(it.tag) == before
    check "Dismiss" in cs.connectScreen(s).labels("button")

  test "connecting swaps Connect for a spinner and a way out":
    s.connecting = true
    let t = cs.connectScreen(s)
    check t.find("spinner").len == 1
    check "Connect" notin t.labels("button")
    check "Cancel" in t.labels("button")

suite "discover":
  setup:
    var s = initState()

  test "before a LIST it offers to ask for one":
    let t = ss.discoverScreen(s)
    check "Refresh" in t.labels("button")
    check t.labels("dim-label").anyIt("Ask the server" in it)

  test "lists what LIST answered, with Join or Open":
    s.listing = @[ListEntry(name: "#a", users: 40, topic: "about a"),
                  ListEntry(name: "#test", users: 3)]
    var r = initRoom("#test"); r.joined = true
    s.rooms["#test"] = r
    let t = ss.discoverScreen(s)
    check t.labels("title-2") == @["#a", "#test"]
    check "Join" in t.labels("button")
    check "Open" in t.labels("button")
    check "40 users" in t.labels("dim-label")

  test "the tab bar is under it, with Discover selected":
    let t = ss.discoverScreen(s)
    s.screen = scDiscover
    let sel = ss.discoverScreen(s).find("button")
      .filterIt(it.props{"kind"}.getStr() == "primary")
      .mapIt(it.props{"label"}.getStr())
    check "Discover" in sel
    check t.find("scroll").len == 1

suite "direct messages":
  test "shows only direct-message buffers":
    var s = initState()
    var room = initRoom("#test"); room.joined = true
    var direct = initRoom("alice")
    s.rooms[room.name] = room
    s.rooms[direct.name] = direct
    let t = ch.dmsScreen(s, true)
    check "alice" in t.labels("title-2")
    check "#test" notin t.labels("title-2")
    check "DMs" in t.labels("button")

  test "the DMs tab is selected":
    var s = initState()
    s.screen = scDms
    let selected = ch.dmsScreen(s, false).find("button")
      .filterIt(it.props{"kind"}.getStr() == "primary")
      .mapIt(it.props{"label"}.getStr())
    check "DMs" in selected

suite "settings":
  setup:
    var s = initState()

  test "a guest is told so":
    check "Not signed in to an account." in
      ss.settingsScreen(s, connected = false, desktop = true).labels("dim-label")

  test "an account SASL settled on is shown":
    s.account = "alice"
    let t = ss.settingsScreen(s, connected = true, desktop = true)
    check "Signed in as alice" in t.labels("dim-label")

  test "Disconnect when connected, Back to connect when not":
    check "Disconnect" in
      ss.settingsScreen(s, connected = true, desktop = true).labels("button")
    check "Back to connect" in
      ss.settingsScreen(s, connected = false, desktop = true).labels("button")

  test "Quit only where there is a window to quit":
    check "Quit" in
      ss.settingsScreen(s, connected = false, desktop = true).labels("button")
    check "Quit" notin
      ss.settingsScreen(s, connected = false, desktop = false).labels("button")

  test "the join/part switch reflects the cell":
    let off = ss.settingsScreen(s, false, true).find("checkbutton")[0]
    check not off.props{"active"}.getBool()
    s.hideJoinPart = true
    let on = ss.settingsScreen(s, false, true).find("checkbutton")[0]
    check on.props{"active"}.getBool()

  test "the status line is live only when connected":
    check ss.settingsScreen(s, true, true).find("status")[0]
            .props{"live"}.getBool()
    check not ss.settingsScreen(s, false, true).find("status")[0]
            .props{"live"}.getBool()

suite "previewLine":
  test "collapses whitespace so a card reads as one line":
    check ch.previewLine("a\n  b\tc") == "a b c"
  test "truncates a pasted script rather than growing the card":
    let long = "x".repeat(200)
    check ch.previewLine(long).runeLen == 60
    check ch.previewLine(long).endsWith("…")

  test "truncates by character, not by byte":
    # A byte slice at 59 lands inside a multi-byte character and produces
    # mojibake where an ellipsis was wanted. The first draft did exactly that.
    let emoji = "😀".repeat(100)
    let got = ch.previewLine(emoji)
    check got.runeLen == 60
    check got.validateUtf8 == -1
  test "leaves a short line alone":
    check ch.previewLine("hello there") == "hello there"

suite "the chats screen":
  setup:
    var s = initState()
    var r = initRoom("#test")
    r.joined = true
    r.messages = @[Message(frm: "alice", text: "hello")]
    s.rooms["#test"] = r

  test "an empty list says so instead of showing nothing":
    var empty = initState()
    check "No conversations yet — join a channel." in
      ch.chatsScreen(empty, false).labels("dim-label")

  test "a room is a card with its name and last line":
    let t = ch.chatsScreen(s, true)
    check "#test" in t.labels("title-2")
    check "alice: hello" in t.labels("dim-label")

  test "the title says who we are when connected":
    check "Logged in as nirc-guest" in ch.chatsScreen(s, true).labels("title")
    check "Chats" in ch.chatsScreen(s, false).labels("title")

  test "an unread count shows, with a mention marked differently":
    var u = s.rooms["#test"]
    u.unread = 3
    s.rooms["#test"] = u
    check "● 3" in ch.chatsScreen(s, true).labels("label")
    u.mention = true
    s.rooms["#test"] = u
    check "◆ @ 3" in ch.chatsScreen(s, true).labels("label")

  test "mark all read is offered only when something is unread":
    check "Mark all read" notin ch.chatsScreen(s, true).labels("button")
    var u = s.rooms["#test"]
    u.unread = 2
    s.rooms["#test"] = u
    let t = ch.chatsScreen(s, true)
    check "Mark all read" in t.labels("button")
    check t.find("button").anyIt(it.props{"onClick"}.getStr() == "rooms.mark-read")

  test "a channel we are not in is badged, a DM never is":
    var away = s.rooms["#test"]
    away.joined = false
    s.rooms["#test"] = away
    check "not joined" in ch.chatsScreen(s, true).labels("status")
    var dmr = initRoom("alice")
    s.rooms["alice"] = dmr
    # Still only the one badge: a DM has nothing to join.
    check ch.chatsScreen(s, true).labels("status").countIt(it == "not joined") == 1

  test "the button says Message for a nick and Join for a channel":
    s.joinInput = "#room"
    check "Join" in ch.chatsScreen(s, true).labels("button")
    s.joinInput = "@alice"
    check "Message" in ch.chatsScreen(s, true).labels("button")

  test "the search box offers a clear only when there is something to clear":
    check "✕" notin ch.chatsScreen(s, true).labels("button")
    s.search = "te"
    check "✕" in ch.chatsScreen(s, true).labels("button")

  test "search filters the list":
    s.rooms["#other"] = initRoom("#other")
    s.search = "oth"
    let names = ch.chatsScreen(s, true).labels("title-2")
    check names == @["#other"]

suite "the chat screen's panes":
  setup:
    var s = initState()
    s.formNick = "me"
    s.windowWidth = wideWidth      # both panes on screen
    s.rooms.ensureRoom("#test")
    var r = s.rooms["#test"]
    r.joined = true
    r.users = {"me": "", "alice": "@"}.toTable
    r.messages = @[Message(id: "1", frm: "alice", text: "hi",
                           at: 1_700_000_000_000'i64)]
    s.rooms["#test"] = r
    s.current = "#test"
    # What `room.open` does, and what the tab bar reads to light Chats.
    s.screen = scChat

  test "a profile offers Message for somebody else, not for yourself":
    s.formNick = "me"
    s.profileViewing = ProfileView(has: true, nick: "alice")
    check "Message" in cht.chatScreen(s, true).labels("button")
    s.profileViewing = ProfileView(has: true, nick: "Me")
    check "Message" notin cht.chatScreen(s, true).labels("button")

  test "the backlog and the rooms sit side by side when the list is up":
    # The toggle had a button and rendered nothing at all: `hideChatList` was
    # read for the button's own highlight and by nobody else.
    s.hideChatList = false
    let t = cht.chatScreen(s, true)
    check "chat-list-pane" in t.keys("vbox")
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "chat-list-pane" and
                               it.children.len > 0)
    check "messages" in t.keys("vbox")

  test "and the strip goes away when it is folded":
    s.hideChatList = true
    let t = cht.chatScreen(s, true)
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "chat-list-pane" and
                               it.children.len == 0)

  test "the people strip is beside the backlog, not instead of it":
    # It used to take the whole pane on a narrow window, so asking who was in
    # a room meant losing the room while you looked.
    s.windowWidth = wideWidth - 1  # one pane at a time
    s.showUsers = true
    let t = cht.chatScreen(s, true)
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "people-pane" and
                               it.children.len > 0)
    check t.find("scroll").anyIt(
      it.props{"scrollKey"}.getStr() == "messages-#test")

  test "a crowded room's people scroll rather than stretch the window":
    # Joining #linux on Libera put a member list taller than any window in a
    # plain column; GTK grew the window to 50,200 pixels to hold it, Wayland
    # refused the surface, and nirc segfaulted.
    for i in 0 ..< 2000: s.rooms["#test"].users["user" & $i] = ""
    s.windowWidth = wideWidth
    s.hideChatList = false
    s.showUsers = true
    let t = cht.chatScreen(s, true)
    for key in ["people-list", "chat-list"]:
      check t.find("scroll").anyIt(it.props{"key"}.getStr() == key)
      check key notin t.keys("vbox")

  test "and only the stretch around the reader is built":
    # A widget per member took a second to open #linux, and as long again to
    # leave it.
    for i in 0 ..< 2000: s.rooms["#test"].users["user" & $i] = ""
    s.windowWidth = wideWidth
    s.peopleBucket = 0
    proc people(s: State): Node =
      cht.chatScreen(s, true).find("scroll").filterIt(
        it.props{"key"}.getStr() == "people-list")[0]
    proc nicks(list: Node): seq[string] =
      for row in list.children:
        let k = row.props{"key"}.getStr()
        if k.startsWith("member-"): result.add k["member-".len .. ^1]
    proc space(list: Node): int =
      for row in list.children:
        if row.props{"key"}.getStr().startsWith("people-"):
          result += row.props{"heightRequest"}.getInt()
    let top = people(s)
    check top.nicks.len == 3 * cht.peopleChunk  # nothing above the first
    check top.nicks[0] == "alice"          # ops first, as ever
    check top.props{"scrollBuckets"}.getInt() == (2002 + 39) div 40
    check top.space == (2002 - top.nicks.len) * 22
    s.peopleBucket = 30
    let deep = people(s)
    check deep.nicks.len == 4 * cht.peopleChunk
    check deep.space == (2002 - deep.nicks.len) * 22
    check deep.children[0].props{"heightRequest"}.getInt() == 29 * 40 * 22
    # Past the end, as a stale bucket from a longer room would be: the last
    # stretch, not nothing.
    s.peopleBucket = 999
    check people(s).nicks[^1] == memberList(s.rooms["#test"].users)[^1].nick

  test "the way to DMs, Discover and Settings is on the screen":
    # It was not: the chat screen never carried the tab bar, and on a wide
    # window there is no back button either — the room list is a strip. So
    # from a conversation there was no way to any of them at all.
    let t = cht.chatScreen(s, true)
    check "DMs" in t.labels("button")
    check "Discover" in t.labels("button")
    check "Settings" in t.labels("button")

  test "and Chats is lit, because a conversation is what it leads to":
    let t = cht.chatScreen(s, true)
    let chats = t.find("button").filterIt(
      it.props{"label"}.getStr() == "Chats")
    check chats.len == 1
    check chats[0].props{"kind"}.getStr() == "primary"

  test "but not on a narrow window, which has no room for them":
    # Three tabs go to two lines at 300 points, and this screen has no 120
    # points to spare — `← Chats` is the way back there instead.
    s.windowWidth = wideWidth - 1
    let t = cht.chatScreen(s, true)
    check "Discover" notin t.labels("button")
    check "←" in t.labels("button")

  test "a room in the strip opens it, and the current one is lit":
    s.hideChatList = false
    let t = cht.chatScreen(s, true)
    let side = t.find("button").filterIt(
      it.props{"key"}.getStr().startsWith("side-"))
    check side.len == 1
    check side[0].props{"onClick"}.getStr() == "room.open:#test"
    check side[0].props{"kind"}.getStr() == "primary"

suite "the sender's row":
  setup:
    var s = initState()
    s.formNick = "me"
    s.rooms.ensureRoom("#test")
    var r = s.rooms["#test"]
    r.messages = @[Message(id: "1", frm: "alice", text: "hi",
                           at: 1_700_000_000_000'i64)]
    s.rooms["#test"] = r
    s.current = "#test"

  test "on a wide window the chips are carried to the right edge":
    # `align: end` on the chips never did anything: the row was a Wrap, which
    # packs from the left and has no slack to align with. What moves them is
    # the name expanding — it is drawn at the left of a box that grows, so
    # everything after it ends up against the far edge.
    s.windowWidth = wideWidth
    let t = cht.chatScreen(s, true)
    let senderRows = t.find("hbox").filterIt(
      it.children.anyIt(it.tag == "avatar"))
    check senderRows.len == 1
    check not senderRows[0].props{"wrap"}.getBool()
    check senderRows[0].children.anyIt(
      it.tag == "button" and it.props{"expand"}.getBool())

  test "on a narrow one it wraps instead, and nothing is pushed off":
    # With the name shrunk to nothing the face, the time and three chips
    # still ask for more than a phone has, so there the row wraps as before —
    # and nothing expands, because a Wrap has no slack to give.
    s.windowWidth = wideWidth - 1  # one pane at a time
    let t = cht.chatScreen(s, true)
    let senderRows = t.find("hbox").filterIt(
      it.children.anyIt(it.tag == "avatar"))
    check senderRows.len == 1
    check senderRows[0].props{"wrap"}.getBool()
    check not senderRows[0].children.anyIt(
      it.tag == "button" and it.props{"expand"}.getBool())

suite "the profile panel":
  setup:
    var s = initState()
    s.formNick = "me"
    s.rooms.ensureRoom("#test")
    s.current = "#test"
    s.profileViewing = ProfileView(has: true, nick: "alice")

  test "waits for WHOIS, and says so":
    check "Asking the server…" in cht.chatScreen(s, true).labels("dim-label")

  test "shows what WHOIS said":
    s.whois["alice"] = Whois(user: "al", host: "example.org",
                             realname: "Alice A", account: "alice")
    let t = cht.chatScreen(s, true)
    check "account" in t.labels("dim-label")
    check t.find("text").anyIt(it.props{"text"}.getStr() == "al@example.org")
