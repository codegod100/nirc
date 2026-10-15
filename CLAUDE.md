# Working in this repo

nirc is a generic IRC client written in Nim, from the socket to the pixels: a
GTK 3 desktop app and a web app built from one core. It started as a copy of
[frq](https://github.com/codegod100/frq), a client for the freeq server, with
the freeq-specific parts (Bluesky sign-in, message signing, task cards, the
media and preview endpoints) taken out and standard IRC put in their place.

## The toolchain

There is no nix in the build. `tools/toolchain.sh` fetches Nim as a
sha256-pinned tarball into `.toolchain/`, and every `just` recipe runs inside
the environment that script prints. The host brings a C compiler, OpenSSL,
curl, tar and python3 — GTK 3 and pkg-config for the desktop, and node for
`just test web`.

```bash
just test nim        # the core, in seconds: no GTK, no browser
just test web        # the JavaScript build of the same core, under node
just test desktop    # the GTK app compiled
```

## Never pipe a long task through `tail`

`tail` and `head` emit nothing until their input ends, so a build piped
through one shows nothing until it is over, and loses everything if it is
killed first. `tee` to a file and trim the file afterwards.

## The protocol reference

The [IRCv3 specifications](https://ircv3.net/irc/) are the reference for
everything past RFC 1459/2812: CAP, SASL, `message-tags`, `server-time`,
`echo-message`, `batch`, `draft/multiline`, `draft/chathistory`,
`draft/message-redaction`, and the `+draft/reply` / `+draft/react` client
tags. [Ergo](https://ergo.chat) implements nearly all of it and is the easiest
server to test against locally; its WebSocket listener is what the web build
talks to.

Anything a server may or may not support is gated on the capability it
ACKed (`app.caps` for the screens, `hasCap` in the reducer). A control that
always fails on a server without the capability is not shown there.

## The Nim core

`nim/` is the program. It owns the state, the screens and the IRC connection,
and nimkit paints the widget tree it emits, on GTK and in a page. Read
`nim/README.md` before touching it.

What differs between the desktop and the web is only the host:
`nim/web/nirc/*.nim` shadows `nim/src/nirc/*.nim` by search path
(`--path:../src --path:.`, resolved from `nim/web`; later wins), so
`nirc/conn` is a queue a WebSocket fills rather than two socket threads, and
`nirc/store` is localStorage rather than files. The shared code imports the
same names either way. The two entry points are `nim/kit/nirc_desktop.nim`
and `nim/web/nirc_app.nim`; the page's own JavaScript, `web/nirc_host.js`,
owns the WebSocket.

`nim/src/nirc/ui.nim` builds a widget tree; `nim/kit/nirckit/render.nim`
walks it into nimkit widgets, reconciling by key. The renderer knows the tag
vocabulary and nothing else. If a feature needs a change on both sides, the
boundary is in the wrong place.

The C ABI in `nim/src/nirc_core.nim` still builds (`just build lib`) though
nothing loads it. Every string it returns is the caller's to free with
`nirc_free`.

## The source trees

```
nim/src            the program: state, screens, IRC
nim/web            the same program's host half for a browser, and its app
nim/kit            the renderer and the palette over nimkit, and the GTK host
nim/vendor/nimkit  the widget toolkit: GTK 3 and the DOM, behind one API
web                the page, and the JavaScript that owns the socket
```

Colours come from `nim/kit/nirckit/theme.nim`, never from the renderer. The
desktop takes `NIRC_THEME=dark|light`; the page follows
`prefers-color-scheme`.

## Things the client deliberately does not do

* Save a password. The server, nick, account name and channels are saved;
  the SASL and server passwords are typed each time.
* Edit messages (no ratified IRCv3 spec), upload files, or fetch avatars and
  link previews (those need a service beside the IRC server).
