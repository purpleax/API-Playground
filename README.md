# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

## Status

Phases 1 to 6 are built, and so is every feature listed in [PLAN.md](PLAN.md).

Covered by engine tests:

- Postman import: Collection v2.0/v2.1, environments, globals, backup files holding several of each, and the zip from Postman's "Export Data"
- Insomnia import: export format 4 (JSON or YAML) and format 5 (YAML), with folders,
  environments, design documents' specs, gRPC requests, and response tags turned into
  "Save from response" rules
- Bruno import: a collection folder of `.bru` files or of YAML files (Bruno 3), a single
  `.bru` request, and the one-file JSON export, with environments, assertions and scripts
- Insomnia's `insomnia` and Bruno's `bru`, `req`, `res`, `test` and `expect` in scripts
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
- Response filtering with JSONPath and jq-style expressions
- Decoding JSON Web Tokens, and reading rate-limit headers in their common forms
- The server's certificate chain and a client certificate, against a TLS server on this Mac
- Copying a request as cURL (read back by the cURL importer), JavaScript, Python and Swift
- Repeat runs: sending a set number at once, stopping, percentiles and the error rate
- Matching for the command palette

Checked by hand in the running app:

- Importing files and a zip, the import report, browsing, editing and sending
- An Insomnia export and a Bruno collection folder, each made by hand, opened with the
  app: both imported, and in each a request used a token saved by the request before it,
  with the imported scripts and assertions passing
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
- API specs: opening a spec with its routes listed, problems that jump to their line, a
  ruleset that changed a rule's severity and added a custom rule, making a collection,
  starting a mock from it, and sending a route to the mock from the spec
- gRPC against a test server on this Mac: loading its methods by reflection, the methods
  still being there after a restart, choosing a method, a unary call, a server stream of
  40 messages, and a call that failed with NOT_FOUND
- Added in November 2026, against servers on this Mac: a JSONPath filter, a jq filter and
  a broken one on a response body; the rate-limit gauge and a decoded token on the
  Headers tab; the code sheet; a repeat run of 8 sends with one failure; the command
  palette finding and opening a request and starting a mock; the TLS tab after a request
  that presented a client certificate; and the menu-bar item showing the mock's port,
  listing its commands and stopping the mock

Not yet checked:

- The Shortcuts actions in the Shortcuts app. The app bundle carries their description,
  but no shortcut has been made or run with them
- In the command palette: the arrow keys, Return and Esc (rows were chosen by clicking),
  and ⌘K itself (it was opened from its button)
- A repeat run with more than one send at once from the app (the engine test covers it),
  and stopping one part-way
- Client certificates: choosing files in the sheet, a passphrase kept in the Keychain,
  and a `.p12` file from the app (the engine test covers `.p12`). A real server that
  demands a certificate
- Copy as cURL from the menu and the sidebar (the code sheet was checked), and the
  JavaScript and Swift code being run. Python and the cURL command are only checked to parse
- Hiding the menu-bar item, and the app staying open with its window closed while a mock runs
- gRPC against a real server, over TLS (`grpcs://`), with metadata or auth set in the app,
  a client-streaming call from the app, loading a descriptor set file, the Stop button
  on a stream, and a stream's messages appearing one by one (the test stream finished
  too quickly to watch)
- A failed gRPC call showing the server's message as the response body (changed after it
  was last looked at)
- API specs: New API Spec, Import OpenAPI Spec, deleting a spec, a JSON spec and a
  Swagger 2.0 spec on screen, Update Collection after editing a spec, and a large real
  spec such as Stripe's or GitHub's
- Git Sync's "Start Tracking This Vault with Git", Discard, saving the remote address and
  identity, and the folder chooser in Clone a Repository
- Push and pull against a real host such as GitHub (tests use a remote on this Mac)
- The zip import against a real Postman "Export Data" file (tested with a hand-made zip)
- Insomnia and Bruno imports against files those apps wrote themselves: every test file
  was written by hand from their documentation and source. Bruno's YAML format is the
  least certain, and its OAuth 2 settings and post-response actions are read by guesswork
  or not at all
- Choosing a Bruno folder or a YAML file in the Import file picker (the check opened them
  with the app instead)
- cURL import from the clipboard, the file-picker import, and switching to a Local Vault
- Form, multipart, GraphQL and file body editors
- Secret variables with the real Keychain (tests use an in-memory store)
- Editing scripts and "Save from response" rows on screen, and running a single folder
- OAuth 2's browser sign-in (authorization code): its requests are tested, but the sign-in
  window has not been tried against a real provider
- The cookie manager sheet, and a WebSocket over TLS (`wss://`)
- In phase 3: the P key while presenting (its button was checked), removing a pinned
  response, reordering demo steps, and the mock's list of requests received

### Inspecting responses

- **Filter.** Above a JSON body is a filter field. An expression that starts with `$` is
  JSONPath (`$.items[?(@.price > 10)].name`); anything else is read as jq
  (`.items[] | select(.price > 10) | .name`). The filter is saved with the request. The jq
  side covers paths, `[]`, slices, pipes, `select`, `map`, `length` and `keys`, not the
  whole language.
- **Rate limits and tokens.** When a response carries rate-limit headers, the Headers tab
  shows the remaining quota as a gauge with the time it refills. JSON Web Tokens found in
  the request's headers, the response's headers or its body are listed there and can be
  opened to read their claims and expiry. Signatures are not checked.
- **TLS.** An https response has a TLS tab with the protocol, the cipher and each
  certificate in the server's chain: who issued it, the names it covers, when it expires,
  and a button to copy it.
- **Client certificates.** Request > TLS and Client Certificates lists which certificate to
  present to which host, for servers that use mutual TLS. A certificate is a PEM file with
  its key, or a `.p12` file. The list is kept on this Mac, not in the workspace, and
  passphrases go in the Keychain. The same sheet can switch off the checking of server
  certificates, for a local server with a self-signed one. Client certificates are used
  for HTTP requests and OAuth 2 token requests, not yet for WebSockets or gRPC.
  The Mac's own TLS library cannot finish a TLS 1.3 handshake with a client certificate
  against servers running OpenSSL 3 or later, so when that handshake fails the request is
  sent once more over TLS 1.2, and the Log tab says so.

### Tools

- **Copy as code.** The braces button beside a request's name, or Request > Copy as
  Code, shows the request as cURL, JavaScript, Python or Swift with variables filled in.
  Request > Copy as cURL (⇧⌘C) copies straight away. While Hide Secrets is on, secrets
  are masked in the copy.
- **Repeat.** The repeat button, or Request > Repeat Request (⇧⌘R), sends one request a
  chosen number of times, several at once if wanted, and reports the median, 90%, 95% and
  99% response times, a histogram, and the error rate. A send counts as an error when it
  gets no response, a 4xx or 5xx status, or a failed test. Nothing from a repeat run is
  added to the history or saved to variables.
- **Command palette.** ⌘K opens a search over every request and command: go to a
  request, send, run a collection, switch environment, start a mock, change theme.
- **Menu bar.** An item in the menu bar starts and stops the mock server and copies its
  address. While a mock is running, closing the window leaves the app running so the
  mock stays up. View > Show Mock Servers in Menu Bar turns the item off.
- **Shortcuts.** The Shortcuts app gets five actions: Send Request, Run Collection, Start
  Mock Server, Stop Mock Server and Set Environment. They act on the workspace that is
  open in the app.

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

Git Sync uses libgit2, built into the app, so Git does not need to be installed on the Mac.
All of it is in `Sources/APIEngine/Git.swift`. Signing in to a remote:

- **https:// addresses** use the sign-in Git itself keeps in the Keychain for that server,
  if there is one. Otherwise, or if the remote turns it down, the app asks for a user name
  and a personal access token, saves them in the Keychain the same way Git does, and tries
  again.
- **git@ (SSH) addresses** run the Mac's own `ssh`, so they use the keys in your SSH agent
  or Keychain. A key that needs its passphrase typed, or a server whose host key has never
  been accepted, fails with a message instead of asking.

Not checked against a real host yet: both kinds of sign-in were only read through, because
the tests and the on-screen check used a remote in a local folder.

Limits: no stash, rebase, tags or amend; a merge needs a clean workspace first; a vault
inside a larger repository is not synced; and committing is refused while the mock server
runs, because it keeps a temporary environment in the workspace.

### Importing from Postman, Insomnia and Bruno

File > Import (⌘O) takes any of these, and works out which app each came from. Dropping
them on the app's icon does the same.

| From | What to choose |
| --- | --- |
| Postman | A collection or environment file, a backup file, or the zip from "Export Data" |
| Insomnia | An export file, JSON or YAML (format 4), or a collection's YAML file (format 5) |
| Bruno | The collection's folder, one `.bru` file, or the JSON from "Export collection" |

A zip can hold any mix of them. The report afterwards lists what came across and what
needs attention. All of it is in `Sources/APIEngine`: `Importer.swift` chooses, and
`PostmanImporter.swift`, `InsomniaImporter.swift` and `BrunoImporter.swift` read.

Where the other app has something this one does not, the import converts it:

- **Insomnia's base environment** becomes the collection's variables, and each
  sub-environment an environment. Nested values become one variable for each leaf, so
  `{{ _.user.name }}` becomes `{{user.name}}`.
- **Insomnia's response tag** (`{% response ... %}`), which reads a value from another
  request's last response, becomes a "Save from response" rule on that request and a
  variable. Unlike Insomnia, the other request is not sent for you: send it first.
- **`{% uuid %}` and `{% now %}`** become `{{$guid}}`, `{{$isoTimestamp}}` and
  `{{$timestamp}}`. Other template tags (faker, prompt, hash, file and so on) are left as
  written and listed in the report.
- **Headers and variables set on a folder**, or on a Bruno collection, are copied onto the
  requests inside it and into the collection's variables, because only requests have
  headers here and folders have no variables.
- **Bruno's assertions** become checks where there is an equivalent (`eq`, `neq`, `gt`,
  `lt`, `contains`, `notContains`, `matches`, `startsWith`, `endsWith`, `isDefined`,
  `isUndefined`); the rest are listed in the report. Its post-response variables become
  "Save from response" rules, or a script line when the expression is not a plain path.
- **Bruno's runtime variables** (`bru.setVar`) are kept as collection variables with a
  "This Mac only" value, so they last between requests as they do in Bruno.
- **A Bruno folder imported again** updates the collection it made. The JSON export has
  nothing to recognise it by, so importing it again makes a second collection.

Not imported: cookies, client certificates, proxy settings, Insomnia's unit tests and
mock servers, `.proto` files (a gRPC request keeps its address, method and message; load
its methods from the server), Bruno's secret values (Bruno keeps them out of its files)
and `{{process.env...}}` values, WebSocket messages, and auth kinds this app does not have
(digest, NTLM, AWS, OAuth 1 and others), which are set to no auth and listed.

### API specs

A workspace can hold OpenAPI 3.0, 3.1 and Swagger 2.0 specs, in YAML or JSON, in its `specs`
folder. They are kept exactly as written, so they read well in Git. File > New API Spec
starts one; File > Import OpenAPI Spec copies one in.

A spec opens with its text on the left and its routes on the right. The routes update as
you type. Each route has a send button, which sends it to one of the spec's servers (or to
the mock, while one runs) with example values filled in. Clicking a route or a problem
jumps to its line.

- **Make Collection** makes a request for each route, grouped into a folder per tag, with
  `{{baseUrl}}` set to the spec's first server, example parameters and bodies, each
  documented response saved as an example, and a check on the success status. Pressing it
  again updates the same collection; requests keep their ids and history. Edits made to
  the generated requests are replaced.
- **Mock Server** makes the collection and serves its documented responses.
- **Example values** come from the spec's `example`, `examples` and `default`, and
  otherwise are made up from the schema.

Problems come from a linter built into the app. Its rules follow Spectral's `spectral:oas`
ruleset and use the same names. File > Lint Rules edits the workspace's ruleset
(`specs/.spectral.yaml`, in Spectral's format), which can switch rules off, change their
severity, and add rules of its own.

Limits:

- The linter is not Spectral or vacuum. It has 27 of the `spectral:oas` rules; it does not
  check examples against their schemas or the document against the full OpenAPI schema.
- Custom rules can use these functions: truthy, falsy, defined, undefined, pattern, casing,
  length, enumeration, alphabetical and xor. Paths can use names, `[*]`, `..` and a final
  `~`; filters (`[?(…)]`) are not supported. A rule that needs something else is skipped,
  and says so in the problems list.
- A ruleset can extend `spectral:oas` only, not a file or a URL.
- A `$ref` to another file is not followed.
- The YAML reader covers what specs use. It does not support tags that change a value's
  type, complex (`?`) keys, or more than one document in a file.
- There is no word completion or schema-aware help in the editor.

### gRPC

File > New gRPC Request makes a request with a server address (`grpc://host:port`, or
`grpcs://` for TLS), a method, a message written as JSON, and metadata.

- **Load Methods** asks the server to describe its services (server reflection). The
  description is remembered for that address, so it is still there offline.
- **A descriptor set file** can be loaded for a server without reflection. Make one with
  `protoc --include_imports --descriptor_set_out=FILE` or `buf build -o FILE`.
- Choosing a method fills in an example message with every field.
- The reply is shown as JSON, with the gRPC status in place of the HTTP status. Checks,
  history and pinned responses work as for HTTP; a check on "Status" compares the gRPC
  status code, where 0 is OK.
- A server stream's messages are listed as they arrive, and the finished reply is a JSON
  list of them. For a client stream, write a JSON list to send several messages.

Limits:

- Every request message is sent before any reply is read. A two-way stream cannot react
  to replies as they come.
- A `.proto` file cannot be read directly; it must be compiled to a descriptor set.
- Compressed replies are not supported; the app asks servers not to compress.
- `Struct`, `Value` and `Any` are shown as the plain messages they are, not in their
  special JSON forms. Timestamps, durations and the wrapper types use theirs.
- Scripts and "Save from response" do not run for gRPC requests, and OAuth 2 is not
  applied to them. The collection runner does not send them correctly.
- Calls use libcurl's HTTP/2, which macOS includes.

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
and lodash. Scripts imported from Insomnia can use `insomnia` in place of `pm`. Scripts
imported from Bruno can use `bru` (variables and `interpolate`), `req`, `res`, `test` and
`expect`; `await`, `bru.sendRequest`, `bru.runRequest`, `bru.sleep` and `res('path')`
queries are not supported. A value a script sets is stored as a "This Mac only" value. Collection and
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

## Releasing

`Scripts/release.sh` makes the download, `build/release/API-Playground-VERSION.dmg`:

1. Runs the tests.
2. Builds for Apple silicon and Intel, with Sparkle and the icon inside the app.
3. Signs with the Developer ID certificate in the Keychain, with the hardened runtime.
4. Sends the app to Apple for notarisation and staples the answer to it.
5. Packs the app and a link to Applications into a disk image, then signs, notarises and
   staples that too.
6. If an update feed is set, signs the disk image with the update key and writes
   `appcast.xml` beside it.

Settings are in `Scripts/release.conf`: the version and build number (raise both for every
release), the update feed's address, and the names of the Keychain items below. Two things
must be set up once on the Mac that makes releases:

- **Notarisation sign-in.** Run `xcrun notarytool store-credentials api-playground-notary`
  and give it the Apple ID, team and an app-specific password. Until then `release.sh`
  stops and says so; `SKIP_NOTARISE=1 Scripts/release.sh` makes a signed disk image that is
  not notarised.
- **Update key.** Sparkle's private key is in the login Keychain under the account
  `api-playground`. Keep a backup: without it no update can be signed. Export one with
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account api-playground -x FILE`.

Updates stay switched off, and the app has no "Check for Updates…", until `FEED_URL` in
`release.conf` names where `appcast.xml` will be hosted. The test copy never updates.

The icon is a placeholder drawn by `Scripts/make-icon.swift`, which writes
`Resources/AppIcon.icns`. The licences of Sparkle and libgit2 are copied into the app as
`Contents/Resources/Acknowledgements.txt`.

Version 0.1.0 was released this way on 26 November 2026: Apple accepted both the app and
the disk image, and Gatekeeper reports each as "Notarized Developer ID".

Not checked: an update has never been downloaded and installed, because there is no feed
yet; the disk image has not been opened on another Mac; and the Intel half of the app has
not been run.

## Layout

| Path | Contents |
|---|---|
| `Sources/APIEngine` | Model, file storage, variables, importers, HTTP. No UI code. |
| `Sources/CCurlShim` | C wrappers for the libcurl functions Swift cannot call directly. |
| `Sources/APIPlayground` | The SwiftUI and AppKit app. |
| `Tests/APIEngineTests` | Engine tests. HTTP tests use a local server and need no internet. |
| `Tests/Support` | A small gRPC server, run with Node, that the gRPC tests call. Those tests are skipped where Node is not installed. |
| `Scripts/make-app.sh` | Builds the app bundle, including the description of its Shortcuts actions. |
| `Scripts/release.sh` | Makes the signed, notarised disk image. Settings in `Scripts/release.conf`. |
| `Scripts/make-icon.swift` | Draws the placeholder icon into `Resources/`. |
