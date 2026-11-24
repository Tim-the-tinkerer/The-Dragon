import AppKit

@main
struct MainEntry {
    static func main() {
        if let code = ShellCLI.run(CommandLine.arguments) {
            exit(code)
        }
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
