## Every piece of state the screens read.
##
## One record: the whole tree is rebuilt from the whole state on every
## event, so there is nothing to gain from splitting it into cells.

import std/tables
import nirc/[model, complete]

type
  Screen* = enum
    scConnect = "connect", scChats = "chats", scChat = "chat",
    scDms = "dms", scDiscover = "discover", scSettings = "settings"


  ReplyTarget* = object
    ## The message the draft is answering. Held whole rather than as an id
    ## alone so the compose bar can say who is being answered without going
    ## looking for them.
    has*: bool
    id*, frm*, text*: string

  Lightbox* = object
    has*: bool
    path*, url*: string

  ReactTarget* = object
    ## What the emoji picker is choosing for. The picker is a panel over the
    ## compose bar rather than a screen: what is being reacted to has to stay
    ## in sight.
    has*: bool
    room*, id*: string

  ProfileView* = object
    ## Who is being looked at.
    has*: bool
    nick*: string

  Whois* = object
    ## What WHOIS said about someone, as it arrives.
    user*, host*, realname*, server*, account*, channels*, away*: string
    idle*: string

  ListEntry* = object
    name*: string
    users*: int
    topic*: string

  State* = object
    screen*: Screen
    status*: string
    error*: string
    hasError*: bool
    connecting*: bool

    # The connect form.
    formHost*, formPort*, formNick*: string
    formTls*: bool
    formServerPassword*: string
      ## `PASS`, for a bouncer or a private server. Never written to disk.
    formAccount*, formSaslPassword*: string
      ## SASL PLAIN. The account is remembered; the password is not.
    formChannels*: string
      ## Joined on connect, comma or space separated, beside whatever rooms
      ## an earlier run left open.

    # What the server said about itself.
    network*: string        ## ISUPPORT NETWORK, for the status line
    chanTypes*: string      ## ISUPPORT CHANTYPES; "#&" until told
    caps*: seq[string]      ## what was ACKed, for the screens to gate on
    account*: string        ## who SASL says we are, "" for nobody

    whois*: Table[string, Whois]
      ## What WHOIS answered, per nick, for the profile panel.

    # Rooms.
    rooms*: OrderedTable[string, Room]
    current*: string
    joinInput*: string
    search*: string


    # The compose bar and its three companions.
    draft*: string
    draftRev*: int
      ## Goes up whenever the core rewrites the draft itself — a send that
      ## empties it, a Tab that completes a name, an edit that loads a line —
      ## and never for a keystroke. The renderer takes the text from the tree
      ## only when this moves, which is what lets a keystroke skip the tree:
      ## the box already holds what was typed, and a tree built before it was
      ## typed must not put the old text back.
    tab*: TabState
      ## What the last Tab in the compose box did, so the next one can cycle.
    replyingTo*: ReplyTarget

    # Chat chrome.
    showUsers*: bool
      ## The people panel on a narrow window, where it is asked for.
    hideUsers*: bool
      ## The people panel on a wide one, where it is up unless folded away.
    peopleBucket*: int
      ## Which stretch of the people list the reader has scrolled to, in
      ## `peopleChunk`s. Only the rows around it are built: a channel of
      ## thousands as a widget per member took a second to open.
    hideChatList*: bool
    atPresent*: bool
    hideJoinPart*: bool
      ## Comings and goings, hidden or not. A quiet room reads better with
      ## them — they are how you notice someone arriving — and a busy one
      ## drowns in them, so it is the reader's call.

    # Emoji picker.
    emojiGroup*: string
    emojiSearch*: string
    reacting*: ReactTarget
    reactionHover*: ReactTarget

    # Navigation within a conversation.
    highlight*: string
    jumpTo*: string
      ## The message a "go to" is aiming at. Set for the frame that scrolls to
      ## it and taken off again — a target that stayed set would pin the view
      ## there and take scrolling away from the reader.
    jumpTick*: int

    lightbox*: Lightbox
    savedTo*: string
      ## What the lightbox's Save has to say for itself: where a picture
      ## landed, or "failed". Saving is a file appearing somewhere off screen,
      ## so the one thing the reader needs back is where — a button that only
      ## stops looking pressed has told them nothing.
    savedFailed*: bool

    profileViewing*: ProfileView

    # The server's room list, from LIST.
    listing*: seq[ListEntry]
    listPending*: seq[ListEntry]
    listing322*: bool       ## a LIST is under way

    # The window, polled from the host.
    windowWidth*, windowHeight*: int
      ## The height is for the pictures in the conversation: a preview sized
      ## against the window is a picture on a laptop and a thumbnail on a
      ## phone, where one fixed height is only ever right on one of them.

const
  defaultHost* = when defined(js): "wss://testnet.ergo.chat/webirc"
                 else: "irc.libera.chat"
    ## A browser cannot open a raw socket, so on the web the host is a
    ## WebSocket URL — IRCv3's WebSocket transport, which Ergo, UnrealIRCd and
    ## InspIRCd all serve.
  defaultPort* = "6697"
  statusRoom* = "*status"
    ## Where the server's own words go: the MOTD, numerics, notices addressed
    ## to nobody in particular. A line typed here is sent raw.

  wideWidth* = 900
    ## Where the second pane starts paying for itself. Below this a 320pt list
    ## beside a conversation leaves the messages narrower than the phone
    ## layout they were written for.

  popularChannels*: seq[(string, string)] = @[]
    ## Nothing is suggested: every network has its own rooms, and LIST is the
    ## way to find them.

func initState*(): State =
  State(screen: scConnect,
        status: "Not connected",
        formHost: defaultHost,
        formPort: defaultPort,
        formTls: true,
        formNick: "nirc-guest", chanTypes: "#&",
        formChannels: when defined(js): "#chat" else: "",
        atPresent: true,
        rooms: initOrderedTable[string, Room]())

func wide*(s: State): bool =
  ## Past this the room list and the conversation are both on screen instead
  ## of taking turns.
  s.windowWidth >= wideWidth

func usersOpen*(s: State): bool =
  ## Whether the people panel is up. Two switches because it starts in two
  ## places: beside the conversation on a wide window there is room for it,
  ## so it is there until folded; on a narrow one it takes a strip the
  ## messages need, so it waits to be asked.
  if s.wide: not s.hideUsers else: s.showUsers

func currentRoom*(s: State): Room =
  if s.current.len > 0 and s.rooms.hasKey(s.current): s.rooms[s.current]
  else: initRoom("")

var app* = initState()
  ## The one mutable thing. Named `app` rather than `state` because `state` is
  ## ambiguous against unittest's own inside a test module.
