import Foundation
import JavaScriptCore

public enum ScriptPhase: String, Sendable {
    case preRequest = "prerequest"
    case test = "test"
}

/// The request as a script sees it. A pre-request script may change the headers and raw body.
public struct ScriptRequest: Codable, Equatable, Sendable {
    public struct Header: Codable, Equatable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var method: String
    public var url: String
    public var headers: [Header]
    public var body: String

    public init(method: String, url: String, headers: [Header] = [], body: String = "") {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct ScriptOutcome: Equatable, Sendable {
    public var tests: [TestResult] = []
    /// Lines written with `console.log` and friends.
    public var logs: [String] = []
    /// Set when a script threw outside of a `pm.test`, or could not be parsed.
    public var error: String?
    /// Set when a pre-request script called `pm.execution.skipRequest()`.
    public var skipRequest = false
}

/// Runs Postman-style scripts in JavaScriptCore, with a `pm` object covering the commonly used
/// parts of Postman's: variables, `pm.request`, `pm.response`, `pm.test` and `pm.expect`.
public enum ScriptRunner {

    private struct Host: Codable {
        struct Response: Codable {
            var code: Int
            var status: String
            var headers: [ScriptRequest.Header]
            var body: String
            var responseTime: Int
            var responseSize: Int
        }

        struct Info: Codable {
            var eventName: String
            var requestName: String
        }

        var globals: [String: String]
        var collection: [String: String]
        var environment: [String: String]
        var locals: [String: String]
        var request: ScriptRequest
        var response: Response?
        var info: Info
    }

    private struct Export: Codable {
        var globals: [String: String]
        var collection: [String: String]
        var environment: [String: String]
        var locals: [String: String]
        var request: ScriptRequest
        var tests: [TestResult]
        var logs: [String]
        var skipRequest: Bool
    }

    /// Runs the scripts in order, as Postman does: collection first, then folders, then the request.
    public static func run(
        scripts: [String],
        phase: ScriptPhase,
        requestName: String,
        state: inout RunState,
        request: inout ScriptRequest,
        response: HTTPResponse? = nil
    ) -> ScriptOutcome {
        var outcome = ScriptOutcome()
        let scripts = scripts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !scripts.isEmpty else { return outcome }

        let before = (
            globals: RunState.dictionary(state.globals),
            collection: RunState.dictionary(state.collectionVariables),
            environment: RunState.dictionary(state.environment)
        )
        let host = Host(
            globals: before.globals,
            collection: before.collection,
            environment: before.environment,
            locals: state.locals,
            request: request,
            response: response.map {
                Host.Response(
                    code: $0.status,
                    status: $0.statusText,
                    headers: $0.headers.map { ScriptRequest.Header(key: $0.name, value: $0.value) },
                    body: $0.text ?? "",
                    responseTime: Int(($0.timings.total * 1000).rounded()),
                    responseSize: $0.body.count
                )
            },
            info: Host.Info(eventName: phase.rawValue, requestName: requestName)
        )

        guard let context = JSContext(),
              let hostData = try? JSONEncoder().encode(host),
              let hostJSON = String(data: hostData, encoding: .utf8) else {
            outcome.error = "Could not start the script engine."
            return outcome
        }

        var thrown: String?
        context.exceptionHandler = { _, exception in
            guard let exception else { return }
            var message = exception.toString() ?? "Script error"
            if let line = exception.objectForKeyedSubscript("line"), line.isNumber {
                // Each script is wrapped in one extra line, so the reported line is one too high.
                message += " (line \(max(1, Int(line.toInt32()) - 1)))"
            }
            thrown = message
        }

        context.setObject(hostJSON, forKeyedSubscript: "__hostJSON" as NSString)
        context.evaluateScript(prelude)
        if let thrown {
            outcome.error = "Could not start the script engine: \(thrown)"
            return outcome
        }

        for script in scripts {
            // The wrapper gives each script its own scope, so two scripts can both declare `const x`.
            context.evaluateScript("(function () {\n\(script)\n})();")
            if let thrown {
                outcome.error = thrown
                break
            }
        }

        thrown = nil
        guard let exported = context.evaluateScript("__pm.exportState()")?.toString(),
              let export = try? JSONDecoder().decode(Export.self, from: Data(exported.utf8)) else {
            outcome.error = outcome.error ?? "Could not read the script's results."
            return outcome
        }

        state.apply(before: before.globals, after: export.globals, scope: .globals)
        state.apply(before: before.collection, after: export.collection, scope: .collection)
        state.apply(before: before.environment, after: export.environment, scope: .environment)
        state.locals = export.locals
        request = export.request
        outcome.tests = export.tests
        outcome.logs = export.logs
        outcome.skipRequest = export.skipRequest
        return outcome
    }

    /// Builds `pm` and the legacy globals from the data in `__hostJSON`.
    private static let prelude = #"""
    var __pm = (function (host) {
      'use strict';
      var tests = [], logs = [], skipRequest = false;
      function hasOwn(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }
      function toStr(v) {
        if (v === null || v === undefined) return '';
        if (typeof v === 'string') return v;
        if (typeof v === 'object') { try { return JSON.stringify(v); } catch (e) { return String(v); } }
        return String(v);
      }
      function show(v) {
        if (v && v.__pmResponse) return 'the response';
        var s;
        try {
          if (v === undefined) s = 'undefined';
          else if (typeof v === 'function') s = '[Function]';
          else if (v instanceof RegExp) s = String(v);
          else s = JSON.stringify(v);
        } catch (e) { s = String(v); }
        if (s === undefined) s = String(v);
        return s.length > 120 ? s.slice(0, 117) + '...' : s;
      }

      // ---- variables ----
      function Scope(store) {
        return {
          get: function (k) { return hasOwn(store, k) ? store[k] : undefined; },
          set: function (k, v) { store[String(k)] = toStr(v); },
          unset: function (k) { delete store[k]; },
          has: function (k) { return hasOwn(store, k); },
          clear: function () { Object.keys(store).forEach(function (k) { delete store[k]; }); },
          toObject: function () { return JSON.parse(JSON.stringify(store)); }
        };
      }
      function lookup(k) {
        if (hasOwn(host.locals, k)) return host.locals[k];
        if (hasOwn(host.environment, k)) return host.environment[k];
        if (hasOwn(host.collection, k)) return host.collection[k];
        if (hasOwn(host.globals, k)) return host.globals[k];
        return undefined;
      }
      function replaceIn(text) {
        return String(text).replace(/\{\{\s*([^}]+?)\s*\}\}/g, function (whole, name) {
          var v = lookup(name);
          return v === undefined ? whole : v;
        });
      }
      var variables = Scope(host.locals);
      variables.get = lookup;
      variables.has = function (k) { return lookup(k) !== undefined; };
      variables.replaceIn = replaceIn;
      var environment = Scope(host.environment), globals = Scope(host.globals), collectionVariables = Scope(host.collection);
      environment.replaceIn = globals.replaceIn = collectionVariables.replaceIn = replaceIn;
      environment.name = '';

      // ---- headers ----
      function HeaderList(list) {
        function find(name) {
          name = String(name).toLowerCase();
          for (var i = 0; i < list.length; i++) if (list[i].key.toLowerCase() === name) return list[i];
          return null;
        }
        return {
          get: function (n) { var h = find(n); return h ? h.value : undefined; },
          has: function (n) { return !!find(n); },
          add: function (h) { list.push({ key: String(h.key), value: toStr(h.value) }); },
          upsert: function (h) {
            var e = find(h.key);
            if (e) e.value = toStr(h.value); else list.push({ key: String(h.key), value: toStr(h.value) });
          },
          remove: function (n) {
            n = String(n).toLowerCase();
            for (var i = list.length - 1; i >= 0; i--) if (list[i].key.toLowerCase() === n) list.splice(i, 1);
          },
          each: function (fn) { list.forEach(fn); },
          all: function () { return list.slice(); },
          toObject: function () { var o = {}; list.forEach(function (h) { o[h.key] = h.value; }); return o; },
          count: function () { return list.length; }
        };
      }

      // ---- request and response ----
      var req = host.request;
      var urlObject = {
        toString: function () { return replaceIn(req.url); },
        getRaw: function () { return req.url; },
        getHost: function () { var m = /^[a-z][a-z0-9+.-]*:\/\/([^\/:?#]+)/i.exec(replaceIn(req.url)); return m ? m[1] : ''; },
        getPath: function () { var m = /^[a-z][a-z0-9+.-]*:\/\/[^\/?#]*([^?#]*)/i.exec(replaceIn(req.url)); return m && m[1] ? m[1] : '/'; }
      };
      var bodyObject = { mode: 'raw', toString: function () { return req.body; } };
      Object.defineProperty(bodyObject, 'raw', {
        get: function () { return req.body; },
        set: function (v) { req.body = toStr(v); },
        enumerable: true
      });
      var request = { method: req.method, url: urlObject, headers: HeaderList(req.headers), body: bodyObject, name: host.info.requestName };

      var res = host.response, response;
      if (res) {
        response = {
          __pmResponse: true,
          code: res.code,
          status: res.status,
          responseTime: res.responseTime,
          responseSize: res.responseSize,
          headers: HeaderList(res.headers),
          text: function () { return res.body; },
          json: function () { return JSON.parse(res.body); }
        };
        Object.defineProperty(response, 'to', { get: function () { return makeExpect(response).to; } });
      }

      // ---- expect ----
      function fail(msg) { var e = new Error(msg); e.name = 'AssertionError'; throw e; }
      function typeOf(v) {
        if (v === null) return 'null';
        if (Array.isArray(v)) return 'array';
        if (v instanceof RegExp) return 'regexp';
        if (v instanceof Date) return 'date';
        return typeof v;
      }
      function deepEqual(a, b) {
        if (a === b) return true;
        if (a !== a && b !== b) return true;
        if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
        if (Array.isArray(a) !== Array.isArray(b)) return false;
        var ka = Object.keys(a), kb = Object.keys(b);
        if (ka.length !== kb.length) return false;
        for (var i = 0; i < ka.length; i++) {
          if (!hasOwn(b, ka[i]) || !deepEqual(a[ka[i]], b[ka[i]])) return false;
        }
        return true;
      }
      function makeExpect(value, message) {
        var negate = false, deep = false, any = false;
        var self = {};
        var isResponse = !!(value && value.__pmResponse);
        function assert(ok, what) {
          if (negate ? ok : !ok) fail((message ? message + ': ' : '') + 'expected ' + show(value) + (negate ? ' not ' : ' ') + what);
          return self;
        }
        function getter(name, fn) { Object.defineProperty(self, name, { get: fn, configurable: true }); }
        ['to', 'be', 'been', 'is', 'that', 'which', 'and', 'has', 'have', 'with', 'at', 'of', 'same', 'but', 'does', 'still', 'also', 'all', 'itself']
          .forEach(function (w) { getter(w, function () { return self; }); });
        getter('not', function () { negate = !negate; return self; });
        getter('deep', function () { deep = true; return self; });
        getter('any', function () { any = true; return self; });

        function code(test, what) { return assert(test(value.code), what + ' (was ' + value.code + ')'); }
        getter('ok', function () {
          return isResponse ? code(function (c) { return c === 200; }, 'to have status 200') : assert(!!value, 'to be truthy');
        });
        getter('true', function () { return assert(value === true, 'to be true'); });
        getter('false', function () { return assert(value === false, 'to be false'); });
        getter('null', function () { return assert(value === null, 'to be null'); });
        getter('undefined', function () { return assert(value === undefined, 'to be undefined'); });
        getter('NaN', function () { return assert(value !== value, 'to be NaN'); });
        getter('exist', function () { return assert(value !== null && value !== undefined, 'to exist'); });
        getter('empty', function () {
          var n = (typeof value === 'string' || Array.isArray(value)) ? value.length : Object.keys(Object(value)).length;
          return assert(n === 0, 'to be empty');
        });

        self.equal = self.equals = self.eq = function (v) {
          return assert(deep ? deepEqual(value, v) : value === v, 'to ' + (deep ? 'deeply ' : '') + 'equal ' + show(v));
        };
        self.eql = self.eqls = function (v) { return assert(deepEqual(value, v), 'to deeply equal ' + show(v)); };
        self.a = self.an = function (t) {
          return assert(typeOf(value) === String(t).toLowerCase(), 'to be of type ' + t + ' (was ' + typeOf(value) + ')');
        };
        self.include = self.includes = self.contain = self.contains = function (v) {
          var ok = false;
          if (typeof value === 'string') ok = value.indexOf(v) !== -1;
          else if (Array.isArray(value)) ok = value.some(function (x) { return deep ? deepEqual(x, v) : x === v; });
          else if (value && typeof value === 'object' && v && typeof v === 'object') {
            ok = Object.keys(v).every(function (k) { return deepEqual(value[k], v[k]); });
          }
          return assert(ok, 'to include ' + show(v));
        };
        self.above = self.gt = self.greaterThan = function (n) { return assert(value > n, 'to be above ' + show(n)); };
        self.least = self.gte = self.greaterThanOrEqual = function (n) { return assert(value >= n, 'to be at least ' + show(n)); };
        self.below = self.lt = self.lessThan = function (n) { return assert(value < n, 'to be below ' + show(n)); };
        self.most = self.lte = self.lessThanOrEqual = function (n) { return assert(value <= n, 'to be at most ' + show(n)); };
        self.within = function (a, b) { return assert(value >= a && value <= b, 'to be within ' + show(a) + '..' + show(b)); };
        self.closeTo = self.approximately = function (n, delta) {
          return assert(Math.abs(value - n) <= delta, 'to be close to ' + show(n) + ' +/- ' + show(delta));
        };
        self.property = function (name, v) {
          var has = value !== null && value !== undefined && (name in Object(value));
          if (arguments.length > 1) {
            assert(has && (deep ? deepEqual(value[name], v) : value[name] === v), 'to have property ' + show(name) + ' of ' + show(v));
          } else {
            assert(has, 'to have property ' + show(name));
          }
          return (has && !negate) ? makeExpect(value[name], message) : self;
        };
        self.lengthOf = function (n) {
          var len = (value === null || value === undefined) ? undefined : value.length;
          return assert(len === n, 'to have length ' + n + ' (was ' + len + ')');
        };
        self.match = self.matches = function (re) { return assert(re.test(value), 'to match ' + String(re)); };
        self.string = function (s) { return assert(typeof value === 'string' && value.indexOf(s) !== -1, 'to contain ' + show(s)); };
        self.oneOf = function (list) {
          return assert(list.some(function (x) { return deep ? deepEqual(x, value) : x === value; }), 'to be one of ' + show(list));
        };
        self.keys = self.key = function () {
          var want = Array.isArray(arguments[0]) ? arguments[0] : Array.prototype.slice.call(arguments);
          var have = Object.keys(Object(value));
          function present(k) { return have.indexOf(k) !== -1; }
          return assert(any ? want.some(present) : want.every(present), 'to have keys ' + show(want));
        };
        self.members = function (list) {
          var ok = Array.isArray(value) && value.length === list.length &&
            list.every(function (x) { return value.some(function (y) { return deepEqual(x, y); }); });
          return assert(ok, 'to have the same members as ' + show(list));
        };
        self.satisfy = self.satisfies = function (fn) { return assert(!!fn(value), 'to satisfy the given function'); };
        self.throw = self.throws = function () {
          var threw = false;
          try { value(); } catch (e) { threw = true; }
          return assert(threw, 'to throw');
        };

        if (isResponse) {
          self.status = function (s) {
            var ok = typeof s === 'number' ? value.code === s : value.status === s;
            return assert(ok, 'to have status ' + s + ' (was ' + value.code + ' ' + value.status + ')');
          };
          self.header = function (name, v) {
            var actual = value.headers.get(name);
            if (arguments.length > 1) return assert(actual === v, 'to have header ' + name + ' of ' + show(v) + ' (was ' + show(actual) + ')');
            return assert(actual !== undefined, 'to have header ' + name);
          };
          self.body = function (b) {
            var text = value.text();
            if (arguments.length === 0) return assert(text.length > 0, 'to have a body');
            if (b instanceof RegExp) return assert(b.test(text), 'to have a body matching ' + String(b));
            return assert(text === b, 'to have body ' + show(b));
          };
          self.jsonBody = function () {
            var ok = true;
            try { JSON.parse(value.text()); } catch (e) { ok = false; }
            return assert(ok, 'to have a JSON body');
          };
          var ranges = {
            info: [100, 199], success: [200, 299], redirection: [300, 399],
            clientError: [400, 499], serverError: [500, 599], error: [400, 599]
          };
          Object.keys(ranges).forEach(function (name) {
            getter(name, function () {
              return code(function (c) { return c >= ranges[name][0] && c <= ranges[name][1]; }, 'to be ' + name);
            });
          });
          var exact = { accepted: 202, badRequest: 400, unauthorized: 401, forbidden: 403, notFound: 404, rateLimited: 429 };
          Object.keys(exact).forEach(function (name) {
            getter(name, function () { return code(function (c) { return c === exact[name]; }, 'to have status ' + exact[name]); });
          });
          getter('json', function () { return self.jsonBody(); });
          getter('withBody', function () { return self.body(); });
        }
        return self;
      }

      // ---- pm ----
      function unsupported(name) { return function () { throw new Error(name + ' is not supported yet'); }; }
      function test(name, fn) {
        try {
          if (typeof fn === 'function') fn(function () {});
          tests.push({ name: String(name), passed: true, skipped: false });
        } catch (e) {
          tests.push({ name: String(name), passed: false, skipped: false, message: String((e && e.message) || e) });
        }
        return pm;
      }
      test.skip = function (name) { tests.push({ name: String(name), passed: true, skipped: true }); return pm; };

      var pm = {
        variables: variables,
        environment: environment,
        globals: globals,
        collectionVariables: collectionVariables,
        iterationData: { get: function () { return undefined; }, has: function () { return false; }, toObject: function () { return {}; } },
        request: request,
        response: response,
        info: { eventName: host.info.eventName, requestName: host.info.requestName, iteration: 0, iterationCount: 1 },
        test: test,
        expect: function (value, message) { return makeExpect(value, message); },
        sendRequest: unsupported('pm.sendRequest'),
        cookies: { get: function () { return undefined; }, has: function () { return false; }, toObject: function () { return {}; } },
        execution: {
          skipRequest: function () { skipRequest = true; },
          setNextRequest: unsupported('pm.execution.setNextRequest')
        }
      };

      return {
        pm: pm,
        log: function (level, args) {
          logs.push((level === 'log' ? '' : level + ': ') + Array.prototype.map.call(args, function (a) {
            return typeof a === 'string' ? a : show(a);
          }).join(' '));
        },
        legacyTests: {},
        exportState: function () {
          var legacy = this.legacyTests;
          Object.keys(legacy).forEach(function (name) {
            tests.push({ name: name, passed: !!legacy[name], skipped: false });
          });
          this.legacyTests = {};
          return JSON.stringify({
            globals: host.globals, collection: host.collection, environment: host.environment, locals: host.locals,
            request: host.request, tests: tests, logs: logs, skipRequest: skipRequest
          });
        },
        response: res,
        host: host
      };
    })(JSON.parse(__hostJSON));

    var pm = __pm.pm;
    var console = {};
    ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
      console[level] = function () { __pm.log(level, arguments); };
    });

    // Insomnia's scripts use the same API under another name.
    var insomnia = pm;

    // Bruno's API, for scripts imported from it: bru, req, res, and test and expect as globals.
    var test = pm.test;
    var expect = pm.expect;
    var bru = (function () {
      function no(name) { return function () { throw new Error('bru.' + name + ' is not supported yet'); }; }
      // Bruno's runtime variables last between requests. A collection variable set by a script
      // does too, and its value stays on this Mac.
      return {
        getVar: function (k) { return pm.variables.get(k); },
        setVar: function (k, v) { pm.collectionVariables.set(k, v); },
        hasVar: function (k) { return pm.variables.has(k); },
        deleteVar: function (k) { pm.collectionVariables.unset(k); },
        getEnvVar: function (k) { return pm.environment.get(k); },
        setEnvVar: function (k, v) { pm.environment.set(k, v); },
        hasEnvVar: function (k) { return pm.environment.has(k); },
        deleteEnvVar: function (k) { pm.environment.unset(k); },
        getGlobalEnvVar: function (k) { return pm.globals.get(k); },
        setGlobalEnvVar: function (k, v) { pm.globals.set(k, v); },
        getCollectionVar: function (k) { return pm.collectionVariables.get(k); },
        getFolderVar: function (k) { return pm.variables.get(k); },
        getRequestVar: function (k) { return pm.variables.get(k); },
        getProcessEnv: function () { return undefined; },
        getEnvName: function () { return pm.environment.name; },
        getCollectionName: function () { return undefined; },
        interpolate: function (text) { return typeof text === 'string' ? pm.variables.replaceIn(text) : text; },
        cwd: function () { return ''; },
        sleep: no('sleep'),
        setNextRequest: no('setNextRequest'),
        runRequest: no('runRequest'),
        sendRequest: no('sendRequest'),
        runner: { skipRequest: function () { pm.execution.skipRequest(); }, stopExecution: no('runner.stopExecution'), setNextRequest: no('runner.setNextRequest') }
      };
    })();
    var req = (function () {
      var r = __pm.host.request;
      function parsed(text) { try { return JSON.parse(text); } catch (e) { return text; } }
      var self = {
        getUrl: function () { return r.url; },
        setUrl: function (u) { r.url = String(u); },
        getMethod: function () { return r.method; },
        setMethod: function (m) { r.method = String(m).toUpperCase(); },
        getName: function () { return pm.info.requestName; },
        getHeader: function (n) { return pm.request.headers.get(n); },
        getHeaders: function () { return pm.request.headers.toObject(); },
        setHeader: function (n, v) { pm.request.headers.upsert({ key: n, value: v }); },
        setHeaders: function (all) { Object.keys(all || {}).forEach(function (n) { self.setHeader(n, all[n]); }); },
        deleteHeader: function (n) { pm.request.headers.remove(n); },
        getBody: function () { return parsed(r.body); },
        setBody: function (b) { r.body = typeof b === 'string' ? b : JSON.stringify(b); },
        setTimeout: function () {},
        setMaxRedirects: function () {}
      };
      ['url', 'method'].forEach(function (name) {
        Object.defineProperty(self, name, { get: function () { return r[name]; }, enumerable: true });
      });
      Object.defineProperty(self, 'headers', { get: function () { return self.getHeaders(); }, enumerable: true });
      Object.defineProperty(self, 'body', { get: function () { return self.getBody(); }, enumerable: true });
      return self;
    })();
    var res = (function () {
      var r = __pm.response;
      if (!r) return undefined;
      var body = r.body;
      try { body = JSON.parse(r.body); } catch (e) {}
      // Bruno gives header names in lower case.
      var headers = {};
      r.headers.forEach(function (h) { headers[h.key.toLowerCase()] = h.value; });
      return {
        status: r.code, statusText: r.status, headers: headers, body: body, responseTime: r.responseTime,
        getStatus: function () { return r.code; },
        getStatusText: function () { return r.status; },
        getHeader: function (n) { return headers[String(n).toLowerCase()]; },
        getHeaders: function () { return headers; },
        getBody: function () { return body; },
        getResponseTime: function () { return r.responseTime; },
        getSize: function () { return { body: r.responseSize, headers: 0, total: r.responseSize }; }
      };
    })();

    // The older "postman" API and its globals, which many saved scripts still use.
    var tests = __pm.legacyTests;
    var postman = {
      setEnvironmentVariable: function (k, v) { pm.environment.set(k, v); },
      getEnvironmentVariable: function (k) { return pm.environment.get(k); },
      clearEnvironmentVariable: function (k) { pm.environment.unset(k); },
      setGlobalVariable: function (k, v) { pm.globals.set(k, v); },
      getGlobalVariable: function (k) { return pm.globals.get(k); },
      clearGlobalVariable: function (k) { pm.globals.unset(k); },
      getResponseHeader: function (k) { return pm.response ? pm.response.headers.get(k) : undefined; },
      setNextRequest: function () { throw new Error('postman.setNextRequest is not supported yet'); }
    };
    if (__pm.response) {
      var responseBody = __pm.response.body;
      var responseCode = { code: __pm.response.code, name: __pm.response.status };
      var responseTime = __pm.response.responseTime;
      var responseHeaders = pm.response.headers.toObject();
    }

    function require(name) { throw new Error("require('" + name + "') is not supported yet"); }

    var btoa = function (input) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      var s = String(input), out = '';
      for (var i = 0; i < s.length; i += 3) {
        var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
        var n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += chars[(n >> 18) & 63] + chars[(n >> 12) & 63] + (isNaN(b) ? '=' : chars[(n >> 6) & 63]) + (isNaN(c) ? '=' : chars[n & 63]);
      }
      return out;
    };
    var atob = function (input) {
      var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      var s = String(input).replace(/=+$/, ''), out = '', bits = 0, acc = 0;
      for (var i = 0; i < s.length; i++) {
        var v = chars.indexOf(s[i]);
        if (v < 0) continue;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); }
      }
      return out;
    };
    """#
}
