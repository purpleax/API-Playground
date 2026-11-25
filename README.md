# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

## Status

Phases 1 to 5 are built.

Covered by engine tests:

- Postman import: Collection v2.0/v2.1, environments, globals, backup files holding several of each, and the zip from Postman's "Export Data"
- Importing a collection again updates it in place, and requests keep their history
- Collections stored as one file per request, folder and environment
- `{{variable}}` resolution with Postman's scope order
- Secret values kept in the Keychain, and "This Mac only" values kept outside the workspace
- Basic, Bearer and API-key auth, inherited from folders and collections
- Sending requests with libcurl, with per-phase timings and a wire log
- cURL command import
- Per-request response history and a line-by-line response diff
- Checks on status, headers, JSON values, body text and response time, with no script
- Saving a response value into a variable for later requests
- Pre-request and test scripts, run in JavaScriptCore with a Postman-compatible `pm` object
- Collection, folder and request scripts running in Postman's order
- Masking of secrets in bodies, headers, URLs and the wire log
- Pinned responses, and demo sequences saved with the collection
- A mock server that answers from pinned responses, including a whole collection run against its own mock
- Responses read as they arrive, with stopping part-way, and server-sent event parsing
- Cookies: parsing, matching by domain, path, scheme and expiry, and carrying between requests
- GraphQL schema introspection
- OAuth 2: client credentials, password and authorization code requests, PKCE, token parsing, and a request fetching, reusing and refreshing its token
- WebSockets: connect, send, receive and close, against a local server
- Git: status, commit, history, discard, branches, clone, push and pull, against a local
  remote with two people working from it
- Merging: changes to different fields of one request combine, headers and other lists are
  matched by name, the same field changed two ways waits for a choice, a request deleted
  on one side and edited on the other asks which to keep, and two new requests with one
  name are both kept

Checked by hand in the running app:

- Importing files and a zip, the import report, browsing, editing and sending
- Response body, headers, timing, log, history and diff
- The environment editor, including a "This Mac only" value
- Imported Postman test scripts running unchanged, with results and console output
- Adding a check, and the collection runner with pass and fail per request
- Hide Secrets across the editor, response body, headers and log
- Pinning a response, and showing it in place of a live one
- The mock server answering a collection with no backend running, and its temporary
  environment being removed on quit and after a force-quit
- A demo sequence with notes, and presentation mode with Space, arrow keys and Esc
- A live event stream with events appearing as they arrive, and stopping one part-way
- Cookies set by one request shown in a Cookies tab and sent on the next
- The GraphQL schema browser
- A WebSocket conversation: connect, receive, send and disconnect
- OAuth 2 client credentials through the real Keychain: Get Token, status, and the token sent
- Git Sync against a remote on this Mac: the branch chip, changes with a diff, commit, a
  refused push and pull, a pull that needed choices in the merge view, push, history,
  creating and switching branches, merging a branch, abandoning a merge, and cloning

Not yet checked:

- Git Sync's "Start Tracking This Vault with Git", Discard, saving the remote address and
  identity, and the folder chooser in Clone a Repository
- Push and pull against a real host such as GitHub (tests use a remote on this Mac)
- The zip import against a real Postman "Export Data" file (tested with a hand-made zip)
- cURL import from the clipboard, the file-picker import, and switching to a Local Vault
- Form, multipart, GraphQL and file body editors
- Secret variables with the real Keychain (tests use an in-memory store)
- Editing scripts and "Save from response" rows on screen, and running a single folder
- OAuth 2's browser sign-in (authorization code): its requests are tested, but the sign-in
  window has not been tried against a real provider
- The cookie manager sheet, and a WebSocket over TLS (`wss://`)
- In phase 3: the P key while presenting (its button was checked), removing a pinned
  response, reordering demo steps, and the mock's list of requests received

### Demo features

- **Hide Secrets** (Demo menu, or the eye in the toolbar) masks tokens, keys and passwords
  wherever they are displayed. Requests still send the real values. It is always on while presenting.
- **Pin** a response to keep it with the request. A pinned response can be shown in place of
  a live one, and is what the mock server serves.
- **Mock Server** answers on `127.0.0.1` only. When a collection's URLs start with a shared
  variable such as `{{baseUrl}}`, starting the mock points that variable at it through a
  temporary environment, which is removed when the mock stops.
- **Demo sequences** list requests in order with a note each. **Present** shows one step at a
  time in large type: Space sends, the arrow keys move, P shows the pinned response, Esc exits.

### Protocols

- **Event streams.** A `text/event-stream` response shows its events as they arrive. Stop
  ends it and keeps what was received. The 30-second timeout does not apply to event streams.
- **Cookies.** Cookies a server sets are kept on this Mac, per workspace, and sent back on
  later requests to the same site, unless the request has a Cookie header of its own.
  Request > Cookies lists and removes them. Cookies set on a redirect that is followed are not kept.
- **GraphQL.** With a GraphQL body, Schema asks the server to describe itself and opens a
  browser of its types and fields. There is no query autocomplete yet.
- **OAuth 2.** Choose it in a request's Auth tab. Client credentials and password tokens are
  fetched automatically when a request is sent; authorization code opens a sign-in window
  and returns to `apiplayground://oauth/callback`. Tokens are kept in the Keychain and
  refreshed when they expire.
- **WebSockets.** A request whose address starts with `ws://` or `wss://` gets a
  conversation pane in place of the response, with Connect in place of Send. The message
  being composed is saved with the request. WebSocket traffic has no timing or wire log.

### Git Sync

A Local Vault folder that is a Git repository gets a branch chip in the top bar and a Git
menu. Git > Clone a Repository copies a shared workspace onto this Mac; Git > Start Tracking
turns the open vault into a repository.

- **Changes** lists what is uncommitted by its name in the app ("Request: List pets"), with
  a diff against the last commit, Discard, and a commit box.
- **Pull** merges by value, not by line of text. Two people changing different fields of
  one request, or adding different headers, never collide. Only a value both changed in
  different ways is a conflict, and the merge view then shows mine and theirs side by side
  for each one, with the value before. Abandon Merge puts everything back.
- **Branches** can be created, switched and merged into the current one. Branches that
  exist only on the remote are listed too.
- Secret values, current values, cookies, history and OAuth tokens are never committed:
  they live in the Keychain or the app's private data, outside the workspace.

Git Sync runs the `git` command already on this Mac (Apple's Command Line Tools or
Homebrew), so it signs in to a remote the same way Git does in Terminal. It never asks for a
password itself: if the remote refuses, it says so. All of it is in `Sources/APIEngine/Git.swift`,
so a built-in library can replace the command before the app ships.

Limits: no stash, rebase, tags or amend; a merge needs a clean workspace first; a vault
inside a larger repository is not synced; and committing is refused while the mock server
runs, because it keeps a temporary environment in the workspace.

### Look and feel

The interface is custom rather than standard macOS controls: a top bar in place of the
toolbar, floating panels, colour-coded methods and status, underline tabs and
syntax-coloured JSON. Every colour and shared control lives in
`Sources/APIPlayground/Theme.swift`.

There are eight colour themes: Aurora, Sunset, Ultraviolet, Ocean, Forest, Gold, Neon and
Graphite. Choose one from the palette button in the top bar or View > Colour Theme. Each
sets the accent gradient and tints the dark background. The app is dark by default; the
same picker, or View > Appearance, switches to Light or Match System. To add a theme, add a
`Palette` in `Theme.swift` and list it in `Palette.all`.

### Script support

Scripts get `pm.test`, `pm.expect` (the commonly used Chai assertions), `pm.response`,
`pm.request`, `pm.environment`, `pm.globals`, `pm.collectionVariables`, `pm.variables`,
`console`, `btoa`/`atob`, and the older `tests[...]`, `responseBody` and `postman.*` API.

Not supported yet, and reported as a script error when used: `pm.sendRequest`,
`setNextRequest`, `require(...)` and Postman's bundled libraries such as CryptoJS, moment
and lodash. A value a script sets is stored as a "This Mac only" value. Collection and
folder scripts run but cannot be edited in the app yet. A script stuck in an endless loop
is not interrupted.

## Building

You need Xcode installed. The Command Line Tools alone cannot build the SwiftUI app.

Run the engine tests:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Build the app into `build/API Playground.app` (quit the app first if it is running):

```bash
Scripts/make-app.sh
```

Build a separate test copy, `build/API Playground Test.app`, with its own settings and
data, for trying changes without touching the real app's data:

```bash
Scripts/make-app.sh debug test
```

Open it:

```bash
open "build/API Playground.app"
```

## Layout

| Path | Contents |
|---|---|
| `Sources/APIEngine` | Model, file storage, variables, importers, HTTP. No UI code. |
| `Sources/CCurlShim` | C wrappers for the libcurl functions Swift cannot call directly. |
| `Sources/APIPlayground` | The SwiftUI and AppKit app. |
| `Tests/APIEngineTests` | Engine tests. HTTP tests use a local server and need no internet. |
| `Scripts/make-app.sh` | Builds the app bundle. |
