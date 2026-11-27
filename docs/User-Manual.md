# API Playground user manual

API Playground is a Mac app for managing, running, testing and demoing APIs. Everything
you make is kept in plain files on your Mac. There is no account and nothing is sent to a
server of ours.

This manual describes version 0.3.2.

## Contents

1. [Installing and updating](#1-installing-and-updating)
2. [The window](#2-the-window)
3. [Where your work is kept](#3-where-your-work-is-kept)
4. [Bringing in existing work](#4-bringing-in-existing-work)
5. [Requests](#5-requests)
6. [Variables and environments](#6-variables-and-environments)
7. [Authentication](#7-authentication)
8. [Reading a response](#8-reading-a-response)
9. [Testing](#9-testing)
10. [Scripts](#10-scripts)
11. [Event streams, WebSockets, GraphQL and gRPC](#11-event-streams-websockets-graphql-and-grpc)
12. [Cookies, proxy and certificates](#12-cookies-proxy-and-certificates)
13. [Tools](#13-tools)
14. [Demoing an API](#14-demoing-an-api)
15. [API specs](#15-api-specs)
16. [Sharing a workspace with Git](#16-sharing-a-workspace-with-git)
17. [Themes](#17-themes)
18. [Keyboard shortcuts](#18-keyboard-shortcuts)
19. [Privacy and where things are stored](#19-privacy-and-where-things-are-stored)

## 1. Installing and updating

You need a Mac with Apple silicon running macOS 14 or later. The app does not run on
Intel Macs.

1. Download the newest `API-Playground-VERSION.dmg` from the
   [Releases page](https://github.com/purpleax/API-Playground/releases/latest).
2. Open it and drag API Playground into Applications.
3. Open the app. It is signed and notarised by Apple, so it opens without a warning.

From version 0.3.2 the app looks for updates by itself. To look now, choose **API
Playground > Check for Updates…**. Versions before 0.3.2 do not update: replace them with a
newer download by hand.

## 2. The window

- **Sidebar** (left): your collections, with their folders and requests, then demo
  sequences and API specs. The field at the top filters requests by name. Right-click a
  collection, folder or request for its commands: New Request, New Folder, Rename, Run
  Collection or Run Folder, Mock Server, Delete and so on.
- **Request editor** (middle): the method, the address and the Send button, with tabs for
  Params, Headers, Body, Auth, Tests and Scripts.
- **Response** (right): the status, size and time, with tabs for the body, headers and
  more. See [Reading a response](#8-reading-a-response).
- **Top bar**: the name of the workspace, the environment switcher, and buttons for the
  command palette, the theme, the environment editor, Hide Secrets and the mock server.

**⌘K** opens the command palette, which finds any request or command by typing part of
its name.

## 3. Where your work is kept

A workspace is a folder of plain files: one for each request, folder and environment. The
app can work in three ways.

| Mode | What it is | How to choose it |
|---|---|---|
| Scratch Pad | A private folder the app keeps for you. It works straight away with nothing to set up. | File > Use Scratch Pad |
| Local Vault | A folder you choose, for example one inside a project. | File > Open Local Vault… |
| Git Sync | A Local Vault that is a Git repository, shared with other people. | See [Sharing a workspace with Git](#16-sharing-a-workspace-with-git) |

The chip beside the app's name in the top bar shows which one is open. Changes are saved
as you make them; there is no Save command.

## 4. Bringing in existing work

**File > Import… (⌘O)** takes exports from Postman, Insomnia and Bruno and works out which
app each file came from. Dropping files on the app's icon does the same.

| From | What to choose |
|---|---|
| Postman | A collection or environment file, a backup file, or the zip from "Export Data" |
| Insomnia | An export file, JSON or YAML (format 4), or a collection's YAML file (format 5) |
| Bruno | The collection's folder, one `.bru` file, or the JSON from "Export collection" |

A zip can hold any mix of them. Afterwards a report lists what came across and what needs
your attention. Importing a Postman or Insomnia collection, or a Bruno folder, a second
time updates the collection it made, and its requests keep their history. Bruno's JSON
export has nothing to recognise it by, so importing it again makes a second collection.

**File > Import cURL from Clipboard (⇧⌘V)** turns a copied `curl` command into a request.

### How things from other apps are converted

- **Insomnia's base environment** becomes the collection's variables, and each
  sub-environment becomes an environment. Nested values become one variable for each
  leaf, so `{{ _.user.name }}` becomes `{{user.name}}`.
- **Insomnia's response tag** (`{% response ... %}`), which reads a value from another
  request's last response, becomes a "Save from response" rule on that request and a
  variable. Unlike Insomnia, the other request is not sent for you: send it first.
- **`{% uuid %}` and `{% now %}`** become `{{$guid}}`, `{{$isoTimestamp}}` and
  `{{$timestamp}}`. Other template tags (faker, prompt, hash, file and so on) are left as
  written and listed in the report.
- **Headers and variables set on a folder**, or on a Bruno collection, are copied onto the
  requests inside it and into the collection's variables.
- **Bruno's assertions** become checks where there is an equivalent; the rest are listed
  in the report. Its post-response variables become "Save from response" rules, or a
  script line when the expression is not a plain path.
- **Bruno's runtime variables** (`bru.setVar`) are kept as collection variables with a
  "This Mac only" value, so they last between requests as they do in Bruno.
- **Settings that belong to the Mac** come across too: the cookies in an Insomnia cookie
  jar, and the client certificates and proxy in a Bruno collection's `bruno.json`. A proxy
  is taken on only when none is set here, because it applies to every request. Postman's
  exports contain none of these.

### What is not imported

- Bruno's certificates and proxy from its YAML format or from inside a zip
- Insomnia's unit tests and mock servers
- `.proto` files. A gRPC request keeps its address, method and message; load its methods
  from the server.
- Bruno's secret values (Bruno keeps them out of its files) and `{{process.env...}}` values
- WebSocket messages
- Kinds of authentication this app does not have (digest, NTLM, AWS, OAuth 1 and others).
  Those requests are set to no auth and listed in the report.

## 5. Requests

**File > New Request (⌘N)** adds a request to the current collection, and **File > New
Collection (⇧⌘N)** starts a collection. Choose the method, type the address, and press
**Send** or **⌘↩**.

| Tab | What it holds |
|---|---|
| Params | Query parameters, added to the address for you |
| Headers | Request headers. Untick one to leave it out without deleting it. |
| Body | None, Raw (JSON or other text), Form, Multipart, GraphQL, or a File |
| Auth | How the request signs in. See [Authentication](#7-authentication). |
| Tests | Checks on the response, and values to save from it. See [Testing](#9-testing). |
| Scripts | JavaScript to run before the request and after the response |

Anywhere you can type a value, `{{name}}` is replaced with the variable of that name when
the request is sent.

A request waits up to 30 seconds for a response. Event streams are not cut off.

## 6. Variables and environments

Variables let one request work against several servers or accounts. Write `{{name}}` in
an address, a header, a body or an auth field.

There are three places a variable can live. When the same name is in more than one, the
environment wins over the collection, and the collection wins over globals.

| Scope | Use it for |
|---|---|
| Globals | Values every request can use |
| Collection | Values that belong to one collection, such as its base address |
| Environment | Values that change between servers: staging, production and so on |

**Request > Environments… (⌘E)** edits environments and globals. The switcher in the top
bar chooses which environment is active.

Each variable has up to three parts:

- **Shared value**: saved in the workspace, and shared with anyone you share it with.
- **This Mac only**: used in place of the shared value on your Mac. It is never saved to
  the workspace, so it is the place for your own token or a local address.
- **Secret**: tick this for passwords, tokens and keys. The value is kept in your Mac's
  Keychain, not in a file, and is masked when Hide Secrets is on.

These names are filled in for you each time a request is sent: `{{$guid}}` and
`{{$randomUUID}}` (a new UUID), `{{$timestamp}}` (seconds since 1970),
`{{$isoTimestamp}}` (the date and time), `{{$randomInt}}` and `{{$randomBoolean}}`.

A name with no value is left in the request as written, so it is easy to spot.

## 7. Authentication

Choose the kind in a request's **Auth** tab.

| Kind | What it does |
|---|---|
| Inherit from parent | Uses whatever the folder or collection above it is set to |
| No auth | Sends nothing |
| Basic | A user name and password |
| Bearer token | A token in the `Authorization` header |
| API key | A named key, sent as a header or as a query parameter |
| OAuth 2 | Fetches a token and sends it; see below |

**OAuth 2.** Choose the grant type and fill in the provider's details. Client credentials
and password tokens are fetched automatically when the request is sent. Authorization code
opens a sign-in window; register `apiplayground://oauth/callback` with the provider as the
redirect address. Tokens are kept in the Keychain and refreshed when they expire.

## 8. Reading a response

The bar at the top shows the status, the size, the time taken and the HTTP version. The
pin button keeps the response with the request (see [Demoing an API](#14-demoing-an-api)).

| Tab | What it shows |
|---|---|
| Body | The response, with JSON coloured and laid out. **Format** switches between the tidy and the original layout. |
| Events | The events of an event stream, as they arrive |
| Headers | Response headers, plus the rate-limit gauge and decoded tokens described below |
| Cookies | Cookies the response set |
| Tests | The result of each check and script test, and the script console |
| Timing | How long each phase took: looking up the name, connecting, TLS, waiting, downloading |
| TLS | For https: the protocol, the cipher and each certificate in the server's chain |
| Log | Exactly what was sent and received on the wire |
| History | Past responses to this request |

**Filtering a JSON body.** Type an expression in the field above the body. One that starts
with `$` is JSONPath, for example `$.items[?(@.price > 10)].name`. Anything else is read
as jq, for example `.items[] | select(.price > 10) | .name`. The filter is saved with the
request. The jq side covers paths, `[]`, slices, pipes, `select`, `map`, `length` and
`keys`, not the whole language.

**Rate limits and tokens.** When a response carries rate-limit headers, the Headers tab
shows the remaining quota as a gauge with the time it refills. JSON Web Tokens found in
the request's headers, the response's headers or its body are listed there and can be
opened to read their claims and expiry. Signatures are not checked.

**History and differences.** Every response is kept. Choose an older one in the History
tab to see the lines that changed between it and the current response.

**Comparing environments.** **Request > Compare Across Environments…** sends the request
once in each of two environments and shows both statuses and the lines that differ
between the two bodies. Nothing from it is saved.

## 9. Testing

### Checks

In a request's **Tests** tab, **Add Check** adds a rule that is tested against every
response, with no code: the status, a header, a value in a JSON body, the body's text, or
the response time. Each check shows as a pass or a fail in the response's Tests tab.

### Saving a value for the next request

In the same tab, **Add Saved Value** copies a value out of the response into a variable,
so a later request can use it as `{{name}}`. This is how a sign-in request hands its token
to the requests after it.

### Running a collection or a folder

**Request > Run Collection (⌘R)**, or **Run Collection** or **Run Folder** from the
sidebar's right-click menu, sends every request in order and shows a pass or fail for
each, with the status and time. Values saved by one request reach the next. **Open** jumps
to a request, and **Run Again** repeats the run.

WebSocket requests are skipped in a run, because a WebSocket stays open until someone
closes it. gRPC requests run in their place in the order.

### Repeating one request

**Request > Repeat Request… (⇧⌘R)** sends one request a chosen number of times, several at
once if you want, and reports the median, 90%, 95% and 99% response times, a histogram and
the error rate. A send counts as an error when it gets no response, a 4xx or 5xx status,
or a failed test. Nothing from a repeat run is added to the history or saved to variables.

## 10. Scripts

A request's **Scripts** tab holds JavaScript that runs before the request is sent and
after the response arrives. Scripts written for Postman run unchanged in most cases.

Available: `pm.test`, `pm.expect` (the commonly used Chai assertions), `pm.response`,
`pm.request`, `pm.environment`, `pm.globals`, `pm.collectionVariables`, `pm.variables`,
`console`, `btoa` and `atob`, and the older `tests[...]`, `responseBody` and `postman.*`.

Scripts imported from Insomnia can use `insomnia` in place of `pm`. Scripts imported from
Bruno can use `bru` (variables and `interpolate`), `req`, `res`, `test` and `expect`.

Not supported, and reported as a script error when used:

- `pm.sendRequest`, `setNextRequest` and `require(...)`
- Postman's bundled libraries, such as CryptoJS, moment and lodash
- From Bruno: `await`, `bru.sendRequest`, `bru.runRequest`, `bru.sleep` and `res('path')`

Other things to know:

- A value a script sets is stored as a "This Mac only" value.
- Scripts on a collection or folder run in Postman's order, but can't be edited in the
  app yet.
- A script stuck in an endless loop is not interrupted.

## 11. Event streams, WebSockets, GraphQL and gRPC

**Event streams.** A response of type `text/event-stream` shows its events as they
arrive. **Stop** ends it and keeps what was received.

**WebSockets.** A request whose address starts with `ws://` or `wss://` gets a
conversation in place of the response, and **Connect** in place of Send. Type a message
at the bottom and send it; `{{variables}}` are filled in. The message you are writing is
saved with the request. WebSocket traffic has no timing or wire log.

**GraphQL.** Choose GraphQL as the body, then write the query and its variables.
**Schema** asks the server to describe itself and opens a browser of its types and
fields. There is no query autocomplete yet.

**gRPC.** **File > New gRPC Request (⌥⌘N)** makes a request with a server address
(`grpc://host:port`, or `grpcs://` for TLS), a method, a message written as JSON, and
metadata.

- **Load Methods** asks the server to describe its services. The description is
  remembered for that address, so it is still there offline.
- For a server that can't describe itself, load a descriptor set file. Make one with
  `protoc --include_imports --descriptor_set_out=FILE` or `buf build -o FILE`. A `.proto`
  file can't be read directly.
- Choosing a method fills in an example message with every field.
- The reply is shown as JSON, with the gRPC status in place of the HTTP status; 0 is OK.
- A server stream's messages are listed as they arrive. For a client stream, write a JSON
  list to send several messages.
- Checks, saved values, scripts, OAuth 2, history and pinned responses work as they do for
  HTTP. A check on "Status" compares the gRPC status code.

Limits: every request message is sent before any reply is read, so a two-way stream can't
react to replies as they come. Compressed replies are not supported. `Struct`, `Value`
and `Any` are shown as plain messages, not in their special JSON forms.

## 12. Cookies, proxy and certificates

**Cookies.** Cookies a server sets are kept on your Mac, for each workspace, and sent
back on later requests to the same site, unless the request has a Cookie header of its
own. **Request > Cookies…** lists and removes them. Cookies set on a redirect that is
followed are not kept.

**Request > Proxy and Certificates…** holds three settings. They stay on your Mac and are
not part of the workspace; passwords and passphrases go in the Keychain.

- **Send requests through a proxy.** Give an `http://` or `socks5://` address, a user name
  and password if the proxy asks for them, and the hosts to reach directly ("Skip for").
  With this off, requests go direct: the Mac's own proxy settings are not read.
  WebSockets use the proxy too, but without the user name and password.
- **Check server certificates.** Leave this on. Switch it off only to reach a local server
  with a self-signed certificate, and back on when you are done: while it is off any
  certificate is accepted.
- **Client certificates.** For servers that ask the client for a certificate (mutual
  TLS), list which certificate to present to which host. A certificate is a PEM file with
  its key, or a `.p12` or `.pfx` file. It is presented on HTTP requests, OAuth 2 token
  requests, gRPC calls and WebSockets. WebSockets need macOS 15 or later for this.

If a server refuses a client certificate over TLS 1.3, the request is sent once more over
TLS 1.2, and the Log tab says so.

## 13. Tools

**Command palette (⌘K).** Search every request and command: go to a request, send, run a
collection, switch environment, start a mock, change theme.

**Copy as code.** The braces button beside a request's name, or **Request > Copy as
Code… (⌥⌘C)**, shows the request as cURL, JavaScript, Python or Swift with variables
filled in. **Request > Copy as cURL (⇧⌘C)** copies straight away. While Hide Secrets is
on, secrets are masked in the copy.

**Menu bar.** An item in the Mac's menu bar starts and stops the mock server and copies
its address. While a mock is running, closing the window leaves the app running so the
mock stays up. **View > Show Mock Servers in Menu Bar** turns the item off.

**Shortcuts.** The Shortcuts app gets five actions: Send Request, Run Collection, Start
Mock Server, Stop Mock Server and Set Environment. They act on the workspace that is open
in the app.

## 14. Demoing an API

**Hide Secrets (⇧⌘H)**, or the eye in the top bar, masks tokens, keys and passwords
wherever they are displayed. Requests still send the real values.

**Pinned responses.** The pin button on a response keeps it with the request. A pinned
response can be shown in place of a live one, which helps when the real API is slow or
down, and it is what the mock server serves.

**Mock server.** **Demo > Mock Server… (⇧⌘M)** answers requests on your Mac with each
request's pinned responses, so a demo needs no backend and no network. It listens on
`127.0.0.1` only. A request with nothing pinned is answered with 501. When a collection's
addresses start with a shared variable such as `{{baseUrl}}`, starting the mock points
that variable at it through a temporary environment, which is removed when the mock
stops. The sheet lists the requests the mock has received.

**Demo sequences.** **Demo > New Demo…** makes an ordered list of requests, each with a
short note.

**Presenting.** **Demo > Present Request (⇧⌘P)**, or **Present** on a demo sequence,
shows one step at a time in large type. Hide Secrets is always on while presenting.

| Key | What it does |
|---|---|
| Space | Sends the request |
| ← → | Moves between steps |
| P | Shows the pinned response instead of calling the API |
| Esc | Stops presenting |

## 15. API specs

A workspace can hold OpenAPI 3.0, 3.1 and Swagger 2.0 specs, in YAML or JSON. They are
kept exactly as written. **File > New API Spec** starts one, and **File > Import OpenAPI
Spec…** copies one in.

A spec opens with its text on the left and its routes on the right. The routes update as
you type. Each route has a send button, which sends it to one of the spec's servers (or to
the mock, while one runs) with example values filled in. Clicking a route or a problem
jumps to its line.

- **Make Collection** makes a request for each route, grouped into a folder for each tag,
  with `{{baseUrl}}` set to the spec's first server, example parameters and bodies, each
  documented response saved as an example, and a check on the success status. Pressing it
  again updates the same collection, and requests keep their history. Edits you made to
  the generated requests are replaced.
- **Mock Server** makes the collection and serves its documented responses.
- **Example values** come from the spec's `example`, `examples` and `default`, and are
  otherwise made up from the schema.

**Problems** come from a linter built into the app. Its rules follow Spectral's
`spectral:oas` ruleset and use the same names. **File > Lint Rules…** edits the
workspace's ruleset, in Spectral's format, which can switch rules off, change their
severity and add rules of its own.

Limits:

- The linter has 27 of the `spectral:oas` rules. It does not check examples against their
  schemas, or the document against the full OpenAPI schema.
- Custom rules can use these functions: truthy, falsy, defined, undefined, pattern,
  casing, length, enumeration, alphabetical and xor. Paths can use names, `[*]`, `..` and
  a final `~`; filters (`[?(…)]`) are not supported. A rule that needs something else is
  skipped, and the problems list says so.
- A ruleset can extend `spectral:oas` only, not a file or a web address.
- A `$ref` to another file is not followed.
- There is no word completion in the editor.

## 16. Sharing a workspace with Git

A Local Vault that is a Git repository gets a branch chip in the top bar and a **Git**
menu. Git does not need to be installed on your Mac.

- **Git > Clone a Repository…** copies a shared workspace onto your Mac and opens it.
- **Git > Start Tracking This Vault with Git** turns the open vault into a repository.
- **Git > Git Sync… (⇧⌘G)** opens the sheet for everything else.

In Git Sync:

- **Changes** lists what is uncommitted by its name in the app ("Request: List pets"),
  with the difference from the last commit, **Discard**, and a box to commit.
- **Pull** merges by value, not by line of text. Two people changing different fields of
  one request, or adding different headers, never collide. Only a value both changed in
  different ways is a conflict. The merge view then shows yours and theirs side by side
  for each one, with the value before. **Abandon Merge** puts everything back.
- **Branches** can be created, switched and merged into the current one.

Secret values, "This Mac only" values, cookies, history and OAuth tokens are never
committed.

**Signing in to a remote**

- **`https://` addresses** use the sign-in Git itself keeps in the Keychain for that
  server, if there is one. Otherwise the app asks for a user name and a personal access
  token, and saves them in the Keychain the way Git does.
- **`git@` (SSH) addresses** use the keys in your SSH agent or Keychain. A key that needs
  its passphrase typed, or a server whose host key has never been accepted, fails with a
  message instead of asking.

Limits: no stash, rebase, tags or amend. A merge needs a clean workspace first. A vault
inside a larger repository is not synced. Committing is refused while the mock server
runs, because the mock keeps a temporary environment in the workspace.

## 17. Themes

There are eight colour themes: Aurora, Sunset, Ultraviolet, Ocean, Forest, Gold, Neon and
Graphite. Choose one from the palette button in the top bar, **View > Theme… (⇧⌘T)** or
**View > Colour Theme**. The app is dark by default; the same picker, or **View >
Appearance**, switches to Light or Match System.

## 18. Keyboard shortcuts

| Shortcut | Command |
|---|---|
| ⌘↩ | Send |
| ⌘N | New Request |
| ⌥⌘N | New gRPC Request |
| ⇧⌘N | New Collection |
| ⌘O | Import… |
| ⇧⌘V | Import cURL from Clipboard |
| ⌘R | Run Collection |
| ⇧⌘R | Repeat Request… |
| ⇧⌘C | Copy as cURL |
| ⌥⌘C | Copy as Code… |
| ⌘E | Environments… |
| ⌘K | Command Palette… |
| ⌃⌘S | Hide or show the sidebar |
| ⇧⌘T | Theme… |
| ⇧⌘G | Git Sync… |
| ⇧⌘P | Present Request, or stop presenting |
| ⇧⌘H | Hide Secrets |
| ⇧⌘M | Mock Server… |

## 19. Privacy and where things are stored

- **Your workspace** is the folder you chose, or the Scratch Pad inside
  `~/Library/Application Support/API Playground`.
- **Secret values, OAuth tokens, proxy passwords and certificate passphrases** are in
  your Mac's Keychain.
- **"This Mac only" values, cookies, response history, and the proxy and certificate
  settings** are in the app's own data on your Mac, outside the workspace, so they are
  never shared or committed.
- **Nothing is sent anywhere** except the requests you send, and a check for updates
  against the project's GitHub releases.

The app is free software under the GNU General Public License, version 3. Its source is
at [github.com/purpleax/API-Playground](https://github.com/purpleax/API-Playground),
where problems can be reported.
