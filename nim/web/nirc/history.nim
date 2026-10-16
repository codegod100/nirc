## What was said, kept between visits — in a browser, nothing yet.
##
## The desktop keeps a SQLite file (`nim/src/nirc/history.nim`); the page has
## no SQLite, and the server's CHATHISTORY is its backlog. The same calls, so
## the shared reducer imports one name either way.

import nirc/model

const keep* = 500

proc enabled*(): bool = false
proc open*(): bool = false
proc close*() = discard
proc save*(server, room: string, m: Message) = discard
proc drop*(server, room, msgid: string) = discard
proc load*(server, room: string, limit = keep): seq[Message] = discard
