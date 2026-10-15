## Discover and Settings — the small two.

import std/[json, strutils, tables]
import nirc/[ui, cells, model]
import nirc/screens/[frame, connect]

func discoverScreen*(s: State): Node =
  ## The server's own room list, from LIST, busiest first. Capped: a big
  ## network lists tens of thousands, and a tree carrying them all is a tree
  ## nobody can scroll.
  const cap = 300
  var head = hbox(%*{"spacing": 8},
    dimLabel(if s.listing322: "Listing channels… " & $s.listPending.len
             elif s.listing.len > 0: $s.listing.len & " channels" &
               (if s.listing.len > cap: ", the busiest " & $cap & " shown"
                else: "")
             else: "Ask the server for its channels."),
    button("Refresh", "list.refresh"))
  var body = @[head, errorNote(s)]
  body.add n("hbox", %*{"key": "join-row", "spacing": 8}, @[
    entry("join-input", s.joinInput, "#channel or @nick", "join-input.change",
          width = 220, verbatim = true, onSubmit = "join"),
    button("Join", "join", "primary")])
  var shown = 0
  for e in s.listing:
    if shown >= cap: break
    inc shown
    let joined = s.rooms.hasKey(e.name) and s.rooms[e.name].joined
    var card0 = n("card", %*{"key": "list-" & e.name}, @[
      hbox(%*{"spacing": 8}, title2(e.name), dimLabel($e.users & " users"))])
    if e.topic.strip.len > 0:
      card0.children.add text(e.topic, lines = 2)
    card0.children.add button(if joined: "Open" else: "Join",
             (if joined: "room.open:" else: "room.join:") & e.name)
    body.add card0
  tabScreen(s, "Discover", "discover-list", body)

func settingsScreen*(s: State, connected: bool, desktop: bool): Node =
  var identity = vbox(%*{"key": "identity", "spacing": 6})
  identity.children.add label(s.formNick &
    (if s.network.len > 0: " on " & s.network else: "") &
    " — " & s.formHost)
  if s.account.len > 0:
    identity.children.add dimLabel("Signed in as " & s.account)
  else:
    identity.children.add dimLabel("Not signed in to an account.")
  if s.caps.len > 0:
    identity.children.add dimLabel("Capabilities: " & s.caps.join(" "))

  # Nothing to disconnect from when there is no connection — the way back to
  # the connect screen is what is wanted then.
  var action = vbox(%*{"key": "connection-action"})
  action.children.add(
    if connected: button("Disconnect", "disconnect", "destructive")
    else: button("Back to connect", "screen.connect"))

  var about = card(
    title2("nirc"),
    dimLabel("An IRC client — Nim on nimkit, on Linux and the web."))
  if desktop:
    about.children.add button("Quit", "quit")

  tabScreen(s, "Settings", "settings-list", [
    card(
      title2("Connection"),
      status(s.status, live = connected),
      identity,
      separator(),
      action),
    card(
      title2("Messages"),
      checkbutton("Hide join/part messages", s.hideJoinPart,
                  "join-part.toggle"),
      dimLabel("Hides other people arriving, leaving and quitting. The " &
               "people panel still follows who is here.")),
    about])
