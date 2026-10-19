#if DEBUG
import AppKit

/// Debug builds only. Launch with `-BoskPerfTest YES` and Bosk folds and unfolds the sidebar
/// and switches tabs by itself, so Instruments can measure hitches without input noise.
/// See scripts/measure-hitches.sh.
@MainActor
enum PerfHarness {
    /// `-BoskInstallExtension <path>`: installs a folder, .zip or .crx at launch (it still asks).
    static func installExtensionIfRequested(_ controller: BrowserWindowController) {
        guard let path = UserDefaults.standard.string(forKey: "BoskInstallExtension") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            do {
                try await ExtensionManager.shared.install(from: URL(fileURLWithPath: path), in: controller.window)
            } catch {
                NSLog("Bosk: test install failed: %@", "\(error)")
            }
        }
    }

    /// `-BoskInstallWebStoreIDs id1,id2`: installs Chrome Web Store extensions at launch.
    static func installWebStoreExtensionsIfRequested(_ controller: BrowserWindowController) {
        guard let ids = UserDefaults.standard.string(forKey: "BoskInstallWebStoreIDs") else { return }
        Task { @MainActor in
            for id in ids.split(separator: ",").map(String.init) {
                do {
                    try await ExtensionManager.shared.installFromWebStore(extensionID: id, in: controller.window)
                    NSLog("Bosk: test install of %@ done", id)
                } catch {
                    NSLog("Bosk: test install of %@ failed: %@", id, "\(error)")
                }
            }
        }
    }

    /// `-BoskOpenPopup <id>` (or `installed`, for the extension `-BoskInstallExtension` added):
    /// shows the extension's popup after `-BoskOpenPopupAfter` seconds (5 when not given), so a
    /// worker's state after a pause can be checked without clicks.
    static func openPopupIfRequested(_ controller: BrowserWindowController) {
        guard let id = UserDefaults.standard.string(forKey: "BoskOpenPopup") else { return }
        let after = UserDefaults.standard.integer(forKey: "BoskOpenPopupAfter")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(after > 0 ? after : 5))
            // "installed": the extension `-BoskInstallExtension` just added (its ID is new).
            let record = id == "installed" ? ExtensionManager.shared.records.last : nil
            guard let context = ExtensionManager.shared.contexts[record?.id ?? id] else {
                return NSLog("Bosk: test popup: extension %@ is not loaded", id)
            }
            NSLog("Bosk: test popup of %@", id)
            context.performAction(for: controller.store.selectedTab)
            // `-BoskOpenPopupCycles <n>`: closes and opens it again, n times in all, to see what
            // a closed popup leaves behind in the extension's process.
            let cycles = UserDefaults.standard.integer(forKey: "BoskOpenPopupCycles")
            for cycle in 1..<max(cycles, 1) {
                try? await Task.sleep(for: .seconds(6))
                context.action(for: controller.store.selectedTab)?.closePopup()
                try? await Task.sleep(for: .seconds(2))
                NSLog("Bosk: test popup of %@, cycle %d", id, cycle + 1)
                context.performAction(for: controller.store.selectedTab)
            }
        }
    }

    static func runIfRequested(_ controller: BrowserWindowController) {
        guard UserDefaults.standard.bool(forKey: "BoskPerfTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            for _ in 0..<6 {
                controller.toggleSidebarFold(nil)
                try? await Task.sleep(for: .seconds(1))
            }
            for _ in 0..<8 {
                controller.showNextTab(nil)
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}
#endif
