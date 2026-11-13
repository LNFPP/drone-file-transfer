import SwiftUI
import AppKit

@main
struct DroneFileTransferApp: App {
    @StateObject private var settings = AppSettings()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Drone File Transfer") {
            TabView {
                RunView()
                    .tabItem { Label("Run", systemImage: "play.circle") }
                SetupView()
                    .tabItem { Label("Setup", systemImage: "gearshape") }
            }
            .environmentObject(settings)
            .frame(minWidth: 760, minHeight: 620)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
