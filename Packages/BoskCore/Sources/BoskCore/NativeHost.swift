import Foundation

// Ported from Search by Office Commun (MIT License, https://github.com/driceroland/Search,
// ExtensionNative.swift). Chrome's native messaging: an extension talks to a program on this
// Mac (its "host") over the program's stdin and stdout. The app finds the host and runs it
// (ExtensionNative); this file is the pipe to the host and its link to the extension's port.

/// A refusal or failure, in Chrome's words: the extension sees it as `runtime.lastError`.
public struct NativeHostError: LocalizedError {
    public let why: String
    public var errorDescription: String? { why }
    public init(why: String) { self.why = why }
}

/// What Bosk uses of an extension's message port. `WKWebExtension.MessagePort` has all of
/// it; BoskCore has no WebKit, so the tests give their own port.
@MainActor
public protocol NativeMessagePort: AnyObject, Sendable {
    var isDisconnected: Bool { get }
    var messageHandler: ((Any?, (any Error)?) -> Void)? { get set }
    var disconnectHandler: (((any Error)?) -> Void)? { get set }
    func sendMessage(_ message: Any?, completionHandler: (((any Error)?) -> Void)?)
    func disconnect()
}

/// One host program and the framing Chrome uses to talk to it.
public final class HostPipe: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()
    public var onMessage: ((Any) -> Void)?
    public var onExit: (() -> Void)?
    private var waiters: [CheckedContinuation<Reply, Error>] = []

    public init(program: URL, origin: String) {
        process.executableURL = program
        process.arguments = [origin]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A host that is already gone — refused to run, killed as it
        // started — would take the browser with it: writing to its closed
        // pipe raises SIGPIPE. Refused, the write only fails.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                self.finish()
                self.closePipes()
                return
            }
            self.take(chunk)
        }
        process.terminationHandler = { [weak self] _ in self?.finish() }
        do {
            try process.run()
        } catch {
            closePipes()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            throw error
        }
    }

    public func stop() {
        // Ended first: a write that waits on a host that does not read then fails and lets go.
        if process.isRunning { process.terminate() }
        closePipes()
    }

    /// Its own lock, not `lock`: a write can wait on a full pipe, and `take` must still run.
    private let writeLock = NSLock()
    private var pipesClosed = false

    /// Bosk's ends of the two pipes closed only when this object went away, and a port kept
    /// this object after it disconnected (see `link`). Bitwarden connects to its host about
    /// twice each 10 s; after about 18 hours Bosk had 4,814 pipes open, and every file open
    /// failed with EMFILE (Bitwarden's storage first, 2026-09-28). So they are closed here,
    /// once: at the end of the host's output, at stop, or when it cannot start.
    private func closePipes() {
        writeLock.lock()
        let first = !pipesClosed
        pipesClosed = true
        writeLock.unlock()
        guard first else { return }
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    public func write(_ message: Any) throws {
        let json = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard json.count <= 1 << 20 else { throw NativeHostError(why: "Message too long for a native host") }
        var length = UInt32(json.count).littleEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        // A closed handle must not be written: Bosk crashes on an exception (AppDelegate).
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !pipesClosed else { throw NativeHostError(why: "Native host has exited.") }
        try input.fileHandleForWriting.write(contentsOf: frame)
    }

    /// A JSON value from the host. Each one is new, and only one reader gets it.
    struct Reply: @unchecked Sendable {
        let value: Any
    }

    public func readOne() async throws -> Any? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Reply, Error>) in
            lock.lock()
            waiters.append(continuation)
            lock.unlock()
        }.value
    }

    private func take(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var messages: [Any] = []
        while buffer.count >= 4 {
            let length = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            guard buffer.count >= 4 + length else { break }
            let body = buffer.subdata(in: 4..<(4 + length))
            buffer.removeSubrange(0..<(4 + length))
            if let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) {
                messages.append(message)
            }
        }
        var handed: [(CheckedContinuation<Reply, Error>, Any)] = []
        for message in messages where !waiters.isEmpty {
            handed.append((waiters.removeFirst(), message))
        }
        let rest = messages.dropFirst(handed.count)
        lock.unlock()
        handed.forEach { $0.0.resume(returning: Reply(value: $0.1)) }
        rest.forEach { onMessage?($0) }
    }

    private func finish() {
        lock.lock()
        let pending = waiters
        waiters = []
        // Both the end of output and the host's exit call this, often at
        // once and on different threads: taken under the lock, onExit runs
        // once and is released once.
        let exit = onExit
        onExit = nil
        lock.unlock()
        pending.forEach { $0.resume(throwing: NativeHostError(why: "Native host has exited.")) }
        exit?()
    }
}

extension HostPipe {
    /// `runtime.connectNative`: keeps the port and the host talking until either end lets go.
    ///
    /// The handlers of the port and of this pipe hold the port and the pipe only weakly. When
    /// they held them strongly, the port held itself through them and never went away, with its
    /// pipe, process and file handles. Bitwarden's worker opens a port to its desktop app twice
    /// each 10 s, all day: Bosk 0.16.6 kept about 107,000 ports after 6 days (338 MB in malloc,
    /// 2026-10-19). WebKit lets a port go when nothing else holds it. While the host runs, the
    /// app holds the port and the pipe (ExtensionNative).
    @MainActor
    public func link(to port: some NativeMessagePort) {
        onMessage = { [weak port] message in
            nonisolated(unsafe) let message = message
            DispatchQueue.main.async { port?.sendMessage(message, completionHandler: nil) }
        }
        onExit = { [weak port] in
            DispatchQueue.main.async { if let port, !port.isDisconnected { port.disconnect() } }
        }
        var beating: Timer?
        port.messageHandler = { [weak port, weak self] message, _ in
            guard let port, let self, let message else { return }
            // A worker's shim asking whether the port has arrived (see the
            // shim, after its WebSocket): answered here, never passed on.
            if let asked = message as? [String: Any], let word = asked["__boskNative"] {
                // The shim's answer to "alive" (below) is only the worker
                // keeping itself: nothing to say back.
                guard (word as? String) == "here?" else { return }
                port.sendMessage(["__boskNative": "here"], completionHandler: nil)
                // Asked, it is a worker's port, and WebKit unloads a worker
                // that hasn't posted on a port for two minutes: iCloud
                // Passwords then forgets it was paired and asks for a code
                // again. Chrome keeps a worker with a port to an app alive;
                // here a word on the port now and then, heard only by the
                // shim, has the worker answer on it, which is what WebKit
                // counts.
                if beating == nil {
                    beating = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak port] timer in
                        // Scheduled on the main run loop, so it fires on the main thread.
                        nonisolated(unsafe) let timer = timer
                        MainActor.assumeIsolated {
                            guard let port, !port.isDisconnected else { timer.invalidate(); return }
                            port.sendMessage(["__boskNative": "alive"], completionHandler: nil)
                        }
                    }
                }
                return
            }
            try? self.write(message)
        }
        port.disconnectHandler = { [weak self] _ in beating?.invalidate(); self?.stop() }
    }
}
