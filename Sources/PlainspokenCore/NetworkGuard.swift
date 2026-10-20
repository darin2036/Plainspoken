import Foundation

/// Blocks every HTTP(S) request the app makes itself, except while a download the user approved is
/// running. This is what makes "nothing leaves your Mac once a model is installed" enforced in
/// code instead of relying on third-party packages to behave: if any dependency tried to phone
/// home during dictation, the request would fail here (and show up in the log as a blocked URL).
///
/// It covers URLSession traffic, which is all the app and its Whisper package use. Apple's own
/// speech and language models are fetched by macOS in separate system processes.
public final class NetworkGuard: URLProtocol {
    private static let lock = NSLock()
    private static var allowDepth = 0

    /// Call once at launch. After this, requests are refused unless inside `allowing`.
    public static func install() {
        URLProtocol.registerClass(NetworkGuard.self)
    }

    /// Runs `body` with network access allowed. Use only for a download the user has confirmed.
    public static func allowing<T>(_ body: () async throws -> T) async rethrows -> T {
        change(+1)
        defer { change(-1) }
        return try await body()
    }

    private static func change(_ delta: Int) {
        lock.lock()
        allowDepth += delta
        lock.unlock()
    }

    private static var blocking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowDepth == 0
    }

    public override class func canInit(with request: URLRequest) -> Bool {
        guard blocking, let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override func startLoading() {
        // Only the host is logged, never a full URL, so nothing sensitive can end up in the log.
        NSLog("Plainspoken blocked a network request to %@", request.url?.host ?? "unknown host")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    public override func stopLoading() {}
}
