import Foundation

/// Decides which tabs go to sleep. A sleeping tab has no web process, so it uses almost
/// no memory, but it reloads when the user comes back to it.
public enum SleepPolicy {
    public struct TabInfo: Sendable {
        public var id: UUID
        public var lastActive: Date
        /// The tab on screen in its window.
        public var isSelected: Bool
        public var isAsleep: Bool
        public var isPlayingMedia: Bool
        /// Camera or microphone in use (a call).
        public var isCapturing: Bool
        /// Text typed in a form and not sent yet.
        public var hasUnsentInput: Bool
        /// A pinned site: the user keeps it open, so a reload there is always a cost.
        public var isPinned: Bool

        public init(id: UUID, lastActive: Date, isSelected: Bool = false, isAsleep: Bool = false,
                    isPlayingMedia: Bool = false, isCapturing: Bool = false, hasUnsentInput: Bool = false,
                    isPinned: Bool = false) {
            self.id = id
            self.lastActive = lastActive
            self.isSelected = isSelected
            self.isAsleep = isAsleep
            self.isPlayingMedia = isPlayingMedia
            self.isCapturing = isCapturing
            self.hasUnsentInput = hasUnsentInput
            self.isPinned = isPinned
        }
    }

    public enum MemoryPressure: Sendable {
        case normal, warning, critical
    }

    /// - Parameters:
    ///   - idleLimit: Normal sleep time (the user chooses it in Bosk; 30 minutes by default).
    ///     When macOS reports a memory warning, half of it.
    /// - Returns: Tab IDs to sleep, oldest first.
    public static func tabsToSleep(_ tabs: [TabInfo], now: Date, idleLimit: TimeInterval,
                                   pressure: MemoryPressure) -> [UUID] {
        let ids = idleTabs(tabs, now: now, idleLimit: idleLimit, pressure: pressure)
        // A warning can stay for hours, and macOS reports it again and again. If each one slept
        // all tabs past half the sleep time, the user's sleep time would almost never apply.
        // The timer sleeps the tabs past the user's sleep time.
        return pressure == .warning ? Array(ids.prefix(1)) : ids
    }

    /// The tabs that can sleep and are idle for the limit, oldest first, with no count limit.
    /// Use it to find the tabs to ask about media before `tabsToSleep`.
    public static func idleTabs(_ tabs: [TabInfo], now: Date, idleLimit: TimeInterval,
                                pressure: MemoryPressure) -> [UUID] {
        let limit: TimeInterval = switch pressure {
        case .normal: idleLimit
        case .warning: idleLimit / 2
        case .critical: 0
        }
        return tabs
            .filter { canSleep($0) && now.timeIntervalSince($0.lastActive) >= limit }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.id)
    }

    /// Tabs that must stay awake, whatever the memory pressure:
    /// sleep would reload the page and lose what the user is doing.
    static func canSleep(_ tab: TabInfo) -> Bool {
        !tab.isAsleep && !tab.isSelected && !tab.isPlayingMedia && !tab.isCapturing && !tab.hasUnsentInput
            && !tab.isPinned
    }
}
