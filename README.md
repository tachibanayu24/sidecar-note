# Sidecar Note

An always-on-top Markdown note that slides in from the edge of the screen — Liquid Glass, keyboard-first. macOS 26+.

## Summon

| | |
|---|---|
| `⌃⇧Space` (configurable) / four-finger swipe down | Show · focus (if visible but unfocused) · hide |
| `⌘H` | Hide |
| `⌘Q` twice | Quit (a single press only shows a hint) |

The note never appears over full-screen apps. While it has keyboard focus a soft halo glows around it, in a different sky each time it appears; that halo is the only visual difference between focused and unfocused.

## Notes & tabs

| | |
|---|---|
| `⌘T` / `⌘W` | New note / close note (its file goes to the Trash) |
| `⌘Z` right after closing | Reopen the closed note (until you type anything; then `⌘Z` undoes text again) |
| `⌘1`…`⌘8`, `⌘9` | Go to a note, `⌘9` = last |
| `⌃Tab` / `⌃⇧Tab`, `⌘⇧]` / `⌘⇧[` | Next / previous note |
| Drag a tab | Reorder |

Tabs appear once there are two notes; with one note it's just the glass. Blank notes don't linger — they go away when you switch to another note or hide the panel.

## Editing

Markdown renders live while you type (headings, emphasis, lists, tasks, quotes, tables, rules, links, images, fenced code with syntax highlighting); the Markdown itself stays plain text. Syntax characters (`**`, `#`, backticks, link URLs, fences) only show on the line you're editing.

| | |
|---|---|
| `Return` in a list / task / quote | Continues it; on an empty item, outdents or ends the list |
| `Tab` / `⇧Tab` on list lines | Indent / outdent |
| `⌘↩` | Toggle the checkbox (turns plain lines, bullets and quotes into tasks) |
| Click a checkbox | Toggle it |
| `⌘B` `⌘I` `⌘⇧X` `⌘E` | Bold · italic · strikethrough · inline code |
| `⌘`-click a link | Open it |
| Paste / drop an image | Saved to `assets/`, shown inline |
| `⌘F`, `⌘G`, `⌘⇧G` | Find in note |
| `⌘+` `⌘-` `⌘0` | Text size |

## Settings (`⌘,`)

Shortcut, four-finger swipe, theme, focus glow, opacity (Apple's clear glass → regular glass → tinted), font, text size, notes folder, launch at login, menu bar icon.

## Files

Notes are plain `.md` files in `~/Library/Application Support/com.tachibanayu24.SidecarNote/Notes/` (changeable in Settings; existing notes move along). They are saved as you type and written back in the encoding they were read with. If another app changed a file while it had unsaved edits here, that version is kept next to it as `name (conflict yyyyMMdd-HHmmss).md`.

## Build

```sh
./scripts/build-app.sh            # build/Sidecar Note.app
./scripts/build-app.sh --install  # install to /Applications and launch
./scripts/build-app.sh --dev      # "Sidecar Note Dev.app": separate bundle id, settings and notes, for testing
                                  # (never takes the keyboard; posts to /tmp/sidecar-dev.log, e.g. its self-test:
                                  #  distributed notification "SidecarNoteDev.selftest")
swift scripts/make-icon.swift     # regenerate the icon
```

`Vendor/` holds two dependencies patched so the app needs no SwiftPM resource bundles (those can't be placed where SwiftPM's generated code looks for them inside a signed app): Highlightr loads its assets from `Contents/Resources/Highlightr.bundle`, and KeyboardShortcuts has its English strings compiled in.

The four-finger swipe and the focus-independent glass look rely on private macOS APIs, so the app can't be distributed through the App Store.
