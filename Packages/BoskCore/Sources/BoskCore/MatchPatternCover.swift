import Foundation

/// The granted match patterns to give WebKit. WebKit makes one copy of each content script for
/// each granted pattern that matches it (WebExtensionContext::addInjectedContent), and each web
/// process holds its own copy of each. Return YouTube Dislike gets `*://*.youtube.com/*` and also
/// `*://youtube.com/*`, `*://www.youtube.com/*` and `*://m.youtube.com/*` (its content script
/// hosts), so its 8.6 MB script was in each web process 4 times. A URL of a removed pattern stays
/// granted: WebKit checks URLs against each granted pattern, and the wider one matches it.
public enum MatchPatternCover {
    /// `granted` without each one-host pattern that a granted `*.` pattern covers for at least as
    /// long. An all-hosts pattern never covers: WebKit checks specific hosts before all hosts, so
    /// a host granted next to a denied all-hosts pattern must stay. Two patterns cannot remove
    /// each other, because only a pattern with no `*` in its host is removed.
    public static func uncovered(_ granted: [String: Date]) -> [String: Date] {
        granted.filter { text, date in
            guard let pattern = Parts(text), !pattern.host.contains("*") else { return true }
            return !granted.contains { other, otherDate in
                guard otherDate >= date, let wide = Parts(other) else { return false }
                return wide.covers(pattern)
            }
        }
    }

    /// `scheme://host/path`. Nil for `<all_urls>` and for no host (`file:///*`).
    private struct Parts {
        let scheme, host, path: String

        init?(_ text: String) {
            guard let separator = text.range(of: "://") else { return nil }
            let rest = text[separator.upperBound...]
            guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
            scheme = text[..<separator.lowerBound].lowercased()
            host = rest[..<slash].lowercased()
            path = String(rest[slash...])
        }

        /// As WebKit matches URLs: scheme `*` is http and https, and host `*.x` is x and its subdomains.
        func covers(_ other: Parts) -> Bool {
            guard host.hasPrefix("*."), host.count > 2 else { return false }
            let domain = host.dropFirst(2)
            let schemeCovers = scheme == other.scheme || (scheme == "*" && ["http", "https"].contains(other.scheme))
            let hostCovers = other.host == domain || other.host.hasSuffix("." + domain)
            return schemeCovers && hostCovers && (path == "/*" || path == other.path)
        }
    }
}
