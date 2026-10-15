// The half of the web build that owns the I/O.
//
// `nirc_core.js` is the same Nim the desktop runs, compiled by `nim js`. It
// holds the state and builds the screens, and it opens nothing: a browser
// cannot dial a TCP socket, and `nirc/conn` on this target is a pair of queues
// rather than two threads. This file is what fills them.
//
// One job: the socket. The core says where it wants to be connected; this
// opens a WebSocket there (IRCv3's WebSocket transport — one IRC line per
// text frame), feeds every line in, and sends everything the core has queued.
//
// nimkit draws, from inside `nirc.js`, and never touches any of this.

(function () {
  "use strict";

  var ws = null;
  var wantedNow = "";

  // The server field holds a WebSocket URL. A bare host is taken as
  // wss://host:port/ (or ws:// with TLS off), which is where most ircds put
  // their WebSocket listener.
  function urlFor(cfg) {
    if (cfg.host.indexOf("://") >= 0) return cfg.host;
    return (cfg.tls ? "wss://" : "ws://") + cfg.host + ":" + cfg.port + "/";
  }

  function connect(cfg) {
    var url = urlFor(cfg);
    var sock;
    try {
      // `text.ircv3.net`: UTF-8 text frames. A server that does not pick a
      // subprotocol is fine too; the browser only refuses one it did not ask
      // for.
      sock = new WebSocket(url, ["text.ircv3.net"]);
    } catch (e) {
      nirc.socketEvent("error: " + e);
      return;
    }
    ws = sock;
    var opened = false;
    sock.onopen = function () {
      if (ws !== sock) return;
      opened = true;
      nirc.socketEvent("open");
    };
    sock.onmessage = function (ev) {
      if (ws !== sock) return;
      // A frame can carry more than one line, and carries the CRLF the wire
      // format puts between them. The core wants lines.
      String(ev.data).split(/\r?\n/).forEach(function (line) {
        if (line.length > 0) nirc.feed(line);
      });
      // And answered now, rather than on the next tick of a timer. A hidden
      // tab's timers are throttled to once a minute, so a PING left for the
      // pump below was PONGed minutes late and the server hung up; a message
      // event is delivered on time whether or not the tab is showing.
      nirc.pump();
      flush();
    };
    // One event per socket, from `onclose`. `onerror` carries nothing worth
    // reporting — the browser withholds the reason on purpose — and `onclose`
    // always follows it; saying both told the core the connection ended
    // twice, and the second arrived after the core had already dialled again.
    //
    // And only for the socket that is current: one closed because the core
    // asked for another still fires `onclose`, late, and was taken for the
    // new one ending.
    sock.onclose = function (ev) {
      if (ws !== sock) return;
      ws = null;
      wantedNow = "";
      nirc.socketEvent(opened
        ? "close: " + (ev.reason || "the connection ended")
        : "error: the connection failed");
    };
  }

  function hangUp() {
    if (!ws) return;
    var old = ws;
    ws = null;
    try { old.close(); } catch (e) {}
  }

  // Everything the core has queued, onto the socket if there is one.
  function flush() {
    if (!ws || ws.readyState !== 1) return;
    var out = nirc.takeOutbound();
    if (out) {
      out.split("\n").forEach(function (line) {
        if (line.length > 0) ws.send(line);
      });
    }
  }

  // The pump. Both directions, on a timer, because nothing calls in here when
  // the core has something to say.
  //
  // Twenty times a second: fast enough that a keystroke's PRIVMSG does not
  // sit in a queue where a reader would notice, and slow enough to be free.
  setInterval(function () {
    // `wanted` is cleared when a connection ends, so the core decides whether
    // to dial again rather than this redialling on its own.
    var want = nirc.wanted();
    if (!want && wantedNow) {
      wantedNow = "";
      hangUp();
    } else if (want && want !== wantedNow) {
      wantedNow = want;
      hangUp();
      connect(JSON.parse(want));
    }
    flush();
  }, 50);

  nirc.init("");
})();
