import Foundation
import WebKit

/**
 Serves the bundled page over `app://local/`.

 `file://` is not an option: WKWebView gives file origins an opaque security
 origin, so localStorage and fetch behave differently from a real app. A custom
 scheme keeps a normal, stable origin (`app://local`) while the bytes still come
 from the app bundle. See BRIDGE.md: assets = custom scheme handler on iOS.
 */
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "app"
    static let host = "local"
    static let startURL = URL(string: "app://local/web/index.html")!

    /// Directory that holds the copied `web/` folder, i.e. the bundle.
    private let root: URL
    private let lock = NSLock()
    private var stopped = Set<ObjectIdentifier>()

    init(root: URL) {
        self.root = root
        super.init()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let key = ObjectIdentifier(task)
        let isStopped: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return stopped.contains(key)
        }()
        if isStopped { return }

        guard let url = task.request.url, let fileURL = fileURL(for: url) else {
            fail(task, key, NSURLErrorBadURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            fail(task, key, NSURLErrorFileDoesNotExist)
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType(for: fileURL.pathExtension),
                "Content-Length": String(data.count),
                "Cache-Control": "no-cache",
                "Access-Control-Allow-Origin": "*",
            ]
        ) else {
            fail(task, key, NSURLErrorCannotParseResponse)
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        stopped.insert(ObjectIdentifier(task))
        lock.unlock()
    }

    // --- helpers ---------------------------------------------------------

    private func fail(_ task: WKURLSchemeTask, _ key: ObjectIdentifier, _ code: Int) {
        lock.lock()
        let isStopped = stopped.contains(key)
        lock.unlock()
        if isStopped { return }
        task.didFailWithError(NSError(domain: NSURLErrorDomain, code: code))
    }

    /**
     Maps `app://local/web/index.html` to `<bundle>/web/index.html`.

     The path is resolved and then checked against the root, so a crafted
     `..%2f` cannot climb out of the bundle.
     */
    func fileURL(for url: URL) -> URL? {
        guard url.scheme == AssetSchemeHandler.scheme else { return nil }
        guard url.host == nil || url.host == AssetSchemeHandler.host else { return nil }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        if path.hasSuffix("/") { path += "index.html" }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        let base = root.standardizedFileURL.path
        guard candidate.path == base || candidate.path.hasPrefix(base + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return FileManager.default.fileExists(atPath: index.path) ? index : nil
        }
        return candidate
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
