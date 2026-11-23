import AppKit
import JarvisCore

// Entry point. Everything interesting lives in JarvisCore.AppDelegate.
@main
@MainActor
struct JarvisMain {
    static func main() {
        // `Jarvis --install-agent` and friends manage the launchd supervisor, then exit.
        Supervisor.handleCommandLine()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // .accessory = menu bar app, no Dock icon (also set via LSUIElement in Info.plist).
        app.setActivationPolicy(.accessory)
        // A hidden main menu with an Edit menu so ⌘V / ⌘C / ⌘A work in our dialogs (API key paste!).
        app.mainMenu = AppDelegate.makeMainMenu()
        app.run()
    }
}
