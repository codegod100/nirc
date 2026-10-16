## The connect screen: a server, a nick, and optionally an account.

import std/json
import nirc/[ui, cells]

const transportNote* =
  when defined(js):
    "In a browser the server is a WebSocket URL (wss://…), which most " &
    "modern ircds (Ergo, UnrealIRCd, InspIRCd) can serve."
  else:
    "TLS on :6697; untick it for a server's plain :6667 listener."

func errorNote*(s: State): Node =
  ## Always a node, never nothing.
  ##
  ## A conditional child that disappears shifts every sibling after it, and a
  ## renderer matching children by position would patch the header into a card
  ## when an error appeared mid-screen. A stable wrapper with a stable key
  ## keeps the shape of the tree fixed and only its contents changing.
  result = vbox(%*{"key": "error-note", "spacing": 6})
  if s.hasError:
    result.children.add card(
      label("⚠ " & s.error),
      button("Dismiss", "error.dismiss"))

func serverFields(s: State): Node =
  ## Every entry carries a key. A renderer that keeps a text controller per
  ## field needs a stable name for it.
  when defined(js):
    vbox(%*{"spacing": 6},
      label("Server"),
      entry("host", s.formHost, "wss://irc.example.org/webirc", "host.change",
            width = 320, verbatim = true))
  else:
    vbox(%*{"spacing": 6},
      label("Server"),
      hbox(%*{"spacing": 8},
        entry("host", s.formHost, "irc.example.org", "host.change",
              width = 220, verbatim = true),
        entry("port", s.formPort, "6697", "port.change", width = 90,
              verbatim = true)),
      checkbutton("TLS", s.formTls, "tls.toggle"))

func identityFields(s: State): Node =
  vbox(%*{"spacing": 6},
    label("Nick"),
    entry("nick", s.formNick, "your nick", "nick.change", width = 320,
          verbatim = true, onSubmit = "connect"),
    label("Channels"),
    entry("channels", s.formChannels, "#one, #two", "channels.change",
          width = 320, verbatim = true, onSubmit = "connect"),
    dimLabel("Joined on connect, beside any rooms you had open."))

func accountFields(s: State): Node =
  vbox(%*{"spacing": 6},
    title2("Account (optional)"),
    dimLabel("Signs in with SASL PLAIN. Leave empty to connect as a guest."),
    label("Account"),
    entry("account", s.formAccount, "account name", "account.change",
          width = 320, verbatim = true),
    label("Password"),
    entry("sasl-password", s.formSaslPassword, "", "sasl-password.change",
          width = 320, verbatim = true, password = true,
          onSubmit = "connect"),
    label("Server password"),
    entry("server-password", s.formServerPassword, "only if the server needs one",
          "server-password.change", width = 320, verbatim = true,
          password = true, onSubmit = "connect"),
    if s.keyring:
      checkbutton("Remember passwords in the system keyring",
                  s.rememberPasswords, "remember-passwords.toggle")
    else: dimLabel("Passwords are never saved."))

func connectAction(s: State): Node =
  if s.connecting:
    # Cancel beside the spinner. A connection that never completes is
    # otherwise a spinner with no way out but killing the window.
    hbox(%*{"spacing": 8},
      spinner(),
      dimLabel(s.status),
      button("Cancel", "cancel"))
  else:
    hbox(%*{"spacing": 8},
      button("Connect", "connect", "primary"),
      dimLabel(s.status))

func connectScreen*(s: State): Node =
  page(%*{"maxWidth": 520},
    title("nirc"),
    dimLabel("An IRC client. Any server, any network."),
    errorNote(s),
    card(
      serverFields(s),
      identityFields(s),
      separator(),
      accountFields(s),
      separator(),
      connectAction(s)),
    dimLabel(transportNote))
