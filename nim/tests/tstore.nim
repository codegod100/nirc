## What survives a restart, and what deliberately does not.
##
## Every test here points `XDG_CONFIG_HOME` at a directory of its own, set
## before `nirc/store` is touched at all: the alternative is a suite that reads
## and writes the config of whoever runs it, which would both lie about the
## result and cost them their room list.

import std/[json, os, sequtils, strutils, tables, times, unittest]

let sandbox = getTempDir() / "nirc-tstore-" & $epochTime()
putEnv("XDG_CONFIG_HOME", sandbox)

import nirc/[cells, clock, model, rooms, store, reducer, keyring]

useMemory()

proc clean() =
  removeDir(sandbox)
  app = initState()

suite "the config directory":
  test "is under XDG_CONFIG_HOME where there is one":
    check configDir() == sandbox / "nirc"

suite "a saved server":
  setup: clean()
  test "round-trips, and says whether there was one":
    check loadServer()[1] == false
    check saveServer(SavedServer(host: "irc.example.org", port: "6697",
                                 tls: true, nick: "alice", account: "alice",
                                 channels: "#a, #b"))
    let (s, had) = loadServer()
    check had
    check s.host == "irc.example.org"
    check s.channels == "#a, #b"
  test "connecting saves the form, but never a password":
    app.formHost = "irc.example.org"
    app.formNick = "alice"
    app.formAccount = "alice"
    app.formSaslPassword = "hunter2"
    app.formServerPassword = "letmein"
    dispatch(%*{"id": "connect"})
    let saved = readFile(serverFile())
    check "irc.example.org" in saved
    check "hunter2" notin saved
    check "letmein" notin saved
    dispatch(%*{"id": "disconnect"})
  test "and restore puts it back on the form":
    check saveServer(SavedServer(host: "irc.example.org", port: "6667",
                                 tls: false, nick: "bob", channels: "#x"))
    restore()
    check app.formHost == "irc.example.org"
    check app.formPort == "6667"
    check not app.formTls
    check app.formNick == "bob"
    check app.formChannels == "#x"

suite "passwords in the keyring":
  setup:
    clean()
    useMemory()
    app.keyring = true
    app.formHost = "irc.example.org"
    app.formPort = "6697"
    app.formNick = "alice"
    app.formAccount = "alice"
    app.formSaslPassword = "hunter2"
    app.formServerPassword = "letmein"
  test "connecting keeps them, and restore puts them back":
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    check recall("sasl", "irc.example.org", "alice") == "hunter2"
    check recall("server", "irc.example.org", "6697") == "letmein"
    app = initState()
    restore()
    check app.keyring
    check app.formSaslPassword == "hunter2"
    check app.formServerPassword == "letmein"
  test "an emptied field forgets its password":
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    app.formServerPassword = ""
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    check recall("server", "irc.example.org", "6697") == ""
    check recall("sasl", "irc.example.org", "alice") == "hunter2"
  test "unticking remember forgets them at the next connect, and stays off":
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    dispatch(%*{"id": "remember-passwords.toggle"})
    check not app.rememberPasswords
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    check recall("sasl", "irc.example.org", "alice") == ""
    check recall("server", "irc.example.org", "6697") == ""
    app = initState()
    restore()
    check not app.rememberPasswords
    check app.formSaslPassword == ""
  test "a password belongs to its account and host":
    dispatch(%*{"id": "connect"})
    dispatch(%*{"id": "disconnect"})
    check recall("sasl", "irc.example.org", "bob") == ""
    check recall("sasl", "irc.other.net", "alice") == ""

suite "the rooms file":
  setup: clean()

  proc saved(): seq[SavedRoom] =
    var rooms: OrderedTable[string, Room]
    for (name, accessed, id, at) in [("#a", 100'i64, "m1", 900'i64),
                                     ("#b", 300'i64, "m2", 800'i64),
                                     ("carol", 200'i64, "", 0'i64)]:
      var r = initRoom(name)
      r.accessed = accessed
      r.lastReadId = id
      r.lastReadAt = at
      r.messages = @[Message(id: "x", frm: "bob", text: "hi", at: 1000)]
      rooms[name] = r
    check saveRooms(rooms)
    loadRooms()

  test "keeps the name and the marker, and not the messages":
    # The list is the part worth keeping; the lines in it come from the
    # server, and a client that saved them would be a second copy to go
    # stale.
    let rs = saved()
    check rs.len == 3
    check rs[0].name == "#a"
    check rs[0].lastReadId == "m1"
    check rs[0].lastReadAt == 900

  test "restore brings them back empty, unjoined, with their markers":
    discard saved()
    restore()
    check app.rooms.len == 3
    check app.rooms["#a"].messages.len == 0
    check not app.rooms["#a"].joined
    check app.rooms["#a"].lastReadId == "m1"
    check app.rooms["#a"].accessed == 100
    check app.rooms["#b"].accessed == 300

  test "and restored rooms have the same stable alphabetical order":
    discard saved()
    restore()
    check channelList(app.rooms, "").mapIt(it.name) == @["#a", "#b", "carol"]

  test "a record with no marker is caught up, not unread from the start":
    # An older nirc's file, or one that lost it. The alternative announces a
    # hundred lines the reader has already seen.
    discard saved()
    restore()
    let before = nowMs()
    check app.rooms["carol"].lastReadAt >= before - 5000
    check app.rooms["carol"].lastReadAt > 0

  test "a room the reader has closed stays closed":
    discard saved()
    restore()
    dispatch(%*{"id": "room.leave:#a"})
    app = initState()
    restore()
    check not app.rooms.hasKey("#a")
    check app.rooms.hasKey("#b")

suite "the prefs file":
  setup: clean()
  test "the display toggles outlive the run":
    restore()
    let wasJoinPart = app.hideJoinPart
    dispatch(%*{"id": "join-part.toggle"})
    dispatch(%*{"id": "chat-list.toggle"})
    app = initState()
    restore()
    check app.hideJoinPart == not wasJoinPart
    check app.hideChatList

  test "but the member list does not":
    # On a narrow window the people panel is the pane rather than something
    # beside it, so a remembered "on" opens a room and shows a list of names
    # instead of the room.
    restore()
    dispatch(%*{"id": "users.toggle"})
    check app.showUsers
    app = initState()
    restore()
    check not app.showUsers

  test "folding it away on a wide window is remembered":
    restore()
    app.windowWidth = 1200
    dispatch(%*{"id": "users.toggle"})
    check app.hideUsers
    app = initState()
    restore()
    check app.hideUsers
  test "and a prefs file that is not there is a first run, not an error":
    check loadPrefs().len == 0
    restore()
    check not app.hideJoinPart
