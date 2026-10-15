# nirc

A generic **IRC client** written in **Nim**, from the socket to the pixels.
Nim owns the state, the screens and the IRC connection, and nimkit — a small
retained-mode toolkit, vendored — paints the widget tree they emit: as GTK 3
widgets on the desktop, and as DOM in a browser.

nirc began as a copy of [frq](https://github.com/codegod100/frq), a client
for the freeq server. The structure and stack are frq's; the freeq-specific
parts (Bluesky/AT Protocol sign-in, message signing, task cards, freeq's
media and link-preview endpoints) are gone, and it connects to any standard
IRC server.

```
nim/src            the program: state, screens, IRC
nim/web            the same program's host half for a browser, and its app
nim/kit            the renderer and the palette over nimkit, and the GTK host
nim/vendor/nimkit  the widget toolkit: GTK 3 and the DOM, behind one API
web/               the page, and the JavaScript that owns the WebSocket
```

## Running

Everything comes from [pixi](https://pixi.sh): Nim, a C compiler, OpenSSL,
GTK 3, pkg-config, Node.js and Python, all from conda-forge and pinned in
`pixi.lock`. The host brings pixi and nothing else (on Linux it also needs an
X11 or Wayland display to show the window).

```bash
curl -fsSL https://pixi.sh/install.sh | sh   # once

pixi run desktop        # build build/nirc and open the window
pixi run web            # build build/web and serve it on :8000
pixi run test           # nim, web and desktop
pixi run test nim       # the core alone, in seconds
pixi run test nim tcommands   # one test file
pixi run build lib      # the core as build/nim/libnirccore.so
```

Linux (x86-64, arm64) and Intel macOS. conda-forge has no Nim for Apple
silicon yet.

A few switches for the desktop:

```bash
NIRC_TRACE=1 pixi run desktop        # verbose: every IRC line in and out
NIRC_DEMO=1 pixi run desktop         # open on a representative room, no server
NIRC_THEME=light pixi run desktop    # or dark; otherwise the desktop's own

# press Connect at startup, with the form filled from the environment
NIRC_AUTOCONNECT=1 NIRC_HOST=irc.libera.chat NIRC_NICK=me \
  NIRC_CHANNELS="#nim" pixi run desktop
# NIRC_PORT=6667 NIRC_TLS=0 for a plain listener
```

### Verbose logging

`NIRC_TRACE=1` logs every IRC line sent and received to stderr, with a
timestamp, plus connection, sign-in and storage events. Passwords are
starred out (`PASS`, SASL payloads, `OPER`, NickServ `IDENTIFY`), so a trace
is safe to paste into a bug report.

```
[nirc 23:39:03.007] out       CAP LS 302
[nirc 23:39:03.215] in        :ergo.test 001 tracey :Welcome to the ErgoTest IRC Network tracey
```

In the web build, open the page with `?trace` (remembered until `?trace=0`)
or run `nirc.trace(true)` in the browser console; the lines go to the console.

## Connecting

The connect screen asks for:

* **Server** — host and port, with TLS on by default (`6697`; untick for a
  plain `6667` listener). Certificates are verified.
* **Nick**, and **Channels** to join on connect (comma or space separated).
  Rooms you had open last time are rejoined as well.
* **Account (optional)** — an account name and password for **SASL PLAIN**,
  which is how NickServ-style accounts sign in on Libera, OFTC, Ergo and most
  other networks.
* **Server password** — sent as `PASS`, for a bouncer (ZNC, soju) or a
  private server.

The server, port, TLS setting, nick, account name and channels are saved
(`$XDG_CONFIG_HOME/nirc/server.json`; `localStorage` on the web). Passwords
never are.

**On the web**, a browser cannot open a raw TCP socket, so the server field
takes a **WebSocket URL** (`wss://…`) — IRCv3's WebSocket transport, which
Ergo, UnrealIRCd and InspIRCd can all serve. The default is Ergo's public
testnet, `wss://testnet.ergo.chat/webirc`. A bare host is tried as
`wss://host:port/`.

## What it covers

* TLS or plain TCP on the desktop, WebSocket in the browser
* `CAP LS 302` negotiation, including `CAP NEW`/`DEL`; SASL PLAIN; `PASS`
* A nick in use at registration is retried as `nick_`, `nick__`, …; the nick
  the server settles on (from `001`, or a later `NICK`) is the one used
* `ISUPPORT`: `CHANTYPES` decides what a channel is, `NETWORK` names it
* Channels and DMs with unread counts and mention markers, a read marker
  kept across runs, and the rooms you had open restored at launch
* A **`*status`** buffer for the MOTD, numerics, server notices and services
  (NickServ, ChanServ); a line typed there is sent raw
* `server-time`, `echo-message`, `message-tags`, `batch`,
  `draft/multiline` (a multi-line message is one message)
* `draft/chathistory`: a room's backlog is asked for on join where the server
  keeps history and did not replay any
* Replies (`+draft/reply`) with a quote chip that jumps to the original
* Emoji reactions (`+draft/react` / `+draft/unreact`) — shown only where the
  server carries client tags
* Unsending your own line with `REDACT`, where the server offers
  `draft/message-redaction`
* `/me`, CTCP `VERSION` and `PING` answered
* Join/part/quit/kick/nick changes, `NAMES` (with `multi-prefix` and
  `userhost-in-names`), `MODE` prefixes, topics
* A profile panel filled by `WHOIS`; a Discover tab filled by `LIST`
* Inline previews for image links; Tab completion of nicks, channels and
  commands
* Commands: `/join /part /msg /query /me /nick /topic /whois /list /quit
  /markread /quote /help`, and any other `/verb args` sent as `VERB args`

## Limits

* **No passwords are remembered**, so an account sign-in is typed each run.
* **No SASL EXTERNAL / client certificates.**
* **One server at a time.**
* **No edits** (there is no ratified IRCv3 edit), **no uploads**, **no
  avatars or link previews** — each of those needs a service beside the IRC
  server, which is what frq got from freeq.
* **No DCC.**
* **mIRC colours and bold are stripped**, not rendered.
