## CAP negotiation and the SASL exchange inside it, as lines to send.
##
## Every step is the same question — given what the server just said, what
## does this client say back — so it answers with lines and the caller writes
## them.
##
## SASL is PLAIN, which every network that does SASL at all accepts: an
## account name and a password, base64'd, sent once over the connection the
## reader chose. Over plain TCP that is the password in the clear, which is
## why the connect screen says so.

import std/[base64, sets, strutils]
import nirc/ircparse

const
  saslChunk* = 400
    ## How much of a SASL payload goes on one AUTHENTICATE line — the IRCv3
    ## figure, with continuation lines for anything longer.

  wantedCaps* = ["message-tags", "server-time", "account-tag", "echo-message",
                 "draft/message-ids", "batch", "draft/multiline",
                 "multi-prefix", "away-notify", "extended-join",
                 "draft/chathistory", "chathistory",
                 "draft/message-redaction", "userhost-in-names",
                 "invite-notify", "chghost", "setname"]
    ## What this client can use, and why even a guest negotiates.
    ##
    ## `server-time`: without it a replayed backlog arrives untimed and every
    ## old line reads as just said. `message-tags`: client-only tags, which is
    ## how a reply (`+draft/reply`) and a reaction (`+draft/react`) travel.
    ## `echo-message`: our own lines come back, which is the only way this
    ## client learns the msgid of something it said. `batch` and
    ## `draft/multiline`: a message with line breaks in it, as one message.
    ## `draft/chathistory`: a room's backlog on request.
    ## `draft/message-redaction`: unsending a line with REDACT.

type
  Credentials* = object
    ## What this connection signs in with. An empty account is a guest, who
    ## asks for no SASL at all.
    account*, password*: string

  Step* = object
    send*: seq[string]
    caps*: HashSet[string]
    offered*: HashSet[string]

func signsIn*(c: Credentials): bool =
  c.account.len > 0 and c.password.len > 0

func capName(token: string): string =
  ## A capability can advertise a value (`sasl=PLAIN,EXTERNAL`). Negotiation
  ## names the capability, not that value.
  let eq = token.find('=')
  if eq < 0: token else: token[0 ..< eq]

proc saslLines*(payload: string): seq[string] =
  ## A payload split the way AUTHENTICATE wants it. One that lands exactly on
  ## the boundary is followed by a bare `+`, so the server knows it ended
  ## rather than waiting for a continuation that is not coming.
  if payload.len == 0: return @["AUTHENTICATE +"]
  var rest = payload
  while rest.len > saslChunk:
    result.add "AUTHENTICATE " & rest[0 ..< saslChunk]
    rest = rest[saslChunk .. ^1]
  result.add "AUTHENTICATE " & rest
  if rest.len == saslChunk:
    result.add "AUTHENTICATE +"

func plainPayload*(c: Credentials): string =
  ## RFC 4616: authzid NUL authcid NUL password. The authzid is the account
  ## itself, which is what every ircd expects.
  encode(c.account & "\0" & c.account & "\0" & c.password)

proc step*(creds: Credentials, caps, offered: HashSet[string],
           m: IrcLine): Step =
  ## What to send in answer to `m`, and what it did to the acked set.
  result.caps = caps
  result.offered = offered

  case m.command
  of "CAP":
    if m.params.len < 2: return
    let sub = m.params[1].toUpperAscii
    let offeredStr = if m.params.len >= 3: m.params[^1] else: ""

    case sub
    of "LS":
      for c in offeredStr.split({' ', '\t'}):
        if c.len > 0: result.offered.incl capName(c)
      # CAP 302 can split a long capability list over several LS replies.
      # The penultimate `*` says another fragment follows.
      if m.params.len >= 4 and m.params[^2] == "*": return
      var wanted: seq[string]
      for c in wantedCaps:
        if c in result.offered: wanted.add c
      # sasl only where there is something to authenticate with.
      if creds.signsIn and "sasl" in result.offered: wanted.add "sasl"
      result.send = @[if wanted.len > 0: "CAP REQ :" & wanted.join(" ")
                      else: "CAP END"]
    of "ACK":
      var acked: seq[string]
      for c in offeredStr.split({' ', '\t'}):
        if c.len > 0 and not c.startsWith("-"):
          result.caps.incl c
          acked.add c
      result.send = @[if "sasl" in acked and creds.signsIn:
                        "AUTHENTICATE PLAIN"
                      else: "CAP END"]
    of "NAK":
      result.send = @["CAP END"]
    of "NEW":
      # A capability that arrived mid-connection; ask for it if it is one we
      # use. Never sasl: by now registration is done.
      var wanted: seq[string]
      for c in offeredStr.split({' ', '\t'}):
        let name = capName(c)
        if name.len > 0: result.offered.incl name
        if name in wantedCaps and name notin caps: wanted.add name
      if wanted.len > 0: result.send = @["CAP REQ :" & wanted.join(" ")]
    of "DEL":
      for c in offeredStr.split({' ', '\t'}):
        if c.len > 0:
          result.caps.excl c
          result.offered.excl c
    else: discard

  of "AUTHENTICATE":
    let challenge = if m.params.len > 0: m.params[0] else: ""
    if challenge == "+" and creds.signsIn:
      result.send = saslLines(plainPayload(creds))

  of "903", "907":
    result.send = @["CAP END"]

  of "902", "904", "905", "906", "908":
    # Refused. End CAP anyway and carry on unauthenticated rather than
    # hanging — the caller reports what happened.
    result.send = @["CAP END"]

  else: discard

proc step*(creds: Credentials, caps: HashSet[string], m: IrcLine): Step =
  ## A complete, single-line exchange, for callers and focused tests that do
  ## not need to carry CAP LS fragments between server lines.
  step(creds, caps, initHashSet[string](), m)
