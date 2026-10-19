import Foundation
import Testing
@testable import BoskCore

/// WebKit puts one copy of a content script in each web process for each granted pattern that
/// matches it. A pattern that a wider granted pattern covers only adds copies (Return YouTube
/// Dislike: 4 copies of 8.6 MB per web process). But a removed pattern must not take away access.
struct MatchPatternCoverTests {
    private let forever = Date.distantFuture

    @Test("Return YouTube Dislike keeps only the patterns that give it one script copy per process")
    func youTubeHostsAreCovered() {
        let granted = ["*://*.youtube.com/*", "*://youtube.com/*", "*://www.youtube.com/*",
                       "*://m.youtube.com/*", "*://returnyoutubedislikeapi.com/*"]
        let kept = MatchPatternCover.uncovered(Dictionary(uniqueKeysWithValues: granted.map { ($0, forever) }))
        #expect(Set(kept.keys) == ["*://*.youtube.com/*", "*://returnyoutubedislikeapi.com/*"])
    }

    @Test("A host stays when the wider pattern ends sooner, so access does not end early")
    func shorterWidePatternDoesNotCover() {
        let soon = Date(timeIntervalSinceNow: 3600)
        let kept = MatchPatternCover.uncovered(["*://*.youtube.com/*": soon, "*://www.youtube.com/*": forever])
        #expect(kept.count == 2)
    }

    @Test("All hosts covers nothing: WebKit checks specific hosts first, so a denied all-hosts pattern cannot win")
    func allHostsDoesNotCover() {
        let granted = ["*://*/*": forever, "<all_urls>": forever, "https://example.com/*": forever]
        #expect(MatchPatternCover.uncovered(granted).count == 3)
    }

    @Test("A host stays when the wider pattern has fewer schemes or paths, so no URL loses access")
    func narrowerSchemeOrPathDoesNotCover() {
        let granted = ["https://*.example.com/*": forever, "*://www.example.com/*": forever,
                       "*://*.example.org/app/*": forever, "*://www.example.org/*": forever,
                       "*://*.ample.com/*": forever]
        #expect(MatchPatternCover.uncovered(granted).count == 5)
    }

    @Test("Scheme * covers http, and host *.x covers x itself, as WebKit matches them")
    func webKitMatching() {
        let kept = MatchPatternCover.uncovered(["*://*.example.com/*": forever, "http://EXAMPLE.com/a": forever])
        #expect(Array(kept.keys) == ["*://*.example.com/*"])
    }
}
