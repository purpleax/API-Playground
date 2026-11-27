# API Playground

A native Mac app for managing, running, testing and demoing APIs. See [PLAN.md](PLAN.md) for the full plan.

Download the newest version from [Releases](https://github.com/purpleax/API-Playground/releases/latest).
It needs macOS 14 or later on Apple silicon, and from 0.3.2 it updates itself.

**[User manual](docs/User-Manual.md)**: installing, importing from Postman, Insomnia and
Bruno, and how to use every feature.

## What it does

- **Manage.** Collections, folders and environments kept as plain files on your Mac, with
  no account. Imports from Postman, Insomnia, Bruno, OpenAPI and cURL.
- **Run.** HTTP, GraphQL, gRPC, WebSockets and event streams, with timings, a wire log,
  response history and diffs, a JSONPath and jq filter, and a TLS inspector.
- **Test.** Checks without code, Postman-compatible scripts, values passed from one
  request to the next, a collection runner and a repeat runner with latency percentiles.
- **Demo.** Presentation mode, hidden secrets, pinned responses, demo sequences and a
  mock server, so a demo runs with no network.
- **Share.** Git Sync with a merge that works on values, not lines of text.

API Playground is free software under the [GNU General Public License, version 3](LICENSE).

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
- gRPC through the same engine as HTTP: scripts, saved values and checks around a call,
  and a server stream handed over message by message
- A proxy, its password, and hosts that skip it
- A WebSocket over TLS presenting a client certificate from PEM files and from a `.p12`
- Insomnia cookies, and Bruno certificates and proxy settings, read from exports

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
- Added in 0.3.0, against servers on this Mac: the Proxy and Certificates sheet saving a
  proxy, the certificate-checking switch and a certificate typed in as file paths; a
  request sent through the proxy with its user name, and local addresses skipping it; an
  imported Insomnia collection with a gRPC request and a WebSocket; Compare Across
  Environments showing both statuses and the changed lines; a collection run with a gRPC
  request in it; and a WebSocket to a self-signed server that was shown the certificate.
  The check found two faults in the collection runner, fixed in 0.3.1: a
  gRPC call's status 0 was drawn in red, and a WebSocket request was sent as a failed GET
  where it is now skipped with a note

Not yet checked:

- A proxy password typed into the sheet and kept in the Keychain (the engine test covers
  sending it), and editing the list of hosts to skip
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

## Notes on how it is built

How to use each feature, and each feature's limits, are in the
[user manual](docs/User-Manual.md). These notes are for people working on the code.

- **Importers.** All in `Sources/APIEngine`: `Importer.swift` works out which app a file
  came from, and `PostmanImporter.swift`, `InsomniaImporter.swift` and
  `BrunoImporter.swift` read them.
- **HTTP.** Requests go through the system's libcurl by way of `Sources/CCurlShim`. It is
  built on LibreSSL, which cannot finish a TLS 1.3 handshake with a client certificate
  against servers running OpenSSL 3 or later, so `HTTPClient` sends such a request once
  more over TLS 1.2 and notes it in the wire log.
- **gRPC.** Calls use libcurl's HTTP/2. The app reads the server's descriptors and
  converts messages itself, and asks servers not to compress.
- **WebSockets.** `URLSession`'s WebSocket task. A client certificate is loaded as an
  identity in memory, never into the Keychain, which needs macOS 15; PEM files are first
  packed into PKCS#12 with `/usr/bin/openssl`.
- **Scripts.** JavaScriptCore, with a Postman-compatible `pm` object and thinner
  `insomnia` and `bru` layers over it.
- **Git Sync.** libgit2, built into the app, in `Sources/APIEngine/Git.swift`. SSH
  addresses run the Mac's own `ssh`. Neither kind of sign-in has been tried against a real
  host: the tests and the on-screen check used a remote in a local folder.
- **API specs.** Kept in the workspace's `specs` folder, with the lint ruleset in
  `specs/.spectral.yaml`. The linter and the YAML reader are the app's own. The YAML
  reader covers what specs use: it does not support tags that change a value's type,
  complex (`?`) keys, or more than one document in a file.
- **Shortcuts.** The actions are in `Sources/APIPlayground/Shortcuts.swift`, and
  `make-app.sh` generates their description into the app bundle.
- **Look and feel.** The interface is custom rather than standard macOS controls. Every
  colour and shared control lives in `Sources/APIPlayground/Theme.swift`. To add a theme,
  add a `Palette` there and list it in `Palette.all`.

## Building

The app is built for Apple silicon and macOS 14 or later. You need Xcode installed. The Command Line Tools alone cannot build the SwiftUI app.

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
2. Builds for Apple silicon, with Sparkle and the icon inside the app. The app does not
   run on Intel Macs.
3. Signs with the Developer ID certificate in the Keychain, with the hardened runtime.
4. Sends the app to Apple for notarisation and staples the answer to it.
5. Packs the app and a link to Applications into a disk image, then signs, notarises and
   staples that too.
6. If an update feed is set, signs the disk image with the update key and writes
   `appcast.xml` beside it, listing that version only.

Publishing is a separate step: make a GitHub release tagged `v` and the version, and
attach the disk image and `appcast.xml` to it. Installed copies read the feed from the
newest release (`releases/latest/download/appcast.xml`), so a release only reaches them
once it is published and is not a draft or pre-release.

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

`FEED_URL` in `release.conf` names where `appcast.xml` is hosted; with it empty the app is
built without updates and has no "Check for Updates…". The test copy never updates.
Renaming or moving the GitHub repository would change that address, and copies already
installed would stop finding updates.

The icon is a placeholder drawn by `Scripts/make-icon.swift`, which writes
`Resources/AppIcon.icns`. The licences of Sparkle and libgit2 are copied into the app as
`Contents/Resources/Acknowledgements.txt`.

Versions 0.1.0 and 0.2.0 were both released this way on 26 November 2026: each time Apple
accepted the app and the disk image, and Gatekeeper reports each as "Notarized Developer
ID". 0.2.0 adds response filtering, the rate-limit gauge and token decoding, the TLS
inspector, client certificates, copying as code, the repeat runner, the command palette,
the menu-bar item and the Shortcuts actions.

Version 0.3.0 was released the same way on 27 November 2026. It is the first build for
Apple silicon only, which roughly halves the disk image (5.3 MB), and it adds the proxy
setting, gRPC through the request engine, client certificates for WebSockets and gRPC,
imported cookies and settings, and Compare Across Environments.

Version 0.3.1 followed the same day with the two collection-runner fixes that the check
of 0.3.0 found: a gRPC call's status is shown correctly, and a WebSocket request is
skipped in a run.

Version 0.3.2, also on 27 November 2026, is the first with an update feed and the first
published on GitHub. Versions before it never check for updates and have to be replaced
by hand.

Not checked: an update has never been downloaded and installed, because that needs a
version newer than 0.3.2 to be published; and the disk image has not been opened on
another Mac.

## Layout

| Path | Contents |
|---|---|
| `docs/User-Manual.md` | The user manual. |
| `PLAN.md` | The plan: goals, design decisions, phases and open questions. |
| `LICENSE` | The GNU General Public License, version 3. |
| `Sources/APIEngine` | Model, file storage, variables, importers, HTTP. No UI code. |
| `Sources/CCurlShim` | C wrappers for the libcurl functions Swift cannot call directly. |
| `Sources/APIPlayground` | The SwiftUI and AppKit app. |
| `Tests/APIEngineTests` | Engine tests. HTTP tests use a local server and need no internet. |
| `Tests/Support` | A small gRPC server and a WebSocket server over TLS, run with Node, that the tests call. Those tests are skipped where Node is not installed. |
| `Scripts/make-app.sh` | Builds the app bundle, including the description of its Shortcuts actions. |
| `Scripts/release.sh` | Makes the signed, notarised disk image and the update feed. Settings in `Scripts/release.conf`. |
| `Scripts/make-icon.swift` | Draws the placeholder icon into `Resources/`. |
