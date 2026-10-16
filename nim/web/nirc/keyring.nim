## The browser has no keyring a page can trust: `localStorage` is readable by
## every script the origin runs. So nothing is remembered, and the connect
## form says passwords are never saved.

proc useMemory*() = discard
proc available*(): bool = false
proc remember*(kind, host, user, password: string): bool = false
proc recall*(kind, host, user: string): string = ""
proc forget*(kind, host, user: string) = discard
