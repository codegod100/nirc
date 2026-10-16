## What this client keeps on disk between runs.
##
## JSON files under `$XDG_CONFIG_HOME/nirc`. Every read treats a file that will
## not parse as absent: a room with a broken marker would count its whole
## history unread, which is worse than a room that starts over.
##
## No password is ever written here: not the server's, not SASL's. Those go
## to the system keyring, through `nirc/keyring`, or nowhere.

import std/[json, os, tables]
import nirc/[model, trace]

type
  SavedServer* = object
    ## Where to connect and as whom — everything on the connect form but the
    ## passwords.
    host*, port*, nick*, account*, channels*: string
    tls*: bool

  SavedRoom* = object
    ## A room and how much of it has been seen.
    name*: string
    accessed*: int64
    lastReadId*: string
    lastReadAt*: int64

proc configDir*(): string =
  ## Where this client's files go.
  ##
  ## `$XDG_CONFIG_HOME/nirc`, or `~/.config/nirc`.
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: xdg / "nirc" else: getHomeDir() / ".config" / "nirc"

proc serverFile*(): string = configDir() / "server.json"
proc roomsFile*(): string = configDir() / "rooms.json"
proc prefsFile*(): string = configDir() / "prefs.json"

proc readJson(path: string): JsonNode =
  ## The file as JSON, or nil where it is absent or will not parse.
  if not fileExists(path): return nil
  try:
    parseJson(readFile(path))
  except CatchableError as e:
    trace("store", "ignoring " & path & ": " & e.msg)
    nil

proc loadServer*(): (SavedServer, bool) =
  ## The connection the reader last made, and whether there was one.
  let j = readJson(serverFile())
  if j.isNil or j.kind != JObject: return (SavedServer(), false)
  let s = SavedServer(host: j{"host"}.getStr(), port: j{"port"}.getStr(),
                      tls: j{"tls"}.getBool(true), nick: j{"nick"}.getStr(),
                      account: j{"account"}.getStr(),
                      channels: j{"channels"}.getStr())
  (s, s.host.len > 0)

proc saveServer*(s: SavedServer): bool =
  try:
    createDir(configDir())
    writeFile(serverFile(), $(%*{"host": s.host, "port": s.port, "tls": s.tls,
                                 "nick": s.nick, "account": s.account,
                                 "channels": s.channels}))
    true
  except CatchableError as e:
    trace("store", "could not save the server: " & e.msg)
    false

proc loadRooms*(): seq[SavedRoom] =
  ## The rooms this client knows, most recently used first.
  ##
  ## This is the authority for what rooms exist. The server forgets them — it
  ## has told us we are in rooms we are not, and left out ones we are — so a
  ## room is gone when the reader closes it here and not before.
  let j = readJson(roomsFile())
  if j.isNil or j.kind != JArray: return
  for r in j:
    let name = r{"name"}.getStr()
    if name.len == 0: continue
    result.add SavedRoom(name: name,
                         accessed: r{"accessed"}.getBiggestInt(),
                         lastReadId: r{"lastReadId"}.getStr(),
                         lastReadAt: r{"lastReadAt"}.getBiggestInt())

proc saveRooms*(rooms: OrderedTable[string, Room]): bool =
  ## The marker goes with the name, which is the point of saving at all: a
  ## phone that comes back to a hundred lines it has already read is a phone
  ## that kept the names and lost the markers.
  try:
    createDir(configDir())
    var arr = newJArray()
    for name, r in rooms:
      arr.add %*{"name": name, "accessed": r.accessed,
                 "lastReadId": r.lastReadId, "lastReadAt": r.lastReadAt}
    writeFile(roomsFile(), $arr)
    true
  except CatchableError as e:
    trace("store", "could not save the rooms: " & e.msg)
    false

proc loadPrefs*(): Table[string, bool] =
  let j = readJson(prefsFile())
  if j.isNil or j.kind != JObject: return
  for k, v in j:
    if v.kind == JBool: result[k] = v.getBool()

proc savePrefs*(prefs: Table[string, bool]): bool =
  try:
    createDir(configDir())
    var o = newJObject()
    for k, v in prefs: o[k] = %v
    writeFile(prefsFile(), $o)
    true
  except CatchableError:
    false
