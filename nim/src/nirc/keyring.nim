## Passwords, kept in the system keyring rather than on disk.
##
## The Secret Service over libsecret, on a desktop that has one: GNOME
## Keyring, KWallet, KeePassXC. libsecret is opened at run time rather than
## linked, so a machine without it runs the client the same as before and
## only loses the remembering; `available` says which it is, and the connect
## form asks to remember only where it is true.
##
## Each password is one item under the `chat.nirc.Password` schema, found by
## what it unlocks: `kind` (`sasl` or `server`), the `host`, and the `user`
## (the account for SASL, the port for a server password). Nothing here is
## written to `$XDG_CONFIG_HOME`.

import std/[dynlib, tables]
import nirc/trace

type
  SchemaAttribute {.pure.} = object
    name: cstring
    kind: cint                     ## SECRET_SCHEMA_ATTRIBUTE_STRING is 0

  SecretSchema {.pure.} = object
    name: cstring
    flags: cint                    ## SECRET_SCHEMA_NONE
    attributes: array[32, SchemaAttribute]
    reserved: cint
    reserved1, reserved2, reserved3, reserved4, reserved5, reserved6,
      reserved7: pointer

  GError {.pure.} = object
    domain: uint32
    code: cint
    message: cstring

  StoreFn = proc (schema: ptr SecretSchema, collection, label,
                  password: cstring, cancellable: pointer,
                  error: ptr ptr GError): cint {.cdecl, varargs, gcsafe.}
  LookupFn = proc (schema: ptr SecretSchema, cancellable: pointer,
                   error: ptr ptr GError): cstring {.cdecl, varargs, gcsafe.}
  ClearFn = proc (schema: ptr SecretSchema, cancellable: pointer,
                  error: ptr ptr GError): cint {.cdecl, varargs, gcsafe.}
  FreeFn = proc (p: pointer) {.cdecl, gcsafe.}

var
  loaded = false
  lib: LibHandle
  storeFn: StoreFn
  lookupFn: LookupFn
  clearFn: ClearFn
  passwordFree, errorFree: FreeFn
  schema: SecretSchema
  memory: Table[string, string]
  inMemory = false
    ## The tests' keyring: a table, so a suite neither needs a Secret Service
    ## nor touches the one belonging to whoever runs it.

proc useMemory*() =
  ## A keyring that lives as long as the process. For the tests.
  inMemory = true
  memory.clear()

proc load(): bool =
  if loaded: return not lib.isNil
  loaded = true
  for name in ["libsecret-1.so.0", "libsecret-1.so", "libsecret-1.0.dylib",
               "libsecret-1.dylib"]:
    lib = loadLib(name)
    if not lib.isNil: break
  if lib.isNil:
    trace("keyring", "no libsecret here; passwords are not remembered")
    return false
  storeFn = cast[StoreFn](lib.symAddr("secret_password_store_sync"))
  lookupFn = cast[LookupFn](lib.symAddr("secret_password_lookup_sync"))
  clearFn = cast[ClearFn](lib.symAddr("secret_password_clear_sync"))
  passwordFree = cast[FreeFn](lib.symAddr("secret_password_free"))
  # GLib is libsecret's own dependency, so it is already in the process.
  errorFree = cast[FreeFn](lib.symAddr("g_error_free"))
  if errorFree.isNil:
    let glib = loadLib("libglib-2.0.so.0")
    if not glib.isNil: errorFree = cast[FreeFn](glib.symAddr("g_error_free"))
  if storeFn.isNil or lookupFn.isNil or clearFn.isNil or passwordFree.isNil:
    trace("keyring", "libsecret is missing its password calls")
    unloadLib(lib)
    lib = nil
    return false
  schema.name = "chat.nirc.Password"
  schema.attributes[0] = SchemaAttribute(name: "kind")
  schema.attributes[1] = SchemaAttribute(name: "host")
  schema.attributes[2] = SchemaAttribute(name: "user")
  true

proc available*(): bool =
  ## Whether a password handed to `remember` can come back next run.
  inMemory or load()

proc failed(what: string, err: ptr GError) =
  if err.isNil: return
  trace("keyring", "could not " & what & ": " & $err.message)
  if not errorFree.isNil: errorFree(err)

proc key(kind, host, user: string): string = kind & "\0" & host & "\0" & user

proc remember*(kind, host, user, password: string): bool =
  ## Keep `password` for this `kind`, `host` and `user`, replacing any before.
  if inMemory:
    memory[key(kind, host, user)] = password
    return true
  if not load(): return false
  var err: ptr GError
  let label = "nirc: " & (if kind == "sasl": user & " on " & host
                          else: "server password for " & host & ":" & user)
  result = storeFn(addr schema, "default", label.cstring, password.cstring,
                   nil, addr err, "kind".cstring, kind.cstring,
                   "host".cstring, host.cstring, "user".cstring, user.cstring,
                   nil) != 0
  failed("save a password", err)

proc recall*(kind, host, user: string): string =
  ## The password kept for this `kind`, `host` and `user`, or "".
  if inMemory: return memory.getOrDefault(key(kind, host, user))
  if not load(): return ""
  var err: ptr GError
  let p = lookupFn(addr schema, nil, addr err, "kind".cstring, kind.cstring,
                   "host".cstring, host.cstring, "user".cstring, user.cstring,
                   nil)
  failed("read a password", err)
  if p.isNil: return ""
  result = $p
  passwordFree(p)

proc forget*(kind, host, user: string) =
  ## Drop whatever is kept for this `kind`, `host` and `user`.
  if inMemory:
    memory.del(key(kind, host, user))
    return
  if not load(): return
  var err: ptr GError
  discard clearFn(addr schema, nil, addr err, "kind".cstring, kind.cstring,
                  "host".cstring, host.cstring, "user".cstring, user.cstring,
                  nil)
  failed("forget a password", err)
