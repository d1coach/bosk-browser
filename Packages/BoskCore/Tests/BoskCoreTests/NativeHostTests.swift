import Foundation
import Testing
@testable import BoskCore

/// Bitwarden's worker opens a native port to its desktop app twice each 10 s, all day. What Bosk
/// makes for one port must go away when the port closes, or the app grows without end: Bosk 0.16.6
/// kept about 107,000 ports, with their pipes and processes, after 6 days.
@MainActor
struct NativeHostTests {
    /// Stands in for `WKWebExtension.MessagePort`.
    final class Port: NativeMessagePort {
        var isDisconnected = false
        var messageHandler: ((Any?, (any Error)?) -> Void)?
        var disconnectHandler: (((any Error)?) -> Void)?
        func sendMessage(_ message: Any?, completionHandler: (((any Error)?) -> Void)?) {}
        func disconnect() { isDisconnected = true }
    }

    @Test("A closed port and its host pipe go away, because Bitwarden opens 17,280 ports a day")
    func closedPortGoesAway() async throws {
        weak var closedPort: Port?
        weak var closedPipe: HostPipe?
        do {
            let port = Port()
            let pipe = HostPipe(program: URL(fileURLWithPath: "/bin/cat"), origin: "chrome-extension://test/")
            try pipe.start()
            pipe.link(to: port)
            // A worker's shim asks if its port arrived. This also starts the timer that keeps
            // the worker loaded.
            port.messageHandler?(["__boskNative": "here?"], nil)
            // The extension closes the port. WebKit then lets the port go.
            port.isDisconnected = true
            port.disconnectHandler?(nil)
            closedPort = port
            closedPipe = pipe
        }
        // The host's end comes on another thread, then on the main queue.
        for _ in 0..<50 where closedPort != nil || closedPipe != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(closedPort == nil)
        #expect(closedPipe == nil)
    }
}
