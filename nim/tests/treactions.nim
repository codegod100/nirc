## Tallies and pills.

import std/[sequtils, tables, unittest]
import nirc/[model, reactions]

suite "parseTally":
  test "the server's wire form":
    let t = parseTally("👍:alice,bob;🎉:carol")
    check t.len == 2
    check t[0].emoji == "👍"
    check t[0].nicks == @["alice", "bob"]
    check t[1].nicks == @["carol"]

  test "order is kept, because it is the order the pills are drawn in":
    check parseTally("a:1;b:2;c:3").mapIt(it.emoji) == @["a", "b", "c"]

  test "an empty tally is no pills":
    check parseTally("").len == 0

  test "a malformed part is skipped rather than fatal":
    check parseTally("👍:alice;garbage;:bob;🎉:").mapIt(it.emoji) == @["👍"]

suite "withReaction":
  setup:
    let base = @[Reaction(emoji: "👍", nicks: @["alice"])]

  test "adding a nick":
    check base.withReaction("👍", "bob", true)[0].nicks == @["alice", "bob"]

  test "adding an emoji nobody had yet":
    let got = base.withReaction("🎉", "bob", true)
    check got.len == 2
    check got[1].emoji == "🎉"

  test "the same nick twice does not double it":
    check base.withReaction("👍", "alice", true)[0].nicks == @["alice"]

  test "removing the last nick removes the pill":
    # An empty pill is a pill that says nothing.
    check base.withReaction("👍", "alice", false).len == 0

  test "removing one of several leaves the rest":
    let two = base.withReaction("👍", "bob", true)
    check two.withReaction("👍", "alice", false)[0].nicks == @["bob"]

  test "removing a nick that is not there changes nothing":
    check base.withReaction("👍", "zoe", false)[0].nicks == @["alice"]

suite "mine":
  setup:
    let m = Message(reactions: @[Reaction(emoji: "👍", nicks: @["alice"])])
  test "on it":
    check m.mine("👍", "alice")
  test "not on it":
    check not m.mine("👍", "bob")
  test "an emoji with no pill at all":
    check not m.mine("🎉", "alice")

suite "updateReaction":
  setup:
    var rooms = initOrderedTable[string, Room]()
    var r = initRoom("#test")
    r.messages = @[Message(id: "1", text: "hi"),
                   Message(id: "2", text: "there", editIds: @["2b"])]
    rooms["#test"] = r

  test "lands on the message it names":
    rooms.updateReaction("#test", "1", "👍", "alice", true)
    check rooms["#test"].messages[0].countOf("👍") == 1
    check rooms["#test"].messages[1].countOf("👍") == 0

  test "finds a line by a name a revision of it wore":
    # Somebody reacting to an already-rewritten line names the revision.
    rooms.updateReaction("#test", "2b", "🎉", "bob", true)
    check rooms["#test"].messages[1].countOf("🎉") == 1

  test "a reaction on a line we do not hold does nothing":
    rooms.updateReaction("#test", "999", "👍", "alice", true)
    check rooms["#test"].messages.allIt(it.reactions.len == 0)

  test "a room we do not hold does nothing":
    rooms.updateReaction("#gone", "1", "👍", "alice", true)
    check rooms["#test"].messages[0].reactions.len == 0
