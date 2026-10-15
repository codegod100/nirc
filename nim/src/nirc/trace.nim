## Tracing, on when `NIRC_TRACE` is set.
##
## The same switch the rest of nirc uses — README.md documents `NIRC_TRACE=1`
## for the IRC lines — because a second convention for a second language is a
## thing to remember rather than a thing to use.
##
## To stderr and not stdout: stdout is a bundle's own, and a Flutter app on
## Linux prints to the terminal it was launched from. `pixi run desktop`
## shows these inline.
##
## Cheap when off. The check is a `let` read once at load rather than a getEnv
## per call, and every `trace` call site guards on it before doing any of the
## string building — which matters because the argument to a trace call is
## usually the expensive part.

import std/[strutils, times]
when not defined(js):
  import std/os

when defined(js):
  # No environment to read, and no stderr to write to. A web build traces
  # through the console, and turns it on from there rather than from a
  # variable set before the page loaded.
  var enabled* = false
else:
  let enabled* = getEnv("NIRC_TRACE").len > 0 and getEnv("NIRC_TRACE") != "0"

proc trace*(topic: string, msg: string) =
  ## One line: a timestamp, a topic, and the message.
  if not enabled: return
  let t = now().format("HH:mm:ss'.'fff")
  let line = "[nirc " & t & "] " & topic.alignLeft(9) & " " & msg
  when defined(js):
    echo line
  else:
    stderr.writeLine(line)
  # Flushed every line rather than at exit: a trace lost when the process dies
  # is worth nothing, and the process dying is the case most worth tracing.
  when not defined(js): stderr.flushFile()

func redact*(line: string): string =
  ## An outgoing line as the trace shows it: a secret in it starred out, so a
  ## trace can be pasted into a bug report. PASS, a SASL payload, OPER, and a
  ## NickServ IDENTIFY or REGISTER typed in by hand.
  let up = line.toUpperAscii
  if up.startsWith("PASS "):
    return "PASS ***"
  if up.startsWith("AUTHENTICATE "):
    let arg = line[13 .. ^1]
    # The mechanism name and the bare `+`/`*` are not secrets; anything else
    # is the base64 of the password.
    if arg in ["+", "*"] or arg.allCharsInSet({'A'..'Z', '-', '_', '0'..'9'}):
      return line
    return "AUTHENTICATE ***"
  if up.startsWith("OPER "):
    let parts = line.splitWhitespace
    return "OPER " & (if parts.len > 1: parts[1] else: "") & " ***"
  for svc in ["NICKSERV ", "PRIVMSG NICKSERV :", "NS "]:
    if up.startsWith(svc):
      let rest = up[svc.len .. ^1]
      for verb in ["IDENTIFY", "REGISTER", "GHOST", "RECOVER"]:
        if rest.startsWith(verb):
          return line[0 ..< svc.len + verb.len] & " ***"
  line

template traced*(topic: string, body: untyped) =
  ## For a message that costs something to build. The body is not evaluated
  ## at all when tracing is off.
  if enabled:
    trace(topic, body)
