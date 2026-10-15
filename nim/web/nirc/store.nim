## What this client keeps between visits, in a browser.
##
## `localStorage` where the desktop has `$XDG_CONFIG_HOME/nirc`. The same three
## files, the same JSON in them, under keys named for what they were: a reader
## who moves between the two does not carry their rooms across, but a reader
## who reloads the page keeps them.
##
## No password is kept here either: `localStorage` is readable by every script
## the origin runs.

import std/[json, tables]
import nirc/[model, trace]

type
  SavedServer* = object
    host*, port*, nick*, account*, channels*: string
    tls*: bool

  SavedRoom* = object
    name*: string
    accessed*: int64
    lastReadId*: string
    lastReadAt*: int64

{.emit: """
function nircStoreGet(k) {
  try { return window.localStorage.getItem(k) || ""; } catch (e) { return ""; }
}
function nircStoreSet(k, v) {
  try { window.localStorage.setItem(k, v); return true; } catch (e) { return false; }
}
function nircStoreDel(k) {
  try { window.localStorage.removeItem(k); } catch (e) {}
}
""".}

proc getItem(key: cstring): cstring {.importc: "nircStoreGet".}
proc setItem(key, value: cstring): bool {.importc: "nircStoreSet".}
proc delItem(key: cstring) {.importc: "nircStoreDel".}

const
  serverKey = "nirc.server"
  roomsKey = "nirc.rooms"
  prefsKey = "nirc.prefs"

proc readJson(key: string): JsonNode =
  ## Absent and unparseable are the same answer here as on the desktop: a
  ## stale credential is not worth an error on load.
  let raw = $getItem(key.cstring)
  if raw.len == 0: return nil
  try: parseJson(raw)
  except CatchableError as e:
    trace("store", "ignoring " & key & ": " & e.msg)
    nil

proc loadServer*(): (SavedServer, bool) =
  let j = readJson(serverKey)
  if j.isNil or j.kind != JObject: return (SavedServer(), false)
  let s = SavedServer(host: j{"host"}.getStr(), port: j{"port"}.getStr(),
                      tls: j{"tls"}.getBool(true), nick: j{"nick"}.getStr(),
                      account: j{"account"}.getStr(),
                      channels: j{"channels"}.getStr())
  (s, s.host.len > 0)

proc saveServer*(s: SavedServer): bool =
  setItem(serverKey.cstring,
          ($(%*{"host": s.host, "port": s.port, "tls": s.tls, "nick": s.nick,
                "account": s.account, "channels": s.channels})).cstring)

proc loadRooms*(): seq[SavedRoom] =
  let j = readJson(roomsKey)
  if j.isNil or j.kind != JArray: return
  for r in j:
    let name = r{"name"}.getStr()
    if name.len == 0: continue
    result.add SavedRoom(name: name,
                         accessed: r{"accessed"}.getBiggestInt(),
                         lastReadId: r{"lastReadId"}.getStr(),
                         lastReadAt: r{"lastReadAt"}.getBiggestInt())

proc saveRooms*(rooms: OrderedTable[string, Room]): bool =
  var arr = newJArray()
  for name, r in rooms:
    arr.add %*{"name": name, "accessed": r.accessed,
               "lastReadId": r.lastReadId, "lastReadAt": r.lastReadAt}
  setItem(roomsKey.cstring, ($arr).cstring)

proc loadPrefs*(): Table[string, bool] =
  let j = readJson(prefsKey)
  if j.isNil or j.kind != JObject: return
  for k, v in j:
    if v.kind == JBool: result[k] = v.getBool()

proc savePrefs*(prefs: Table[string, bool]): bool =
  var o = newJObject()
  for k, v in prefs: o[k] = %v
  setItem(prefsKey.cstring, ($o).cstring)
