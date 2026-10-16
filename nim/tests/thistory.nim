## What was said, on disk: kept, put back on the next run, and not doubled
## when the server replays the same lines.
##
## Both XDG directories point at a sandbox of this test's own, set before
## anything opens: the alternative is a suite that writes into the history of
## whoever runs it.

import std/[json, os, sequtils, tables, times, unittest]

let sandbox = getTempDir() / "nirc-thistory-" & $epochTime()
putEnv("XDG_CONFIG_HOME", sandbox / "config")
putEnv("XDG_DATA_HOME", sandbox / "data")

import nirc/[cells, model, history, reducer, store]
import nirc/conn as tr

proc say(lines: varargs[string]) =
  for l in lines: tr.feed(l)
  drain()
  while tr.tryOutbound()[0]: discard

proc run() =
  ## A fresh start of the program, as far as the state goes: what is on disk
  ## is all that carries over.
  history.close()
  app = initState()
  restore()

proc texts(room: string): seq[string] =
  app.rooms[room].messages.filterIt(not it.system).mapIt(it.text)

suite "kept history":
  setup:
    removeDir(sandbox)
    discard saveServer(SavedServer(host: "irc.example.org", port: "6697",
                                   tls: true, nick: "alice"))
    run()
    say(":s CAP alice ACK :draft/chathistory server-time message-tags",
        ":s 001 alice :Welcome", ":alice!a@h JOIN #nirc")

  test "lives in the data directory":
    check historyFile() == sandbox / "data" / "nirc" / "history.sqlite3"
    check fileExists(historyFile())

  test "comes back on the next run, before connecting":
    say("@msgid=m1;time=2026-10-16T01:00:00.000Z :bob!b@h PRIVMSG #nirc :one",
        "@msgid=m2;time=2026-10-16T01:01:00.000Z :bob!b@h PRIVMSG #nirc :two")
    discard saveRooms(app.rooms)
    run()
    check texts("#nirc") == @["one", "two"]
    check app.rooms["#nirc"].messages[0].id == "m1"

  test "a replay of kept lines is not doubled":
    say("@msgid=m1;time=2026-10-16T01:00:00.000Z :bob!b@h PRIVMSG #nirc :one")
    discard saveRooms(app.rooms)
    run()
    say(":s 001 alice :Welcome", ":alice!a@h JOIN #nirc",
        "@msgid=m1;time=2026-10-16T01:00:00.000Z :bob!b@h PRIVMSG #nirc :one",
        "@msgid=m3;time=2026-10-16T01:02:00.000Z :bob!b@h PRIVMSG #nirc :three")
    check texts("#nirc") == @["one", "three"]
    run()
    check texts("#nirc") == @["one", "three"]

  test "joins and parts are not kept":
    say(":bob!b@h JOIN #nirc", ":bob!b@h PART #nirc :bye")
    check history.load("irc.example.org", "#nirc").len == 0

  test "a redacted line is gone from the disk":
    say("@msgid=m1 :bob!b@h PRIVMSG #nirc :oops",
        ":bob!b@h REDACT #nirc m1")
    check history.load("irc.example.org", "#nirc").len == 0

  test "our own line is kept once the server names it":
    say(":s CAP alice ACK :echo-message")
    app.current = "#nirc"
    app.draft = "hello"
    dispatch(%*{"id": "send"})
    check history.load("irc.example.org", "#nirc").len == 0
    say("@msgid=e1 :alice!a@h PRIVMSG #nirc :hello")
    let kept = history.load("irc.example.org", "#nirc")
    check kept.len == 1
    check kept[0].id == "e1"

  test "rooms are one room whatever their case":
    say("@msgid=m1 :bob!b@h PRIVMSG #NIRC :loud")
    check history.load("irc.example.org", "#nirc").len == 1

  test "another server's history stays out":
    say("@msgid=m1 :bob!b@h PRIVMSG #nirc :here")
    discard saveRooms(app.rooms)
    run()
    app.formHost = "irc.elsewhere.net"
    say(":s 001 alice :Welcome")
    check texts("#nirc").len == 0

removeDir(sandbox)
