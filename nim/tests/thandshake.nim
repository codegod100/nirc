## CAP negotiation and SASL PLAIN. No network: every case here is a line in
## and lines out.

import std/[base64, sets, strutils, unittest]
import nirc/[ircparse, handshake]

proc caps0(): HashSet[string] = initHashSet[string]()

proc guest(): Credentials = Credentials()
proc signedIn(): Credentials = Credentials(account: "alice", password: "pw")

suite "PLAIN":
  test "authzid, authcid and password, NUL-separated":
    check decode(plainPayload(signedIn())) == "alice\0alice\0pw"

  test "a guest is not signing in, nor is an account with no password":
    check not guest().signsIn
    check not Credentials(account: "alice").signsIn
    check signedIn().signsIn

suite "saslLines":
  test "a short payload is one line":
    check saslLines("abc") == @["AUTHENTICATE abc"]

  test "one that lands exactly on the boundary gets a bare + after it":
    # Or the server waits for a continuation that is not coming.
    let got = saslLines("x".repeat(saslChunk))
    check got.len == 2
    check got[1] == "AUTHENTICATE +"

  test "a longer one is split at 400":
    let got = saslLines("x".repeat(saslChunk + 5))
    check got.len == 2
    check got[0].len == "AUTHENTICATE ".len + 400

suite "step: CAP":
  test "LS asks for what it can use":
    let m = parseLine(
      ":s CAP * LS :message-tags server-time account-tag echo-message " &
      "draft/message-ids")
    let got = step(guest(), caps0(), m)
    check got.send.len == 1
    check got.send[0].startsWith("CAP REQ :")
    for c in ["message-tags", "server-time", "account-tag", "echo-message",
              "draft/message-ids"]:
      check c in got.send[0]

  test "a capability is asked for by name, not with its value":
    let m = parseLine(
      ":s CAP * LS :message-tags batch draft/multiline=max-bytes=40000,max-lines=100")
    let got = step(guest(), caps0(), m)
    check got.send[0] == "CAP REQ :message-tags batch draft/multiline"

  test "it asks only for what was offered":
    let m = parseLine(":s CAP * LS :server-time")
    check step(guest(), caps0(), m).send[0] == "CAP REQ :server-time"

  test "it ignores what it has no use for":
    let m = parseLine(":s CAP * LS :server-time znc.in/self-message")
    check step(guest(), caps0(), m).send[0] == "CAP REQ :server-time"

  test "it waits for every multiline LS fragment":
    let first = step(guest(), caps0(), caps0(),
      parseLine(":s CAP * LS * :message-tags account-tag"))
    check first.send.len == 0
    let last = step(guest(), first.caps, first.offered,
      parseLine(":s CAP * LS :server-time echo-message draft/message-ids"))
    check last.send.len == 1
    for c in ["message-tags", "account-tag", "server-time", "echo-message",
              "draft/message-ids"]:
      check c in last.send[0]

  test "nothing on offer ends CAP rather than requesting nothing":
    check step(guest(), caps0(), parseLine(":s CAP * LS :")).send == @["CAP END"]

  test "a guest does not ask for sasl even when it is offered":
    let m = parseLine(":s CAP * LS :sasl server-time")
    check "sasl" notin step(guest(), caps0(), m).send[0]

  test "an account does":
    let m = parseLine(":s CAP * LS :sasl=PLAIN,EXTERNAL server-time")
    check "sasl" in step(signedIn(), caps0(), m).send[0]

  test "ACK with sasl starts PLAIN":
    let m = parseLine(":s CAP nick ACK :sasl server-time")
    let got = step(signedIn(), caps0(), m)
    check got.send == @["AUTHENTICATE PLAIN"]
    check "sasl" in got.caps
    check "server-time" in got.caps

  test "ACK without sasl ends CAP":
    let m = parseLine(":s CAP nick ACK :server-time")
    check step(guest(), caps0(), m).send == @["CAP END"]

  test "NAK ends CAP rather than hanging":
    check step(guest(), caps0(), parseLine(":s CAP nick NAK :sasl")).send ==
      @["CAP END"]

  test "NEW asks for a capability we use, after registration":
    var caps = caps0()
    caps.incl "server-time"
    let got = step(guest(), caps, parseLine(":s CAP nick NEW :away-notify foo"))
    check got.send == @["CAP REQ :away-notify"]

  test "DEL forgets one":
    var caps = caps0()
    caps.incl "server-time"
    let got = step(guest(), caps, parseLine(":s CAP nick DEL :server-time"))
    check "server-time" notin got.caps

suite "step: AUTHENTICATE":
  test "the + is answered with the PLAIN payload":
    let got = step(signedIn(), caps0(), parseLine("AUTHENTICATE +"))
    check got.send.len == 1
    check decode(got.send[0]["AUTHENTICATE ".len .. ^1]) == "alice\0alice\0pw"

  test "a guest has nothing to say":
    check step(guest(), caps0(), parseLine("AUTHENTICATE +")).send.len == 0

suite "step: the outcome":
  test "903 ends CAP so registration can proceed":
    check step(signedIn(), caps0(), parseLine(":s 903 n :ok")).send == @["CAP END"]

  test "a refusal ends CAP too rather than leaving the client hanging":
    for code in ["902", "904", "905", "906", "908"]:
      check step(signedIn(), caps0(), parseLine(":s " & code & " n :no")).send ==
        @["CAP END"]
