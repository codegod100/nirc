## What was said, kept on disk between runs.
##
## One SQLite file, `$XDG_DATA_HOME/nirc/history.sqlite3`, one row per line,
## keyed by server, room and the line's own name: its msgid where the server
## gave one. A restart opens every room on what it held when it closed, and the
## server's CHATHISTORY then lands on top of it without doubling anything,
## because a msgid already stored is a row already there.
##
## Bound by hand rather than through `db_connector`: a dozen calls are all
## this needs, and the toolchain is pixi's alone, with no nimble to fetch a
## package. libsqlite comes from conda-forge beside GTK.
##
## Nothing here opens until `open` is called, which `reducer.restore` does —
## the tests that drive the reducer without restoring never touch the disk.

import std/[os, strutils]
import nirc/[model, trace]

{.passL: gorge("pkg-config --libs sqlite3").}

type
  Db = ptr object
  Stmt = ptr object

{.push importc, cdecl.}
proc sqlite3_open(path: cstring, db: var Db): cint
proc sqlite3_close(db: Db): cint
proc sqlite3_errmsg(db: Db): cstring
proc sqlite3_exec(db: Db, sql: cstring, cb, arg: pointer,
                  err: pointer): cint
proc sqlite3_prepare_v2(db: Db, sql: cstring, n: cint, st: var Stmt,
                        tail: pointer): cint
proc sqlite3_bind_text(st: Stmt, i: cint, s: cstring, n: cint,
                       destructor: int): cint
proc sqlite3_bind_int64(st: Stmt, i: cint, v: int64): cint
proc sqlite3_step(st: Stmt): cint
proc sqlite3_column_text(st: Stmt, i: cint): cstring
proc sqlite3_column_int64(st: Stmt, i: cint): int64
proc sqlite3_finalize(st: Stmt): cint
{.pop.}

const
  sqliteOk = 0
  sqliteRow = 100
  sqliteDone = 101
  sqliteTransient = -1
    ## Tells SQLite to copy a bound string, which a Nim string bound and then
    ## let go of needs.

  keep* = 500
    ## How many lines of a room come back from disk. The server's backlog is
    ## a hundred; the disk is there to reach further than that, not to hand a
    ## room every line it has ever had.

var db: Db

proc dataDir*(): string =
  ## `$XDG_DATA_HOME/nirc`, or `~/.local/share/nirc`. Data rather than config:
  ## this is what was said, not how the reader likes things.
  let xdg = getEnv("XDG_DATA_HOME")
  if xdg.len > 0: xdg / "nirc" else: getHomeDir() / ".local" / "share" / "nirc"

proc historyFile*(): string = dataDir() / "history.sqlite3"

proc enabled*(): bool = not db.isNil

proc exec(sql: string): bool =
  if sqlite3_exec(db, sql.cstring, nil, nil, nil) != sqliteOk:
    trace("history", "failed: " & $sqlite3_errmsg(db))
    return false
  true

proc open*(): bool =
  ## Open the file, making it where it is not there. A file that will not open
  ## is a client with no history rather than one that will not start.
  if not db.isNil: return true
  try: createDir(dataDir())
  except CatchableError as e:
    trace("history", "no data directory: " & e.msg)
    return false
  if sqlite3_open(historyFile().cstring, db) != sqliteOk:
    trace("history", "could not open " & historyFile())
    discard sqlite3_close(db)
    db = nil
    return false
  # WAL with NORMAL sync: a CHATHISTORY reply is a hundred inserts, and a
  # sync apiece is a hundred waits on the disk for a line nobody would miss.
  if not (exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;") and
          exec("""CREATE TABLE IF NOT EXISTS messages(
                    server TEXT NOT NULL, room TEXT NOT NULL,
                    key TEXT NOT NULL, msgid TEXT NOT NULL,
                    at INTEGER NOT NULL, frm TEXT NOT NULL,
                    text TEXT NOT NULL, action INTEGER NOT NULL,
                    account TEXT NOT NULL, reply_to TEXT NOT NULL,
                    PRIMARY KEY(server, room, key));
                  CREATE INDEX IF NOT EXISTS messages_by_time
                    ON messages(server, room, at);""")):
    discard sqlite3_close(db)
    db = nil
    return false
  trace("history", "open: " & historyFile())
  true

proc close*() =
  if db.isNil: return
  discard sqlite3_close(db)
  db = nil

proc prepare(sql: string): Stmt =
  if sqlite3_prepare_v2(db, sql, -1, result, nil) != sqliteOk:
    trace("history", "failed: " & $sqlite3_errmsg(db))
    result = nil

proc bindText(st: Stmt, i: int, s: string) =
  discard sqlite3_bind_text(st, i.cint, s, s.len.cint, sqliteTransient)

func roomKey(room: string): string =
  ## IRC names are case-insensitive: `#Nim` and `#nim` are one room.
  room.toLowerAscii

func rowKey*(m: Message): string =
  ## What a stored line is known by. Its msgid where it has one; otherwise
  ## what it is, which is all an untagged line has.
  if m.id.len > 0: m.id
  else: "~" & $m.at & "\x1f" & m.frm & "\x1f" & m.text

proc save*(server, room: string, m: Message) =
  ## Keep a line. One already kept is left as it was.
  if db.isNil or server.len == 0: return
  let st = prepare("""INSERT OR IGNORE INTO messages
    (server, room, key, msgid, at, frm, text, action, account, reply_to)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""")
  if st.isNil: return
  st.bindText(1, server)
  st.bindText(2, roomKey(room))
  st.bindText(3, m.rowKey)
  st.bindText(4, m.id)
  discard sqlite3_bind_int64(st, 5, m.at)
  st.bindText(6, m.frm)
  st.bindText(7, m.text)
  discard sqlite3_bind_int64(st, 8, (if m.action: 1 else: 0))
  st.bindText(9, m.account)
  st.bindText(10, m.replyTo)
  if sqlite3_step(st) != sqliteDone:
    trace("history", "could not save: " & $sqlite3_errmsg(db))
  discard sqlite3_finalize(st)

proc drop*(server, room, msgid: string) =
  ## A redacted line is gone from the disk too.
  if db.isNil or server.len == 0 or msgid.len == 0: return
  let st = prepare(
    "DELETE FROM messages WHERE server = ? AND room = ? AND msgid = ?")
  if st.isNil: return
  st.bindText(1, server)
  st.bindText(2, roomKey(room))
  st.bindText(3, msgid)
  discard sqlite3_step(st)
  discard sqlite3_finalize(st)

proc load*(server, room: string, limit = keep): seq[Message] =
  ## The newest `limit` lines of a room, oldest first.
  if db.isNil or server.len == 0: return
  let st = prepare("""SELECT msgid, at, frm, text, action, account, reply_to
    FROM (SELECT rowid AS n, * FROM messages WHERE server = ? AND room = ?
          ORDER BY at DESC, n DESC LIMIT ?)
    ORDER BY at, n""")
  if st.isNil: return
  st.bindText(1, server)
  st.bindText(2, roomKey(room))
  discard sqlite3_bind_int64(st, 3, limit.int64)
  while sqlite3_step(st) == sqliteRow:
    var m = Message(id: $sqlite3_column_text(st, 0),
                    at: sqlite3_column_int64(st, 1),
                    frm: $sqlite3_column_text(st, 2),
                    text: $sqlite3_column_text(st, 3),
                    action: sqlite3_column_int64(st, 4) != 0,
                    account: $sqlite3_column_text(st, 5),
                    replyTo: $sqlite3_column_text(st, 6))
    if m.id.len == 0: m.localId = "kept-" & $result.len
    result.add m
  discard sqlite3_finalize(st)
