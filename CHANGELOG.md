# Changelog

## 0.1.0 (unreleased)

First release.

- Bar icon with the unread count, refreshed in the background every 5 minutes;
  dims when not connected. Middle-click refreshes.
- Dropdown built on the shell's own `qs.Ui` kit and `qs.Commons` theme: All
  unread, Starred and every category with unread counts; article list with
  thumbnails (image enclosure or first image) and feed favicons as a fallback;
  article view with the lead image and a plain-text summary.
- Read / unread, star / unstar and open in browser, synced with the server
  through FreshRSS's Google Reader-compatible API. Mark all read asks for a
  second click. Unread / All toggle and load more.
- Pop out into a resizable window, and back.
- Keyboard-driven with FreshRSS's default shortcuts (`j`/`k`, `h`, `n`/`p`,
  Home/End, Enter, Space, `r`, `f`, `m`, `u`, `q`), plus `R` to refresh, `z` for
  the window and `,` for settings. Keyboard reference in settings; buttons show
  their keys in tooltips. The refresh icon spins while loading.
- Setup inside the dropdown with the FreshRSS API password; the login token is
  kept in the system keyring. The server check explains wrong addresses and a
  disabled API instead of failing with a bare HTTP error.
- Favicon links are rebuilt on the address you connected with, so servers whose
  `base_url` is missing the port still show icons.
- IPC: `toggle`, `open`, `close`, `refresh`, `openUnread`, `openSettings`,
  `popOut`.
- DankMaterialShell version in `dms/` with the same features and keys.
