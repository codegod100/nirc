## What this client says back to a server, given what a server says to it.
##
## The reducer's answer to an incoming line was the largest untested thing in
## the program: reachable only through a real socket, so nothing checked it.
## That is where the missing CHATHISTORY request sat through the whole port —
## every room came back with no history and the only comment about it was in
## another module, describing behaviour that had never been ported.
##
## `conn.feed` puts a line in as though the server had sent it; `tryOutbound`
## reads what went out. No socket at either end.

import std/[json, options, sequtils, strutils, tables, unittest]
import nirc/[cells, model, reactions, reducer, rooms]
import nirc/conn as tr

proc sent(): seq[string] =
  ## Everything queued to go out, drained.
  while true:
    let (ok, line) = tr.tryOutbound()
    if not ok: break
    result.add line

proc say(lines: varargs[string]) =
  for l in lines: tr.feed(l)
  drain()

proc reset() =
  app = initState()
  app.formNick = "alice"
  chanPrefixes = "#&"
  # A server that keeps history and says so.
  say(":s CAP alice ACK :draft/chathistory server-time message-tags")
  discard sent()

proc joined(room: string) =
  ## The server putting us in a room, which is how every one of them starts —
  ## a JOIN we sent, or one freeq made for a signed-in account at
  ## registration. A 366 for a room this client has never heard of is not
  ## ours and is left alone.
  say(":alice!a@h JOIN " & room)
  discard sent()

suite "asking for the backlog":
  setup: reset()

  test "end of NAMES in an empty room asks for history":
    joined("#nirc")
    # freeq re-joins an authenticated user's channels at registration and
    # leaves the backlog for the client to ask for. A room that arrives this
    # way has no history coming unless we ask, which is why a signed-in
    # connection showed new lines and nothing else.
    say(":server 366 alice #nirc :End of /NAMES list")
    check app.rooms.hasKey("#nirc")
    check sent().anyIt(it.startsWith("CHATHISTORY LATEST #nirc * "))

  test "and asks for a hundred lines of it":
    joined("#nirc")
    say(":server 366 alice #nirc :End of /NAMES list")
    check "CHATHISTORY LATEST #nirc * 100" in sent()

  test "a room that already has lines is not asked twice":
    # The replay comes back as ordinary PRIVMSGs; asking again is a second
    # copy of the same history crossing the wire to be thrown away.
    joined("#nirc")
    say(":bob!b@h PRIVMSG #nirc :already here")
    discard sent()
    say(":server 366 alice #nirc :End of /NAMES list")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

  test "a reconnect that brings no backlog asks, though the buffer is full":
    # freeq answers a reconnect by reclaiming the ghost session: JOIN and
    # NAMES, and no replay between them. The buffer still holds the lines
    # from before the drop, and testing it for emptiness is what left every
    # line said while we were away missing.
    joined("#nirc")
    say("@msgid=a1 :bob!b@h PRIVMSG #nirc :before the drop",
        ":server 366 alice #nirc :End of /NAMES list")
    discard sent()
    joined("#nirc")
    say(":server 366 alice #nirc :End of /NAMES list")
    check "CHATHISTORY LATEST #nirc * 100" in sent()

  test "a rejoin that replays lines we already hold does not ask again":
    joined("#nirc")
    say("@msgid=a1 :bob!b@h PRIVMSG #nirc :before the drop",
        ":server 366 alice #nirc :End of /NAMES list")
    discard sent()
    joined("#nirc")
    say("@msgid=a1 :bob!b@h PRIVMSG #nirc :before the drop",
        ":server 366 alice #nirc :End of /NAMES list")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

  test "a room this client was never put in is not asked about":
    # Not a room of ours: 366 for it arrives before any JOIN, and answering
    # it would ask a server for the history of somewhere we are not.
    say(":server 366 alice #nowhere :End of /NAMES list")
    check not app.rooms.hasKey("#nowhere")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

suite "the rest of the conversation":
  setup: reset()

  test "a PING is answered with its own token":
    say("PING :abc123")
    check "PONG :abc123" in sent()

  test "our own JOIN marks the room joined; somebody else's adds a name":
    say(":alice!a@h JOIN #nirc")
    check app.rooms["#nirc"].joined
    say(":bob!b@h JOIN #nirc")
    check app.rooms["#nirc"].users.hasKey("bob")

  test "NAMES arrives over several lines and lands in one go":
    joined("#nirc")
    say(":server 353 alice = #nirc :alice @bob",
        ":server 353 alice = #nirc :carol")
    # Still pending: replacing the list per line empties the panel and
    # refills it a name at a time.
    check app.rooms["#nirc"].users.len == 0
    say(":server 366 alice #nirc :End of /NAMES list")
    check app.rooms["#nirc"].users.len == 3

  test "a replayed line lands in the room it names":
    joined("#nirc")
    say(":server 366 alice #nirc :End of /NAMES list",
        ":bob!b@h PRIVMSG #nirc :an old line")
    check app.rooms["#nirc"].messages.anyIt(it.text == "an old line")

  test "a message to us is filed under whoever sent it":
    say(":bob!b@h PRIVMSG alice :a direct word")
    check app.rooms.hasKey("bob")
    check app.rooms["bob"].messages[^1].text == "a direct word"

  test "an empty late notice does not create a phantom latest row":
    joined("#nirc")
    say("@time=2026-09-23T19:00:00Z :bob!b@h PRIVMSG #nirc :current")
    say("@time=2026-09-17T19:00:00Z :server NOTICE #nirc :")
    let messages = app.rooms["#nirc"].messages.filterIt(not it.system)
    check messages.len == 1
    check messages[0].text == "current"

  test "a channel notice lands in its channel, not the one on screen":
    joined("#nirc")
    joined("#other")
    app.current = "#other"
    say(":server NOTICE #nirc :maintenance at noon")
    check app.rooms["#nirc"].messages.anyIt(it.text == "maintenance at noon")
    check not app.rooms["#other"].messages.anyIt(it.text == "maintenance at noon")

  test "a late history replay is placed by server time":
    joined("#nirc")
    say("@time=2026-09-23T19:00:00Z :bob!b@h PRIVMSG #nirc :current",
        "@time=2026-09-17T19:00:00Z :carol!c@h PRIVMSG #nirc :older")
    let messages = app.rooms["#nirc"].messages.filterIt(not it.system)
    check messages.mapIt(it.text) == @["older", "current"]


suite "how big the window is":
  setup: reset()

  test "the host says, in the value, which is where the renderer puts it":
    # Nothing sent this until it was noticed: `windowWidth` was zero on every
    # window there had ever been, so `wide` was always false and the whole
    # side-by-side layout was unreachable.
    #
    # The value and not the id, and this test says so because the first one
    # did not: it passed against a reducer that read the id only, while the
    # renderer sent a value nobody looked at.
    dispatch(%*{"id": "window.size", "value": "1280x760"})
    check app.windowWidth == 1280
    check app.windowHeight == 760
    check app.wide

  test "or after the colon, for a console or a test that types it":
    dispatch(%*{"id": "window.size:1280x760"})
    check app.wide

  test "and a narrow one is not wide":
    dispatch(%*{"id": "window.size", "value": "420x800"})
    check not app.wide

  test "nonsense does not move it":
    dispatch(%*{"id": "window.size", "value": "1280x760"})
    dispatch(%*{"id": "window.size", "value": "banana"})
    dispatch(%*{"id": "window.size", "value": "0x0"})
    check app.windowWidth == 1280

suite "being renamed":
  setup: reset()

  test "the server settling our name is the name we use":
    # A bouncer or services may rename us; every "is this mine?" test on a
    # line compares nicks, so the client has to follow.
    joined("#nirc")
    say(":alice!a@h NICK alice_away")
    check app.formNick == "alice_away"

  test "and somebody else's rename follows them round the room":
    joined("#nirc")
    say(":irc.example.org 353 alice = #nirc :alice @bob carol",
        ":irc.example.org 366 alice #nirc :End of /NAMES list",
        ":bob!b@h NICK robert")
    check app.rooms["#nirc"].users.hasKey("robert")
    check not app.rooms["#nirc"].users.hasKey("bob")

  test "with the mode they had":
    # An op who renames is still an op; dropping the prefix would take their
    # mode off the list until the next NAMES.
    joined("#nirc")
    say(":irc.example.org 353 alice = #nirc :alice @bob",
        ":irc.example.org 366 alice #nirc :End of /NAMES list",
        ":bob!b@h NICK robert")
    check app.rooms["#nirc"].users["robert"] == "@"

  test "and somebody we have never seen changes nothing":
    joined("#nirc")
    say(":stranger!s@h NICK someoneelse")
    check app.formNick == "alice"

suite "marking everything read":
  setup:
    reset()

  test "every room and DM is caught up":
    joined("#nirc")
    joined("#other")
    dispatch(%*{"id": "room.open:#nirc"})
    say(":bob!b@h PRIVMSG #other :over here",
        ":bob!b@h PRIVMSG alice :and here, alice")
    check app.rooms["#other"].unread > 0
    check app.rooms["bob"].unread > 0
    dispatch(%*{"id": "rooms.mark-read"})
    for name, r in app.rooms:
      check r.unread == 0
      check not r.mention

suite "receiving replies":
  setup:
    reset()
    joined("#nirc")

  test "the standardized draft reply tag names its target":
    say("@msgid=m1 :alice!a@h PRIVMSG #nirc :first",
        "@+draft/reply=m1;msgid=m2 :bob!b@h PRIVMSG #nirc :answer")
    check app.rooms["#nirc"].messageById("m2").get.replyTo == "m1"

  test "the older unprefixed reply tag is accepted too":
    say("@msgid=m1 :alice!a@h PRIVMSG #nirc :first",
        "@+reply=m1;msgid=m2 :bob!b@h PRIVMSG #nirc :answer")
    check app.rooms["#nirc"].messageById("m2").get.replyTo == "m1"


suite "a server without history":
  setup:
    reset()
    say(":s CAP alice DEL :draft/chathistory")
    discard sent()

  test "is not asked for it":
    joined("#nirc")
    say(":server 366 alice #nirc :End of /NAMES list")
    check not sent().anyIt(it.startsWith("CHATHISTORY"))

suite "registering":
  setup: reset()

  test "a nick in use is retried with an underscore, then another":
    app.formNick = "alice"
    dispatch(%*{"id": "connect"})
    discard sent()
    tr.feed(":s 433 * alice :Nickname is already in use")
    drain()
    check "NICK alice_" in sent()
    tr.feed(":s 433 * alice_ :Nickname is already in use")
    drain()
    check "NICK alice__" in sent()
    check not app.hasError
    dispatch(%*{"id": "disconnect"})

  test "001 joins the form's channels and says who we are on what":
    app.formChannels = "#one, two"
    say(":s 005 alice NETWORK=Example CHANTYPES=#& :are supported",
        ":s 001 alice :Welcome to Example")
    let wire = sent()
    check "JOIN #one" in wire
    check "JOIN #two" in wire
    check app.status == "Connected as alice on Example"
    check app.network == "Example"

  test "ISUPPORT CHANTYPES decides what a channel is":
    say(":s 005 alice CHANTYPES=#+ :are supported")
    check "+lounge".isChannel
    check not "&local".isChannel
    chanPrefixes = "#&"

  test "a refused SASL is said, with the server's reason":
    say(":s 904 alice :SASL authentication failed")
    check app.hasError
    check "SASL authentication failed" in app.error
    check "CAP END" in sent()

  test "900 says which account we are":
    say(":s 900 alice alice!a@h alice :You are now logged in as alice")
    check app.account == "alice"

suite "the status buffer":
  setup: reset()

  test "the MOTD and unread numerics go there":
    say(":s 372 alice :- welcome to the server",
        ":s 251 alice :There are 3 users")
    check app.rooms.hasKey(statusRoom)
    let texts = app.rooms[statusRoom].messages.mapIt(it.text)
    check "- welcome to the server" in texts
    check "There are 3 users" in texts

  test "a server notice goes there rather than into a DM":
    say(":irc.example.org NOTICE * :*** Looking up your hostname")
    check app.rooms[statusRoom].messages.anyIt("Looking up" in it.text)
    check not app.rooms.hasKey("irc.example.org")

  test "and so does a services notice to us":
    say(":NickServ!s@services NOTICE alice :This nickname is registered")
    check app.rooms[statusRoom].messages.anyIt("This nickname" in it.text)
    check not app.rooms.hasKey("NickServ")

  test "what is typed there goes out raw":
    dispatch(%*{"id": "room.open:" & statusRoom})
    dispatch(%*{"id": "draft.change", "value": "WHOIS bob"})
    dispatch(%*{"id": "send"})
    check "WHOIS bob" in sent()

  test "is not saved as a room":
    say(":s 372 alice :- hello")
    check statusRoom.isStatus
    check not statusRoom.dm

suite "people coming and going":
  setup:
    reset()
    joined("#a")
    joined("#b")
    say(":s 353 alice = #a :alice bob", ":s 366 alice #a :End",
        ":s 353 alice = #b :alice bob", ":s 366 alice #b :End")

  test "a QUIT takes them out of every room they were in":
    say(":bob!b@h QUIT :gone")
    check not app.rooms["#a"].users.hasKey("bob")
    check not app.rooms["#b"].users.hasKey("bob")
    check app.rooms["#a"].messages.anyIt(it.text == "bob quit (gone)")

  test "a KICK of us leaves the room unjoined":
    say(":op!o@h KICK #a alice :behave")
    check not app.rooms["#a"].joined

  test "userhost-in-names is reduced to nicks":
    say(":s 353 alice = #a :@carol!c@h dave!d@h", ":s 366 alice #a :End")
    check app.rooms["#a"].users["carol"] == "@"
    check app.rooms["#a"].users.hasKey("dave")

suite "reactions and redaction":
  setup:
    reset()
    joined("#nirc")
    say("@msgid=m1 :bob!b@h PRIVMSG #nirc :hello")

  test "a +draft/react TAGMSG puts a pill on the line":
    say("@+draft/react=👍;+draft/reply=m1 :carol!c@h TAGMSG #nirc")
    let m = app.rooms["#nirc"].messageById("m1").get
    check m.countOf("👍") == 1

  test "and +draft/unreact takes it off":
    say("@+draft/react=👍;+draft/reply=m1 :carol!c@h TAGMSG #nirc",
        "@+draft/unreact=👍;+draft/reply=m1 :carol!c@h TAGMSG #nirc")
    check app.rooms["#nirc"].messageById("m1").get.countOf("👍") == 0

  test "reacting sends the tags":
    dispatch(%*{"id": "room.open:#nirc"})
    dispatch(%*{"id": "react.toggle:m1:🎉"})
    check sent().anyIt(it.startsWith("@+draft/react=🎉;+draft/reply=m1 TAGMSG #nirc"))

  test "a REDACT takes the line away":
    say(":bob!b@h REDACT #nirc m1")
    check app.rooms["#nirc"].messageById("m1").isNone

suite "WHOIS and LIST":
  setup: reset()

  test "WHOIS fills the profile panel":
    dispatch(%*{"id": "profile.open:bob"})
    check "WHOIS bob" in sent()
    say(":s 311 alice bob b example.org * :Bob B",
        ":s 330 alice bob bobacct :is logged in as",
        ":s 318 alice bob :End of WHOIS")
    check app.whois["bob"].realname == "Bob B"
    check app.whois["bob"].account == "bobacct"

  test "LIST fills Discover, busiest first":
    say(":s 321 alice Channel :Users Name",
        ":s 322 alice #quiet 2 :shh",
        ":s 322 alice #busy 90 :lots",
        ":s 323 alice :End of /LIST")
    check app.listing.mapIt(it.name) == @["#busy", "#quiet"]
    check not app.listing322

suite "CTCP":
  setup: reset()

  test "VERSION is answered, and is not a line":
    say(":bob!b@h PRIVMSG alice :\x01VERSION\x01")
    check sent().anyIt(it.startsWith("NOTICE bob :\x01VERSION nirc"))
    check not app.rooms.hasKey("bob")
