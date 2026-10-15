// The web core, driven the way a browser drives it.
//
// Not a unit test — the Nim suite is that, and it covers the same reducer
// this runs. What is checked here is the seam: that the JavaScript build
// loads, that a tree comes out as JSON, that an event goes in, and that a
// line fed in as if from a socket reaches the screen. Those are the four
// things that can break without a single Nim test noticing, because the
// desktop build does them through a different file.
//
//   node nim/web/test/smoke.js build/web/nirc_core.js

const fs = require('fs');
const path = process.argv[2] || 'build/web/nirc_core.js';

// The bits of a browser this build touches. The core asks localStorage for a
// saved session and asks `location` where to send a reader for sign-in.
globalThis.window = {
  localStorage: {
    _v: {},
    getItem(k) { return this._v[k] || ""; },
    setItem(k, v) { this._v[k] = String(v); return true; },
    removeItem(k) { delete this._v[k]; },
  },
  location: { href: "", origin: "http://localhost", pathname: "/" },
};

// Global scope, not a module's: the core puts `nirc` on globalThis, and a
// `require` would wrap it where nothing could see it.
(0, eval)(fs.readFileSync(path, 'utf8'));

let failures = 0;
function check(what, ok) {
  console.log((ok ? "  ok   " : "  FAIL ") + what);
  if (!ok) failures++;
}

nirc.init("");
check("the connect screen renders", JSON.parse(nirc.render()).tag === "page");

nirc.demo();
check("the demo room renders", nirc.render().includes("hello there"));

const chats = nirc.dispatch(JSON.stringify({ id: "screen.chats" }));
check("an event answers with the tree it produced", chats.includes("#test"));

// Connecting: the core asks to be dialled rather than dialling.
nirc.dispatch(JSON.stringify({ id: "screen.connect" }));
nirc.dispatch(JSON.stringify({ id: "host.change", value: "wss://irc.example.org/webirc" }));
nirc.dispatch(JSON.stringify({ id: "nick.change", value: "webtester" }));
nirc.dispatch(JSON.stringify({ id: "channels.change", value: "#test" }));
nirc.dispatch(JSON.stringify({ id: "connect" }));
const wanted = JSON.parse(nirc.wanted() || "{}");
check("it asks the host for a socket", wanted.host === "wss://irc.example.org/webirc");

// The host says the socket opened; the core answers with registration.
nirc.socketEvent("open");
nirc.render();
const out = nirc.takeOutbound().split("\n");
check("registration goes out on open",
      out[0] === "CAP LS 302" && out[1] === "NICK webtester");
check("and is taken once", nirc.takeOutbound() === "");

// A line arrives.
nirc.feed(":irc.example.org 005 webtester CHANTYPES=# NETWORK=Example :are supported");
nirc.feed(":irc.example.org 001 webtester :Welcome");
nirc.render();
check("the form's channels are joined", nirc.takeOutbound().split("\n").includes("JOIN #test"));
nirc.feed(":alice!a@h PRIVMSG #test :hello from the web");
const tree = nirc.render();
check("a fed line reaches the screen", tree.includes("hello from the web"));

// A PING is answered by `pump` alone -- no render. The host calls it from
// the socket's `onmessage`, because the timer that renders is throttled in a
// hidden tab and a late PONG is a dropped connection.
nirc.takeOutbound();
nirc.feed("PING :irc.example.org");
nirc.pump();
check("a PING is answered without a render",
      nirc.takeOutbound() === "PONG :irc.example.org");

// What is saved is saved, and no password among it.
check("the store writes through localStorage",
      Object.keys(window.localStorage._v).some(k => k.startsWith("nirc.")));

// SASL PLAIN, over the same seam.
nirc.dispatch(JSON.stringify({ id: "disconnect" }));
nirc.takeOutbound();
nirc.dispatch(JSON.stringify({ id: "account.change", value: "alice" }));
nirc.dispatch(JSON.stringify({ id: "sasl-password.change", value: "hunter2" }));
nirc.dispatch(JSON.stringify({ id: "connect" }));
nirc.socketEvent("open");
nirc.render();
nirc.takeOutbound();                       // CAP LS, NICK, USER
nirc.feed("CAP * LS :sasl message-tags server-time");
nirc.render();
check("sasl is requested with an account",
      nirc.takeOutbound().includes("sasl"));
nirc.feed("CAP * ACK :sasl message-tags server-time");
nirc.render();
check("an acked sasl starts PLAIN",
      nirc.takeOutbound().trim() === "AUTHENTICATE PLAIN");
nirc.feed("AUTHENTICATE +");
nirc.render();
const answer = nirc.takeOutbound().trim().replace("AUTHENTICATE ", "");
check("the payload is account, account, password",
      Buffer.from(answer, "base64").toString() === "alice\0alice\0hunter2");
check("no password is in storage",
      !JSON.stringify(window.localStorage._v).includes("hunter2"));

console.log(failures ? failures + " failed" : "all ok");
process.exit(failures ? 1 : 0);
