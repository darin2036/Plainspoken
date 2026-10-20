import Foundation

public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    /// The GitHub release page. Always on github.com under this project's own path.
    public var url: URL
}

public enum UpdateResult: Equatable, Sendable {
    case upToDate
    case available(AvailableUpdate)
    /// The repository has no published release yet, so there is nothing to compare against.
    case noReleases
}

/// Asks GitHub whether a newer release exists. This is the one request the app makes on its own
/// (besides approved model downloads). It sends nothing about you or your install: no version,
/// no identifiers, just a plain GET for the project's latest release.
public enum UpdateChecker {
    public static let repo = "darin2036/Plainspoken"

    /// True when `candidate` is a higher dotted version than `current` ("v0.2.0" > "0.1.9").
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let trimmed = v.hasPrefix("v") || v.hasPrefix("V") ? String(v.dropFirst()) : v
            // Ignore anything after a dash or plus, such as "-beta.1" or build metadata.
            let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Only links to this project's own GitHub pages are ever opened.
    static func isTrusted(_ url: URL, repo: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/\(repo)/")
    }

    /// `repo` is only overridden by the harness, to exercise the "update found" path.
    public static func check(current: String, repo: String = UpdateChecker.repo) async throws -> UpdateResult {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Plainspoken", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false

        let (data, response) = try await NetworkGuard.allowing {
            try await URLSession(configuration: .ephemeral).data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { return .noReleases }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              isTrusted(page, repo: repo)
        else { throw URLError(.cannotParseResponse) }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(tag, than: current) ? .available(AvailableUpdate(version: version, url: page)) : .upToDate
    }
}
