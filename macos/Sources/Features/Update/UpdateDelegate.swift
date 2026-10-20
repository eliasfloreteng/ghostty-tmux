import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // A build that names its own feed with SUFeedURL in its Info.plist,
        // such as a fork's, updates from that feed alone, whatever the
        // channel. Returning nil makes Sparkle use it.
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            return nil
        }

        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // Sparkle supports a native concept of "channels" but it requires that
        // you share a single appcast file. We don't want to do that so we
        // do this instead.
        switch appDelegate.ghostty.config.autoUpdateChannel {
        case .tip: return "https://tip.files.ghostty.org/appcast.xml"
        case .stable: return "https://release.files.ghostty.org/appcast.xml"
        }
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
