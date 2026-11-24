import Foundation

/**
 iOS half of the http.* ops: a plain HTTP client the page drives, so a request
 never goes through WKWebView and is therefore free of CORS, origin checks and
 the browser's list of forbidden headers.

 Nothing here is a browser: no JavaScript, no rendering, no preflight. A page
 that builds its content in script comes back empty.

 Requests run off the main thread and answer through `ShellBridge.answer`,
 which hops back on its own.
 */
final class HttpFetcher: NSObject, URLSessionDataDelegate {

    static let shared = HttpFetcher()

    /// Anything above this is refused instead of filling the heap.
    private static let maxBytes = 16 * 1024 * 1024
    private static let maxRedirects = 5
    private static let defaultTimeoutMs = 30000

    /**
     Headers the HTTP client owns. Setting them by hand either throws or breaks
     the request, so they are dropped silently.
     */
    private static let reserved: Set<String> = [
        "host", "connection", "content-length", "expect", "upgrade",
        "keep-alive", "transfer-encoding", "proxy-connection",
    ]

    /// host -> (cookie name -> value). Memory only: nothing survives a launch.
    private var jar: [String: [String: String]] = [:]
    private let jarLock = NSLock()

    private var buffers: [Int: Data] = [:]
    private var truncated: [Int: Bool] = [:]
    private let bufferLock = NSLock()

    /// One completion per in-flight task, called from `didCompleteWithError`.
    private var done: [Int: (Error?) -> Void] = [:]

    /// Redirects are followed by hand so every hop can be inspected and every
    /// Set-Cookie seen: the delegate refuses to follow them itself.
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    // MARK: - http.fetch

    func fetch(_ id: String?, _ payload: [String: Any], _ bridge: ShellBridge) {
        let url = (payload["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty {
            bridge.answer(id, false, ShellBridge.error("E_BAD_REQUEST", "url is required"))
            return
        }
        if !HttpFetcher.isHttp(url) {
            bridge.answer(id, false, ShellBridge.error("E_BAD_REQUEST", "url must be http or https"))
            return
        }
        let method = (payload["method"] as? String ?? "GET").uppercased()
        let body = payload["body"] as? String ?? ""
        let timeoutMs = payload["timeoutMs"] as? Int ?? HttpFetcher.defaultTimeoutMs
        let headers = payload["headers"] as? [String: Any] ?? [:]
        let useJar = payload["cookies"] as? Bool ?? true

        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try self.get(url, method: method, body: body,
                                       timeoutMs: timeoutMs, headers: headers, useJar: useJar)
                bridge.answer(id, true, data)
            } catch let error as HttpError {
                bridge.answer(id, false, ShellBridge.error(error.code, error.message))
            } catch {
                bridge.answer(id, false,
                              ShellBridge.error("E_UNAVAILABLE", error.localizedDescription))
            }
        }
    }

    private func get(_ url: String, method: String, body: String, timeoutMs: Int,
                     headers: [String: Any], useJar: Bool) throws -> [String: Any] {
        var current = url
        var currentMethod = method
        var currentBody = body

        var hop = 0
        while hop <= HttpFetcher.maxRedirects {
            var request = URLRequest(url: URL(string: current)!)
            request.httpMethod = currentMethod
            request.timeoutInterval = Double(max(timeoutMs, 1000)) / 1000
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            for (name, value) in headers {
                if HttpFetcher.isReserved(name) { continue }
                request.setValue(String(describing: value), forHTTPHeaderField: name)
            }
            if useJar, let cookie = cookieHeader(current), !cookie.isEmpty {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            if !currentBody.isEmpty && currentMethod != "GET" && currentMethod != "HEAD" {
                request.httpBody = currentBody.data(using: .utf8)
            }

            let (response, body, wasTruncated) = try perform(request)
            if useJar {
                storeCookies(current, response)
            }

            let status = response.statusCode
            if HttpFetcher.isRedirect(status),
               let location = response.value(forHTTPHeaderField: "Location"),
               !location.isEmpty {
                guard let next = URL(string: location, relativeTo: URL(string: current)) else {
                    throw HttpError("E_UNAVAILABLE", "bad redirect location")
                }
                current = next.absoluteString
                if !HttpFetcher.isHttp(current) {
                    throw HttpError("E_UNAVAILABLE", "redirected outside http")
                }
                if status == 303 || ((status == 301 || status == 302)
                                     && currentMethod != "GET" && currentMethod != "HEAD") {
                    // 303 always becomes GET; 301/302 in practice do the same.
                    currentMethod = "GET"
                    currentBody = ""
                }
                hop += 1
                continue
            }

            return outcome(response, body: body, truncated: wasTruncated, url: current)
        }
        throw HttpError("E_UNAVAILABLE", "too many redirects")
    }

    // MARK: - one request

    /// Runs one request to completion and hands back its status, body and the
    /// "we cut it at the cap" flag.
    private func perform(_ request: URLRequest) throws -> (HTTPURLResponse, Data, Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        var failure: Error?

        let task = session.dataTask(with: request)
        let key = task.taskIdentifier
        bufferLock.lock()
        buffers[key] = Data()
        truncated[key] = false
        done[key] = { error in
            failure = error
            semaphore.signal()
        }
        bufferLock.unlock()
        task.resume()
        semaphore.wait()

        bufferLock.lock()
        done[key] = nil
        let body = buffers.removeValue(forKey: key) ?? Data()
        let wasTruncated = truncated.removeValue(forKey: key) ?? false
        bufferLock.unlock()

        if let failure = failure as NSError? {
            // A body we cut at the cap cancels the task; that is not a failure.
            let cancelled = failure.domain == NSURLErrorDomain
                && failure.code == NSURLErrorCancelled
            if !(cancelled && wasTruncated) {
                throw HttpError("E_UNAVAILABLE", failure.localizedDescription)
            }
        }
        guard let response = task.response as? HTTPURLResponse else {
            throw HttpError("E_UNAVAILABLE", "no response")
        }
        return (response, body, wasTruncated)
    }

    /// Contract shape: status, final url, headers, body (or base64) and the
    /// "we cut it at the cap" flag.
    private func outcome(_ response: HTTPURLResponse, body: Data, truncated: Bool,
                         url: String) -> [String: Any] {
        var seen: [String: [String]] = [:]
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            seen[name, default: []].append(String(describing: rawValue))
        }
        var headers: [String: String] = [:]
        for (name, values) in seen {
            headers[name] = values.joined(separator: ", ")
        }

        var o: [String: Any] = [
            "status": response.statusCode,
            "url": url,
            "headers": headers,
            "truncated": truncated,
        ]
        if let text = String(data: body, encoding: .utf8) {
            o["body"] = text
        } else {
            o["bodyBase64"] = body.base64EncodedString()
        }
        return o
    }

    // MARK: - http.cookies / http.clearCookies

    func cookies(_ payload: [String: Any]) -> [String: Any] {
        let host = HttpFetcher.hostOf(payload["url"] as? String ?? "")
        jarLock.lock()
        defer { jarLock.unlock() }
        var o: [String: Any] = [:]
        for (key, value) in jar {
            if let host = host, key != host { continue }
            o[key] = value.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        }
        return o
    }

    func clearCookies(_ payload: [String: Any]) -> [String: Any] {
        let host = HttpFetcher.hostOf(payload["url"] as? String ?? "")
        jarLock.lock()
        if let host = host {
            jar.removeValue(forKey: host)
        } else {
            jar.removeAll()
        }
        let count = jar.count
        jarLock.unlock()
        return ["hosts": count]
    }

    private func cookieHeader(_ url: String) -> String? {
        guard let host = HttpFetcher.hostOf(url) else { return nil }
        jarLock.lock()
        defer { jarLock.unlock() }
        guard let map = jar[host], !map.isEmpty else { return nil }
        return map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func storeCookies(_ url: String, _ response: HTTPURLResponse) {
        guard let host = HttpFetcher.hostOf(url) else { return }
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        // URLSession hands multiple Set-Cookie lines over as one comma-joined
        // string, so attributes have to be filtered out by name.
        let attributes: Set<String> = [
            "expires", "max-age", "path", "domain", "secure", "httponly",
            "samesite", "priority", "partitioned", "version", "comment",
        ]
        jarLock.lock()
        defer { jarLock.unlock() }
        for chunk in raw.components(separatedBy: ",") {
            let pair = chunk.components(separatedBy: ";").first ?? ""
            guard let eq = pair.firstIndex(of: "=") else { continue }
            let name = pair[pair.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let value = pair[pair.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if name.isEmpty || attributes.contains(name.lowercased()) { continue }
            var map = jar[host] ?? [:]
            if value.isEmpty {
                map.removeValue(forKey: name)
            } else {
                map[name] = value
            }
            jar[host] = map
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // handled manually in get()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let key = dataTask.taskIdentifier
        bufferLock.lock()
        var buffer = buffers[key] ?? Data()
        let room = HttpFetcher.maxBytes - buffer.count
        if room > 0 {
            buffer.append(data.prefix(room))
        }
        if data.count > room {
            truncated[key] = true
            dataTask.cancel()
        }
        buffers[key] = buffer
        bufferLock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        let key = task.taskIdentifier
        bufferLock.lock()
        let finish = done[key]
        bufferLock.unlock()
        finish?(error)
    }

    // MARK: - helpers

    private static func isHttp(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func isRedirect(_ status: Int) -> Bool {
        return status == 301 || status == 302 || status == 303
            || status == 307 || status == 308
    }

    private static func isReserved(_ name: String) -> Bool {
        return reserved.contains(name.lowercased())
    }

    private static func hostOf(_ url: String) -> String? {
        guard !url.isEmpty, let host = URL(string: url)?.host else { return nil }
        return host.lowercased()
    }

    /// A request failure that already knows its contract error code.
    private struct HttpError: Error {
        let code: String
        let message: String

        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }
}
