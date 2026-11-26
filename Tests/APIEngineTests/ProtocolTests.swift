import Foundation
import Network
import Testing
@testable import APIEngine

func withEchoServer<T>(_ work: (String) async throws -> T) async throws -> T {
    let server = try EchoServer()
    try await server.start()
    defer { server.stop() }
    return try await work("http://127.0.0.1:\(server.port)")
}

final class Collector<Value: Sendable>: @unchecked Sendable {
    private var values: [Value] = []
    private let lock = NSLock()
    func add(_ value: Value) { lock.lock(); values.append(value); lock.unlock() }
    var all: [Value] { lock.lock(); defer { lock.unlock() }; return values }
}

@Suite struct EventStreams {
    @Test func parserHandlesFieldsCommentsAndSplitChunks() {
        var parser = ServerSentEventParser()
        var events = parser.feed(Data(": hello\ndata: one\n\nevent: update\nid: 7\ndata: {\"a\":".utf8))
        #expect(events == [ServerSentEvent(data: "one")])
        events = parser.feed(Data(" 1}\ndata: second line\nretry: 5000\n\r\ndata:no space\r\n\r\ndata: partial".utf8))
        #expect(events == [
            ServerSentEvent(event: "update", data: "{\"a\": 1}\nsecond line", lastEventID: "7"),
            ServerSentEvent(data: "no space", lastEventID: "7"),
        ])
        #expect(parser.retry == 5000)
        // The id carries over to later events, and an unfinished event waits for its blank line.
        #expect(parser.feed(Data("\n\n".utf8)) == [ServerSentEvent(data: "partial", lastEventID: "7")])
        #expect(ServerSentEventParser.events(in: Data("data: a\n\ndata: cut off".utf8)).map(\.data) == ["a", "cut off"])
    }

    @Test func eventsArriveWhileTheResponseIsStillOpen() async throws {
        try await withEchoServer { base in
            let chunks = Collector<Data>()
            let headers = Collector<Int>()
            let handlers = HTTPStreamHandlers(
                onHeaders: { status, headers_ in
                    headers.add(status)
                    #expect(headers_.contains(HTTPHeader(name: "Content-Type", value: "text/event-stream")))
                },
                onData: { chunks.add($0) }
            )
            let response = try await HTTPClient().send(PreparedRequest(method: "GET", url: "\(base)/sse"), handlers: handlers)
            #expect(response.status == 200)
            #expect(!response.wasCancelled)
            #expect(headers.all == [200])
            // The events came in more than one piece, and together they are the whole body.
            #expect(chunks.all.count > 1)
            #expect(chunks.all.reduce(Data(), +) == response.body)
            let events = ServerSentEventParser.events(in: response.body)
            #expect(events.map(\.data) == ["tick 1", "{\"n\": 2}", "tick 3"])
            #expect(events.map(\.event) == ["message", "update", "message"])
        }
    }

    @Test func anOpenStreamCanBeStoppedAndKeepsWhatArrived() async throws {
        try await withEchoServer { base in
            let flag = CancellationFlag()
            let seen = Collector<Data>()
            let handlers = HTTPStreamHandlers(onData: { chunk in
                seen.add(chunk)
                if seen.all.count >= 3 { flag.cancel() }
            })
            // A short timeout shows that an event stream is not cut off by it.
            let response = try await HTTPClient().send(
                PreparedRequest(method: "GET", url: "\(base)/sse-forever"),
                options: HTTPOptions(timeout: 0.1), handlers: handlers, cancellation: flag
            )
            #expect(response.wasCancelled)
            #expect(response.status == 200)
            #expect(ServerSentEventParser.events(in: response.body).count >= 3)
        }
    }

    @Test func cancellingBeforeAnyResponseIsAnError() async throws {
        let flag = CancellationFlag()
        flag.cancel()
        await #expect(throws: HTTPClientError.self) {
            // A non-routable address, so nothing can answer before the cancel is seen.
            try await HTTPClient().send(PreparedRequest(method: "GET", url: "http://10.255.255.1:81/"), cancellation: flag)
        }
    }
}

@Suite struct Cookies {
    let url = URL(string: "https://shop.example.com/account/settings")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func parsesAttributes() throws {
        let cookie = try #require(CookieJar.parse("sid=abc; Domain=.example.com; Path=/account; Max-Age=60; Secure; HttpOnly", from: url, now: now))
        #expect(cookie == Cookie(name: "sid", value: "abc", domain: "example.com", hostOnly: false, path: "/account",
                                 expires: now.addingTimeInterval(60), secure: true, httpOnly: true))

        let plain = try #require(CookieJar.parse("theme=dark", from: url, now: now))
        #expect(plain.domain == "shop.example.com")
        #expect(plain.hostOnly)
        #expect(plain.path == "/account")
        #expect(plain.expires == nil)

        let dated = try #require(CookieJar.parse("a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT", from: url, now: now))
        #expect(dated.expires != nil)

        // A server cannot set a cookie for someone else's domain.
        #expect(CookieJar.parse("x=1; Domain=evil.com", from: url) == nil)
        #expect(CookieJar.parse("no-equals", from: url) == nil)
    }

    @Test func matchesByDomainPathSchemeAndExpiry() {
        var jar = CookieJar()
        jar.store(setCookieHeaders: [
            "wide=1; Domain=example.com; Path=/",
            "host=2; Path=/",
            "deep=3; Path=/account/settings",
            "secure=4; Path=/; Secure",
            "brief=5; Path=/; Max-Age=10",
        ], from: url, now: now)

        #expect(jar.header(for: url, now: now) == "deep=3; wide=1; host=2; secure=4; brief=5")
        #expect(jar.header(for: URL(string: "https://shop.example.com/")!, now: now) == "wide=1; host=2; secure=4; brief=5")
        // Another subdomain only gets the cookie set for the parent domain.
        #expect(jar.header(for: URL(string: "https://api.example.com/")!, now: now) == "wide=1")
        // No Secure cookie over plain http, and nothing for an unrelated site.
        #expect(jar.header(for: URL(string: "http://shop.example.com/")!, now: now) == "wide=1; host=2; brief=5")
        #expect(jar.header(for: URL(string: "https://other.org/")!, now: now) == nil)
        // "/accounting" is not under "/account".
        #expect(jar.header(for: URL(string: "https://shop.example.com/accounting")!, now: now)?.contains("deep") == false)
        // Later, the short-lived cookie is gone.
        #expect(jar.header(for: URL(string: "https://shop.example.com/")!, now: now.addingTimeInterval(11)) == "wide=1; host=2; secure=4")
    }

    @Test func replacesAndDeletes() {
        var jar = CookieJar()
        jar.store(setCookieHeaders: ["a=1; Path=/", "b=1; Path=/"], from: url, now: now)
        jar.store(setCookieHeaders: ["a=2; Path=/", "b=; Path=/; Max-Age=0"], from: url, now: now)
        #expect(jar.cookies.map { "\($0.name)=\($0.value)" } == ["a=2"])
    }

    @Test func overlappingRunsDoNotUndoEachOther() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Two requests start from the same empty jar. One sets a cookie and finishes first.
        let start = CookieJar()
        var first = start
        first.store(setCookieHeaders: ["session=abc; Path=/"], from: url, now: now)
        var current = RunState.merge(start, from: start, to: first)
        #expect(current.cookies.map(\.name) == ["session"])
        // The slower one changed nothing, so finishing it must not wipe the cookie.
        current = RunState.merge(current, from: start, to: start)
        #expect(current.cookies.map(\.name) == ["session"])
        // A run that deletes a cookie removes only that one.
        var deleting = current
        deleting.store(setCookieHeaders: ["session=; Path=/; Max-Age=0", "other=1; Path=/"], from: url, now: now)
        #expect(RunState.merge(current, from: current, to: deleting).cookies.map(\.name) == ["other"])

        // The same rule for variables.
        let before = [Variable(key: "a", value: "1"), Variable(key: "gone", value: "x")]
        let after = [Variable(key: "a", value: "1", currentValue: "2"), Variable(key: "new", value: "", currentValue: "n")]
        let meanwhile = before + [Variable(key: "other", value: "kept")]
        #expect(RunState.merge(meanwhile, from: before, to: after) == [
            Variable(key: "a", value: "1", currentValue: "2"), Variable(key: "other", value: "kept"), Variable(key: "new", value: "", currentValue: "n"),
        ])
        #expect(RunState.merge(meanwhile, from: before, to: before) == meanwhile)
    }

    @Test func cookiesCarryBetweenRequestsInARun() async throws {
        try await withEchoServer { base in
            let login = RequestItem(name: "Login", url: "\(base)/login")
            let home = RequestItem(name: "Home", url: "\(base)/home")
            let admin = RequestItem(name: "Admin", url: "\(base)/admin/users")
            let own = RequestItem(name: "Own", url: "\(base)/home", headers: [KeyValue(key: "Cookie", value: "mine=1")])
            let collection = APICollection(items: [.request(login), .request(home), .request(admin), .request(own)])
            var state = RunState()
            let executor = RequestExecutor()

            _ = await executor.run(login, in: collection, state: &state)
            #expect(state.cookies.cookies.map(\.name).sorted() == ["admin", "session"])

            func cookieSent(_ item: RequestItem) async throws -> String? {
                let result = await executor.run(item, in: collection, state: &state)
                return try JSONDecoder().decode(Echo.self, from: try #require(result.response).body).headers["cookie"]
            }
            do {
                let value = try await cookieSent(home)
                #expect(value == "session=abc123")
            }
            do {
                let value = try await cookieSent(admin)
                #expect(value == "admin=1; session=abc123")
            }
            // A Cookie header written on the request is left alone.
            do {
                let value = try await cookieSent(own)
                #expect(value == "mine=1")
            }
        }
    }
}

@Suite struct GraphQLSchemas {
    let introspection = """
    { "data": { "__schema": {
      "queryType": { "name": "Query" }, "mutationType": { "name": "Mutation" }, "subscriptionType": null,
      "types": [
        { "kind": "OBJECT", "name": "Query", "description": "Root", "fields": [
          { "name": "pet", "description": "One pet", "args": [ { "name": "id", "defaultValue": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "SCALAR", "name": "ID" } } } ],
            "type": { "kind": "OBJECT", "name": "Pet" } },
          { "name": "pets", "description": null, "args": [ { "name": "first", "defaultValue": "10", "type": { "kind": "SCALAR", "name": "Int" } } ],
            "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "LIST", "name": null, "ofType": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "OBJECT", "name": "Pet" } } } } } ] },
        { "kind": "OBJECT", "name": "Pet", "description": null, "fields": [ { "name": "name", "description": null, "args": [], "type": { "kind": "SCALAR", "name": "String" } } ] },
        { "kind": "ENUM", "name": "Species", "description": null, "enumValues": [ { "name": "DOG" }, { "name": "CAT" } ] },
        { "kind": "INPUT_OBJECT", "name": "NewPet", "description": null, "inputFields": [ { "name": "name", "description": null, "defaultValue": null, "type": { "kind": "NON_NULL", "name": null, "ofType": { "kind": "SCALAR", "name": "String" } } } ] },
        { "kind": "OBJECT", "name": "__Schema", "description": null, "fields": [] }
      ] } } }
    """

    @Test func parsesTypesFieldsAndSignatures() throws {
        let schema = try GraphQL.parseSchema(Data(introspection.utf8))
        #expect(schema.queryType == "Query")
        #expect(schema.mutationType == "Mutation")
        #expect(schema.subscriptionType == nil)
        #expect(schema.types.map(\.name) == ["NewPet", "Pet", "Query", "Species"])

        let query = try #require(schema.type(named: schema.queryType))
        #expect(query.fields.map(\.signature) == ["pet(id: ID!): Pet", "pets(first: Int): [Pet!]!"])
        #expect(query.fields[0].description == "One pet")
        #expect(query.fields[1].arguments[0].defaultValue == "10")
        #expect(schema.type(named: "Species")?.enumValues == ["DOG", "CAT"])
        #expect(schema.type(named: "NewPet")?.fields.map(\.signature) == ["name: String!"])
    }

    @Test func explainsWhenThereIsNoSchema() {
        #expect(throws: GraphQLError.notASchema("Introspection is disabled")) {
            try GraphQL.parseSchema(Data("{\"errors\": [{\"message\": \"Introspection is disabled\"}]}".utf8))
        }
        #expect(throws: GraphQLError.notASchema("The response was not JSON.")) {
            try GraphQL.parseSchema(Data("<html>".utf8))
        }
    }

    @Test func introspectionRequestKeepsURLAndAuth() throws {
        let original = PreparedRequest(method: "GET", url: "https://api.example.com/graphql", headers: [
            HTTPHeader(name: "Authorization", value: "Bearer t"), HTTPHeader(name: "content-type", value: "text/plain"),
        ], body: Data("old".utf8))
        let request = GraphQL.introspectionRequest(from: original)
        #expect(request.method == "POST")
        #expect(request.url == original.url)
        #expect(request.header("Authorization") == "Bearer t")
        #expect(request.headers.filter { $0.name.lowercased() == "content-type" }.map(\.value) == ["application/json"])
        let data = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body["query"]?.contains("__schema") == true)
    }
}

@Suite struct OAuth2Flows {
    let resolver = VariableResolver(scopes: [["secret": "s3cret", "host": "auth.example.com"]])

    @Test func clientCredentialsRequest() throws {
        let config = OAuth2Config(tokenURL: "https://{{host}}/token", clientID: "app", clientSecret: "{{secret}}", scope: "read write")
        let request = try OAuth2.tokenRequest(config, resolver: resolver)
        #expect(request.method == "POST")
        #expect(request.url == "https://auth.example.com/token")
        #expect(request.header("Authorization") == "Basic " + Data("app:s3cret".utf8).base64EncodedString())
        #expect(String(decoding: try #require(request.body), as: UTF8.self) == "grant_type=client_credentials&scope=read+write")

        var inBody = config
        inBody.clientAuthInBody = true
        let bodyRequest = try OAuth2.tokenRequest(inBody, resolver: resolver)
        #expect(bodyRequest.header("Authorization") == nil)
        #expect(String(decoding: try #require(bodyRequest.body), as: UTF8.self) == "grant_type=client_credentials&scope=read+write&client_id=app&client_secret=s3cret")

        #expect(throws: OAuth2Error.missing("a token URL")) { try OAuth2.tokenRequest(OAuth2Config(), resolver: resolver) }
    }

    @Test func passwordAndCodeRequests() throws {
        let password = OAuth2Config(grant: .password, tokenURL: "https://a.example/token", clientID: "app", username: "guy", password: "p w")
        #expect(String(decoding: try #require(try OAuth2.tokenRequest(password, resolver: resolver).body), as: UTF8.self)
                == "grant_type=password&username=guy&password=p+w&client_id=app")

        let code = OAuth2Config(grant: .authorizationCode, tokenURL: "https://a.example/token", clientID: "app")
        #expect(throws: OAuth2Error.needsSignIn) { try OAuth2.tokenRequest(code, resolver: resolver) }
        let exchange = try OAuth2.tokenRequest(code, resolver: resolver, code: "c0de", codeVerifier: "ver")
        #expect(String(decoding: try #require(exchange.body), as: UTF8.self)
                == "grant_type=authorization_code&code=c0de&redirect_uri=apiplayground%3A%2F%2Foauth%2Fcallback&code_verifier=ver&client_id=app")
    }

    @Test func authorizationURLAndCallback() throws {
        let config = OAuth2Config(grant: .authorizationCode, authURL: "https://{{host}}/authorize?tenant=1", clientID: "app", scope: "openid profile")
        let pkce = OAuth2.pkce()
        #expect(pkce.verifier.count >= 43)
        #expect(pkce.challenge == OAuth2.challenge(for: pkce.verifier))
        // The published example from the PKCE specification (RFC 7636, appendix B).
        #expect(OAuth2.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")

        let url = try OAuth2.authorizationURL(config, resolver: resolver, state: "st8", codeChallenge: "chal")
        #expect(url.absoluteString == "https://auth.example.com/authorize?tenant=1&response_type=code&client_id=app&redirect_uri=apiplayground%3A%2F%2Foauth%2Fcallback&scope=openid%20profile&state=st8&code_challenge=chal&code_challenge_method=S256")

        #expect(try OAuth2.code(fromCallback: URL(string: "apiplayground://oauth/callback?code=abc&state=st8")!, expectedState: "st8") == "abc")
        #expect(throws: OAuth2Error.stateMismatch) {
            try OAuth2.code(fromCallback: URL(string: "apiplayground://oauth/callback?code=abc&state=other")!, expectedState: "st8")
        }
        #expect(throws: OAuth2Error.server("access_denied: Nope")) {
            try OAuth2.code(fromCallback: URL(string: "apiplayground://oauth/callback?error=access_denied&error_description=Nope")!, expectedState: "st8")
        }
    }

    @Test func tokenParsing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let token = try OAuth2.parseToken(makeResponse(body: "{\"access_token\": \"abc\", \"expires_in\": 60, \"refresh_token\": \"r\", \"scope\": \"read\"}"), now: now)
        #expect(token == OAuth2Token(accessToken: "abc", refreshToken: "r", expiresAt: now.addingTimeInterval(60), scope: "read"))
        #expect(!token.isExpired(now: now))
        #expect(token.isExpired(now: now.addingTimeInterval(31)))
        #expect(!OAuth2Token(accessToken: "x").isExpired())

        #expect(throws: OAuth2Error.server("invalid_client: Bad secret")) {
            try OAuth2.parseToken(makeResponse(status: 401, body: "{\"error\": \"invalid_client\", \"error_description\": \"Bad secret\"}"))
        }
        #expect(throws: OAuth2Error.noToken) { try OAuth2.parseToken(makeResponse(body: "{}")) }
        #expect(throws: OAuth2Error.server("HTTP 500 Oops")) { try OAuth2.parseToken(makeResponse(status: 500, statusText: "Oops", body: "nope")) }
    }

    @Test func aRequestFetchesReusesAndRefreshesItsToken() async throws {
        try await withEchoServer { base in
            let secrets = InMemorySecretStore()
            let tokens = OAuth2TokenStore(secrets: secrets)
            let config = OAuth2Config(tokenURL: "\(base)/token", clientID: "app", clientSecret: "s3cret")
            let request = RequestItem(name: "Me", url: "\(base)/me")
            let collection = APICollection(auth: .oauth2(config), items: [.request(request)])
            let executor = RequestExecutor(tokens: tokens)
            var state = RunState()

            func authorization() async throws -> String? {
                let result = await executor.run(request, in: collection, state: &state)
                #expect(result.error == nil, "\(result.error ?? "")")
                return try JSONDecoder().decode(Echo.self, from: try #require(result.response).body).headers["authorization"]
            }
            // Fetched automatically on first use, then reused rather than fetched again.
            do {
                let value = try await authorization()
                #expect(value == "Bearer tok-1")
            }
            do {
                let value = try await authorization()
                #expect(value == "Bearer tok-1")
            }
            // The token is in the secret store, not in the collection.
            #expect(secrets.get("oauth2/\(config.id.uuidString)")?.contains("tok-1") == true)

            // Once expired, the refresh token is used.
            var expired = try #require(tokens.token(for: config.id))
            expired.expiresAt = Date().addingTimeInterval(-10)
            tokens.save(expired, for: config.id)
            do {
                let value = try await authorization()
                #expect(value == "Bearer refreshed")
            }
            #expect(tokens.token(for: config.id)?.refreshToken == "r-1")

            // A custom prefix replaces "Bearer".
            var custom = config
            custom.headerPrefix = "Token"
            let customCollection = APICollection(auth: .oauth2(custom), items: [.request(request)])
            let result = await executor.run(request, in: customCollection, state: &state)
            #expect(try JSONDecoder().decode(Echo.self, from: try #require(result.response).body).headers["authorization"] == "Token refreshed")
        }
    }

    @Test func failuresAreReportedOnTheRequest() async throws {
        try await withEchoServer { base in
            let request = RequestItem(name: "Me", url: "\(base)/me")
            var state = RunState()
            let executor = RequestExecutor(tokens: OAuth2TokenStore(secrets: InMemorySecretStore()))

            let bad = APICollection(auth: .oauth2(OAuth2Config(tokenURL: "\(base)/token", clientID: "app", clientSecret: "wrong")), items: [.request(request)])
            let refused = await executor.run(request, in: bad, state: &state)
            #expect(refused.error?.contains("invalid_client: Bad secret") == true)
            #expect(refused.response == nil)

            let interactive = APICollection(auth: .oauth2(OAuth2Config(grant: .authorizationCode, tokenURL: "\(base)/token", authURL: "\(base)/authorize", clientID: "app")), items: [.request(request)])
            let needsSignIn = await executor.run(request, in: interactive, state: &state)
            #expect(needsSignIn.error?.contains("Get Token") == true)
        }
    }

    @Test func postmanOAuth2IsImportedAndRoundTrips() throws {
        let json = """
        { "info": { "name": "O", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "auth": { "type": "oauth2", "oauth2": [
            { "key": "accessTokenUrl", "value": "https://a.example/token" }, { "key": "authUrl", "value": "https://a.example/auth" },
            { "key": "clientId", "value": "{{clientId}}" }, { "key": "clientSecret", "value": "{{clientSecret}}" },
            { "key": "scope", "value": "read" }, { "key": "grant_type", "value": "authorization_code_with_pkce" },
            { "key": "client_authentication", "value": "body" }, { "key": "accessToken", "value": "should-not-be-imported" } ] },
          "item": [ { "name": "R", "request": { "method": "GET", "url": "https://api.example/r" } } ] }
        """
        guard case .collection(let collection, let report) = try PostmanImporter.importDocument(data: Data(json.utf8)),
              case .oauth2(let config) = collection.auth else {
            Issue.record("expected an OAuth 2 collection")
            return
        }
        #expect(report.warnings.isEmpty)
        #expect(config.grant == .authorizationCode)
        #expect(config.usePKCE)
        #expect(config.tokenURL == "https://a.example/token")
        #expect(config.authURL == "https://a.example/auth")
        #expect(config.clientID == "{{clientId}}")
        #expect(config.clientAuthInBody)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apiplayground-oauth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(root: root, secrets: InMemorySecretStore())
        try store.save(collection)
        #expect(try store.loadCollections() == [collection])
        let text = try String(contentsOf: root.appendingPathComponent("collections/o/collection.json"), encoding: .utf8)
        #expect(!text.contains("should-not-be-imported"))
    }
}

/// A WebSocket server on localhost that answers each text message with "echo: " and the message.
final class WebSocketEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ws-echo")
    private(set) var port: UInt16 = 0

    init() throws {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Collector<Bool>()
            listener.stateUpdateHandler = { [self] state in
                guard resumed.all.isEmpty else { return }
                switch state {
                case .ready:
                    resumed.add(true)
                    port = listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    resumed.add(true)
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, context, _, error in
            guard error == nil, let context,
                  let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                connection.cancel()
                return
            }
            if metadata.opcode == .text, let data {
                let text = String(decoding: data, as: UTF8.self)
                if text == "bye" {
                    let close = NWProtocolWebSocket.Metadata(opcode: .close)
                    close.closeCode = .protocolCode(.normalClosure)
                    connection.send(content: nil, contentContext: NWConnection.ContentContext(identifier: "close", metadata: [close]), completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let reply = NWConnection.ContentContext(identifier: "reply", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                connection.send(content: Data("echo: \(text)".utf8), contentContext: reply, completion: .contentProcessed { _ in })
            } else if metadata.opcode == .close {
                connection.cancel()
                return
            }
            receive(on: connection)
        }
    }
}

@Suite struct WebSockets {
    @Test func recognisesWebSocketURLs() {
        #expect(WebSocketClient.isWebSocketURL("ws://localhost:8080/chat"))
        #expect(WebSocketClient.isWebSocketURL(" WSS://example.com"))
        #expect(!WebSocketClient.isWebSocketURL("https://example.com"))
        #expect(!WebSocketClient.isWebSocketURL("{{base}}/ws"))
    }

    @Test func connectsSendsReceivesAndCloses() async throws {
        let server = try WebSocketEchoServer()
        try await server.start()
        defer { server.stop() }

        let events = Collector<WebSocketEvent>()
        let client = WebSocketClient { events.add($0) }
        client.connect(url: URL(string: "ws://127.0.0.1:\(server.port)/chat")!, headers: [HTTPHeader(name: "X-Test", value: "1")])

        func wait(_ what: String, until condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("timed out waiting for \(what)")
        }
        func received() -> [String] {
            events.all.compactMap { if case .message(let message) = $0 { return message.text } else { return nil } }
        }
        func isConnected() -> Bool { events.all.contains { if case .connected = $0 { return true } else { return false } } }
        func isClosed() -> Bool { events.all.contains { if case .closed = $0 { return true } else if case .failed = $0 { return true } else { return false } } }

        try await wait("connection") { isConnected() }
        try await client.send("hello")
        try await client.send("{\"type\": \"ping\"}")
        try await wait("two replies") { received().count == 2 }
        #expect(received() == ["echo: hello", "echo: {\"type\": \"ping\"}"])

        // The server closes when asked, and the client reports it once.
        try await client.send("bye")
        try await wait("close") { isClosed() }
        let endings = events.all.filter { if case .closed = $0 { return true } else if case .failed = $0 { return true } else { return false } }
        #expect(endings.count == 1)
    }

    @Test func reportsAFailedConnection() async throws {
        let events = Collector<WebSocketEvent>()
        let client = WebSocketClient { events.add($0) }
        client.connect(url: URL(string: "ws://127.0.0.1:1/")!)
        for _ in 0..<200 {
            if !events.all.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .failed = try #require(events.all.first) else {
            Issue.record("expected a failure")
            return
        }
    }
}

private let nodeForSockets = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }

/// A WebSocket over TLS, against a Node server that asks for a client certificate and says
/// which one it was shown. Skipped where Node is not installed.
@Suite(.serialized, .enabled(if: nodeForSockets != nil, "Node is needed to run the test WebSocket server"))
struct SecureWebSockets {
    final class SecureSocketServer {
        let folder: URL
        let port: Int
        private let process = Process()

        static func openssl(_ arguments: [String], in folder: URL) throws {
            let tool = Process()
            tool.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            tool.arguments = arguments
            tool.currentDirectoryURL = folder
            tool.standardOutput = FileHandle.nullDevice
            tool.standardError = FileHandle.nullDevice
            try tool.run()
            tool.waitUntilExit()
        }

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("wss-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key", "-out", "server.pem", "-days", "2", "-subj", "/CN=localhost"], in: folder)
            try Self.openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "client.key", "-out", "client.pem", "-days", "2", "-subj", "/CN=socket client"], in: folder)
            try Self.openssl(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-out", "client.p12", "-passout", "pass:secret"], in: folder)

            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Support/wss-test-server.js")
            process.executableURL = URL(fileURLWithPath: nodeForSockets!)
            process.arguments = [script.path, folder.appendingPathComponent("server.key").path, folder.appendingPathComponent("server.pem").path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            var text = ""
            while !text.contains("\n") {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                text += String(decoding: chunk, as: UTF8.self)
            }
            port = Int(text.replacingOccurrences(of: "PORT ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        func path(_ name: String) -> String { folder.appendingPathComponent(name).path }
        var url: URL { URL(string: "wss://localhost:\(port)/")! }

        deinit {
            process.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Connects and returns the first thing that happens after the handshake: the server's
    /// greeting, or the reason the connection failed.
    private func firstWord(_ server: SecureSocketServer, _ options: WebSocketOptions) async throws -> String {
        let events = Collector<WebSocketEvent>()
        let client = WebSocketClient { events.add($0) }
        client.connect(url: server.url, options: options)
        defer { client.close() }
        for _ in 0..<300 {
            for event in events.all {
                if case .message(let message) = event { return message.text }
                if case .failed(let reason) = event { return "failed: \(reason)" }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return "timed out"
    }

    @Test func aSelfSignedServerIsRefusedUnlessCheckingIsOff() async throws {
        let server = try SecureSocketServer()
        #expect(try await firstWord(server, WebSocketOptions()).hasPrefix("failed:"))
        #expect(try await firstWord(server, WebSocketOptions(verifyTLS: false)) == "client: none")
    }

    @Test func presentsAClientCertificateFromPEMFilesOrPKCS12() async throws {
        guard #available(macOS 15.0, *) else { return }
        let server = try SecureSocketServer()
        let pem = ClientCertificate(certificatePath: server.path("client.pem"), keyPath: server.path("client.key"))
        #expect(try await firstWord(server, WebSocketOptions(verifyTLS: false, clientCertificate: pem)) == "client: socket client")

        let bundle = ClientCertificate(certificatePath: server.path("client.p12"), passphrase: "secret")
        #expect(try await firstWord(server, WebSocketOptions(verifyTLS: false, clientCertificate: bundle)) == "client: socket client")

        let wrong = ClientCertificate(certificatePath: server.path("client.p12"), passphrase: "wrong")
        #expect(try await firstWord(server, WebSocketOptions(verifyTLS: false, clientCertificate: wrong)).hasPrefix("failed:"))
    }

    @Test func aProxyAddressBecomesTheSettingsTheSystemTakes() {
        let http = WebSocketClient.proxyDictionary(ProxySettings(enabled: true, url: "proxy.test:3128"))
        #expect(http?["HTTPSProxy"] as? String == "proxy.test")
        #expect(http?["HTTPSPort"] as? Int == 3128)
        let socks = WebSocketClient.proxyDictionary(ProxySettings(enabled: true, url: "socks5://127.0.0.1"))
        #expect(socks?["SOCKSProxy"] as? String == "127.0.0.1")
        #expect(socks?["SOCKSPort"] as? Int == 1080)
    }
}
