import AppKit
import SwiftUI
import TinyTouchCore

@main
struct TinyTouchManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("TinyTouch Manager", id: "main") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 860, minHeight: 580)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.connection.isConnected ? "touchid" : "touchid")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.connection.isConnected ? 1 : 0.5)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Opens the management window on a section and brings the (menu-bar-only) app to the front.
struct WindowOpener {
    let openWindow: OpenWindowAction

    @MainActor
    func open(_ section: AppSection) {
        AppModel.shared.selection = section
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
