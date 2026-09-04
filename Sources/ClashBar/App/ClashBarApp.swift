import AppKit
import SwiftUI

@main
struct ClashMenuApp: App {
    @NSApplicationDelegateAdaptor(ClashMenuAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class ClashMenuAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItemController: NativeStatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let image = BrandIcon.image {
            NSApp.applicationIconImage = image
        }
        NSApp.setActivationPolicy(.accessory)
        self.statusItemController = NativeStatusMenuController(appState: self.appState)
        self.appState.requestLocationPermissionIfNeeded()
        self.appState.presentInitialNoCoreSetupGuideIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.appState.shutdownForTermination()
        self.statusItemController?.shutdown()
        self.statusItemController = nil
    }
}
