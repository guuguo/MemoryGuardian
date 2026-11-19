import SwiftUI

@main
struct MemoryGuardianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = MemoryMonitor()

    var body: some Scene {
        WindowGroup("内存守卫", id: "main") {
            DashboardView()
                .environmentObject(monitor)
                .focusEffectDisabled()
                .frame(minWidth: 1100, idealWidth: 1100, maxWidth: .infinity,
                       minHeight: 708, idealHeight: 908, maxHeight: .infinity)
                .background(MemoryStyle.background)
                .ignoresSafeArea()
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    monitor.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1100, height: 908)
        .commands { GuardianWindowCommands() }

        MenuBarExtra {
            MenuBarView(status: monitor.menuBarStatus)
                .environmentObject(monitor)
                .focusEffectDisabled()
        } label: {
            MenuBarStatusLabel(status: monitor.menuBarStatus)
        }
    }
}

struct GuardianWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("显示内存守卫") { showGuardianWindow(using: openWindow) }
                .keyboardShortcut("1", modifiers: [.command, .option])
        }
    }
}

@MainActor
func showGuardianWindow(using openWindow: OpenWindowAction) {
    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    } else {
        openWindow(id: "main")
    }
    NSApp.activate(ignoringOtherApps: true)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppAssets.appIcon() {
            NSApp.applicationIconImage = icon
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.forEach {
                self.configureWindow($0)
                $0.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    private func configureWindow(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: 1100, height: 740)
        var frame = window.frame
        frame.origin.y += frame.height - 940
        frame.size = NSSize(width: 1100, height: 940)
        window.setFrame(frame, display: true)
        window.isMovableByWindowBackground = true
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedRed: 0.094, green: 0.102, blue: 0.110, alpha: 1)
    }
}
