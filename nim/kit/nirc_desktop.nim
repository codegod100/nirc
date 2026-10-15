## nirc on the Linux desktop: the core, painted by nimkit's GTK backend.
##
## One process and one language. The core owns the state, the screens and the
## IRC connection; `nirckit/render` walks the core's tree into GTK widgets;
## and this file is the host — the window and the clock that polls the core.
##
##   just run desktop
##
##   NIRC_AUTOCONNECT=1  press Connect at startup; NIRC_NICK, NIRC_HOST,
##                       NIRC_PORT and NIRC_TLS=0 override the form
##   NIRC_DEMO=1         open on a representative room instead, no server
##   NIRC_THEME=light    or dark; otherwise whatever the desktop's theme is

import std/[json, os, strutils]
import nimkit
import nimkit/backend/gtkapi
import nirc/[eintr, reducer, tree, trace]
import nirc_core
import nirckit/[render, theme]

const insertImagePng = staticRead("../assets/insert-image.png")

# ------------------------------------------------------------------ the core

var shownGen = -1

proc paint() =
  ## The screen, if it moved. `refresh` drains the socket first, so this is
  ## also how lines that arrived get onto the screen.
  discard refresh()
  if treeGen != shownGen:
    shownGen = treeGen
    render(treeNode)

proc dispatchNow(id, value: string) =
  try:
    dispatch(%*{"id": id, "value": value})
  except CatchableError as e:
    trace("dispatch", "!! " & e.msg)
  paint()

# ------------------------------------------------------------------ the look

{.push cdecl, importc.}
proc gtk_settings_get_default(): pointer
proc g_object_get(o: pointer, first: cstring): void {.varargs.}
{.pop.}

proc prefersDark(): bool =
  ## Whether the desktop is dark: the theme's name says so on KDE and most
  ## others (Breeze-Dark, Adwaita-dark), the preference flag on GNOME.
  let forced = getEnv("NIRC_THEME").toLowerAscii
  if forced == "dark": return true
  if forced == "light": return false
  var name: cstring
  var dark: cint
  let s = gtk_settings_get_default()
  if s == nil: return true
  g_object_get(s, "gtk-theme-name", addr name, "gtk-application-prefer-dark-theme", addr dark, nil)
  let theme = if name == nil: "" else: $name
  dark != 0 or "dark" in theme.toLowerAscii or getEnv("GTK_THEME").toLowerAscii.contains("dark")

proc applyTheme() =
  let css = gtkCss(if prefersDark(): nircDark else: nircLight)
  let p = gtk_css_provider_new()
  discard gtk_css_provider_load_from_data(p, css.cstring, css.len, nil)
  # Above the application priority nimkit's own sheet takes, so nirc's
  # colours win where both speak.
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), p,
                                            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1)

# ------------------------------------------------------------------- start

proc main() =
  appName = "nirc"
  # Before anything opens a socket; see `nirc_init`.
  restartableSyscalls()
  reducer.restore()
  wantJson = false
  insertImage = insertImagePng
  sendHook = dispatchNow
  inputHook = proc (id, value: string) = input($(%*{"id": id, "value": value}))
  onWindowSize = proc (w, h: int) =
    windowWidth = w
    dispatchNow("window.size", $w & "x" & $h)
  applyTheme()

  let content = newRoot()
  # After the root exists: every dispatch paints, and a paint before there
  # is a window to paint into is a nil dereference.
  if getEnv("NIRC_DEMO") notin ["", "0"]:
    nirc_ui_demo()
  else:
    let want = getEnv("NIRC_AUTOCONNECT")
    if want notin ["", "0"]:
      # TLS first: the tick moves the port, and NIRC_PORT should win.
      if getEnv("NIRC_TLS") == "0": dispatchNow("tls.toggle", "")
      for (env, event) in [("NIRC_NICK", "nick.change"),
                           ("NIRC_HOST", "host.change"),
                           ("NIRC_PORT", "port.change"),
                           ("NIRC_CHANNELS", "channels.change")]:
        let v = getEnv(env)
        if v.len > 0: dispatchNow(event, v)
      dispatchNow("connect", "")
  paint()
  # Polling, because the socket lives on its own threads and nothing calls
  # into this one when a line arrives.
  discard every(100, proc () = paint())
  run("nirc", content, 1100, 760)

main()
