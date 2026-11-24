import AppKit
import DragonCurve
import Dragonfold
import Dragonreel
import Dragonscale
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    static let shared = AppDelegate()

    private var window: NSWindow?
    private let minSize = NSSize(width: 1240, height: 780)
    private let defaultSize = NSSize(width: 1380, height: 860)
    private var fileMenu: NSMenu?
    private var viewMenu: NSMenu?
    private var playMenuItem: NSMenuItem?
    private var playItem: NSMenuItem?
    private var keyMonitor: Any?

    private override init() { super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        showMainWindow()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handleKey(event)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if ShellState.shared.mounted.contains(.fold) {
            DragonfoldHost.stop()
        }
        if ShellState.shared.mounted.contains(.reel) {
            DragonreelHost.pause()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        ShellState.shared.open(url)
    }

    func sectionChanged() {
        refreshFileMenu()
        updateViewChecks()
        window?.title = ShellState.shared.section.windowTitle
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        switch ShellState.shared.section {
        case .fold:
            playItem?.title = DragonfoldHost.playMenuTitle
        case .reel:
            playItem?.title = DragonreelHost.playMenuTitle
        case .curve, .scale:
            break
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let section = ShellState.shared.section
        switch menuItem.action {
        case #selector(menuOpen(_:)), #selector(menuOpenSecond(_:)), #selector(menuDemo(_:)):
            switch section {
            case .curve: return true
            case .scale: return !DragonscaleHost.busy
            case .fold: return !DragonfoldHost.busy
            case .reel: return !DragonreelHost.busy
            }
        case #selector(menuFold(_:)):
            switch section {
            case .scale: return DragonscaleHost.canFold
            case .fold: return DragonfoldHost.canFold
            case .reel: return DragonreelHost.canFold
            case .curve: return false
            }
        case #selector(menuRestore(_:)):
            switch section {
            case .scale: return DragonscaleHost.canRestore
            case .fold: return DragonfoldHost.canRestore
            case .reel: return DragonreelHost.canRestore
            case .curve: return false
            }
        case #selector(menuFoldAgain(_:)):
            switch section {
            case .scale: return DragonscaleHost.canFoldAgain
            case .fold: return DragonfoldHost.canFoldAgain
            case .reel: return DragonreelHost.canFoldAgain
            case .curve: return false
            }
        case #selector(menuExport(_:)):
            switch section {
            case .scale: return DragonscaleHost.canExportFolded
            case .fold: return DragonfoldHost.canExportFolded
            case .reel: return DragonreelHost.canExportFolded
            case .curve: return false
            }
        case #selector(menuSavePlain(_:)):
            switch section {
            case .scale: return DragonscaleHost.canSavePlain
            case .fold: return DragonfoldHost.canSavePlain
            case .reel: return DragonreelHost.canSavePlain
            case .curve: return false
            }
        default:
            return true
        }
    }

    private static func handleKey(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return event
        }
        if NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil {
            return event
        }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView || responder is NSTextField {
            return event
        }
        let section = ShellState.shared.section
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == " " {
            switch section {
            case .fold:
                if !event.isARepeat { DragonfoldHost.togglePlay() }
                return nil
            case .reel:
                if !event.isARepeat { DragonreelHost.togglePlay() }
                return nil
            case .curve, .scale:
                return event
            }
        }
        guard section != .curve else { return event }
        switch key {
        case "0", "a":
            if event.isARepeat { return nil }
            setPasses(0, section)
            return nil
        case "1", "2", "3", "4", "5", "6", "7":
            if event.isARepeat { return nil }
            if let value = Int(key ?? "") {
                setPasses(value, section)
            }
            return nil
        default:
            return event
        }
    }

    private static func setPasses(_ value: Int, _ section: Wing) {
        switch section {
        case .scale: DragonscaleHost.setPasses(value)
        case .fold: DragonfoldHost.setPasses(value)
        case .reel: DragonreelHost.setPasses(value)
        case .curve: break
        }
    }

    private func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = ShellView().frame(minWidth: minSize.width, minHeight: minSize.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: defaultSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = ShellState.shared.section.windowTitle
        window.backgroundColor = ShellTheme.windowNS
        window.contentView = hosting
        window.setContentSize(defaultSize)
        window.contentMinSize = minSize
        window.isRestorable = true
        window.center()
        window.setFrameAutosaveName("TheDragonMain")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    @objc private func showAbout(_ sender: Any?) {
        let section = ShellState.shared.section
        let credits = NSAttributedString(
            string: """
            Curve rearranges a note, a file, or a folder.
            Scale rearranges a picture.
            Fold rearranges audio.
            Reel rearranges a movie.

            The phrase is not stored. This is a fold, not a lock.

            \(section.title) \(version(of: section))
            """,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: AppInfo.name,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .version: AppInfo.build,
            .credits: credits,
        ])
    }

    private func version(of section: Wing) -> String {
        switch section {
        case .curve: return DragonCurveHost.versionLine
        case .scale: return DragonscaleHost.versionLine
        case .fold: return DragonfoldHost.versionLine
        case .reel: return DragonreelHost.versionLine
        }
    }

    @objc private func menuSection(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let wing = Wing(rawValue: raw) else { return }
        ShellState.shared.show(wing)
    }

    @objc private func menuOpen(_ sender: Any?) {
        switch ShellState.shared.section {
        case .curve: DragonCurveHost.openNote()
        case .scale: DragonscaleHost.openPanel()
        case .fold: DragonfoldHost.openPanel()
        case .reel: DragonreelHost.openPanel()
        }
    }

    @objc private func menuOpenSecond(_ sender: Any?) { DragonscaleHost.openSecondPanel() }
    @objc private func menuEncrypt(_ sender: Any?) { DragonCurveHost.encryptNote() }
    @objc private func menuDecrypt(_ sender: Any?) { DragonCurveHost.decryptNote() }
    @objc private func menuClear(_ sender: Any?) { DragonCurveHost.clearNote() }
    @objc private func menuSaveCiphertext(_ sender: Any?) { DragonCurveHost.saveCiphertext() }
    @objc private func menuSavePlaintext(_ sender: Any?) { DragonCurveHost.savePlaintext() }
    @objc private func menuEncryptFile(_ sender: Any?) { DragonCurveHost.encryptFiles() }
    @objc private func menuDecryptFile(_ sender: Any?) { DragonCurveHost.decryptFiles() }
    @objc private func menuEncryptFolder(_ sender: Any?) { DragonCurveHost.encryptFolders() }
    @objc private func menuDecryptFolder(_ sender: Any?) { DragonCurveHost.decryptFolders() }

    @objc private func menuFold(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.fold()
        case .fold: DragonfoldHost.fold()
        case .reel: DragonreelHost.fold()
        case .curve: break
        }
    }

    @objc private func menuRestore(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.restore()
        case .fold: DragonfoldHost.restore()
        case .reel: DragonreelHost.restore()
        case .curve: break
        }
    }

    @objc private func menuFoldAgain(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.foldAgain()
        case .fold: DragonfoldHost.foldAgain()
        case .reel: DragonreelHost.foldAgain()
        case .curve: break
        }
    }

    @objc private func menuExport(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.exportFolded()
        case .fold: DragonfoldHost.exportFolded()
        case .reel: DragonreelHost.exportFolded()
        case .curve: break
        }
    }

    @objc private func menuSavePlain(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.savePlain()
        case .fold: DragonfoldHost.savePlain()
        case .reel: DragonreelHost.savePlain()
        case .curve: break
        }
    }

    @objc private func menuDemo(_ sender: Any?) {
        switch ShellState.shared.section {
        case .scale: DragonscaleHost.useCard()
        case .fold: DragonfoldHost.useTone()
        case .reel: DragonreelHost.useReel()
        case .curve: break
        }
    }

    @objc private func menuPlay(_ sender: Any?) {
        switch ShellState.shared.section {
        case .fold: DragonfoldHost.togglePlay()
        case .reel: DragonreelHost.togglePlay()
        case .curve, .scale: break
        }
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About The Dragon", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide The Dragon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit The Dragon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        self.fileMenu = fileMenu

        let playItemMenu = NSMenuItem()
        main.addItem(playItemMenu)
        let playMenu = NSMenu(title: "Play")
        playItemMenu.submenu = playMenu
        playMenu.delegate = self
        let play = playMenu.addItem(withTitle: "Play", action: #selector(menuPlay(_:)), keyEquivalent: "")
        play.target = self
        playItem = play
        playMenuItem = playItemMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        self.viewMenu = viewMenu
        for (index, wing) in Wing.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: wing.title, action: #selector(menuSection(_:)), keyEquivalent: "\(index + 1)")
            item.target = self
            item.representedObject = wing.rawValue
        }

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
        sectionChanged()
    }

    private func refreshFileMenu() {
        guard let fileMenu else { return }
        fileMenu.removeAllItems()
        switch ShellState.shared.section {
        case .curve:
            _ = keyed(fileMenu, "Open Note…", #selector(menuOpen(_:)), "o")
            _ = keyed(fileMenu, "Encrypt", #selector(menuEncrypt(_:)), "e")
            _ = keyed(fileMenu, "Decrypt", #selector(menuDecrypt(_:)), "d")
            _ = keyed(fileMenu, "Clear", #selector(menuClear(_:)), "k")
            fileMenu.addItem(.separator())
            let cipher = keyed(fileMenu, "Save Ciphertext…", #selector(menuSaveCiphertext(_:)), "s")
            cipher.keyEquivalentModifierMask = [.command, .shift]
            let plain = keyed(fileMenu, "Save Plaintext…", #selector(menuSavePlaintext(_:)), "s")
            plain.keyEquivalentModifierMask = [.command, .option]
            fileMenu.addItem(.separator())
            _ = keyed(fileMenu, "Encrypt File", #selector(menuEncryptFile(_:)), "")
            _ = keyed(fileMenu, "Decrypt File", #selector(menuDecryptFile(_:)), "")
            _ = keyed(fileMenu, "Encrypt Folder", #selector(menuEncryptFolder(_:)), "")
            _ = keyed(fileMenu, "Decrypt Folder", #selector(menuDecryptFolder(_:)), "")
        case .scale:
            _ = keyed(fileMenu, "Open Image…", #selector(menuOpen(_:)), "o")
            let second = keyed(fileMenu, "Open Second Image…", #selector(menuOpenSecond(_:)), "O")
            second.keyEquivalentModifierMask = [.command, .shift]
            _ = keyed(fileMenu, "Fold", #selector(menuFold(_:)), "f")
            _ = keyed(fileMenu, "Restore", #selector(menuRestore(_:)), "d")
            _ = keyed(fileMenu, "Fold Again", #selector(menuFoldAgain(_:)), "")
            fileMenu.addItem(.separator())
            _ = keyed(fileMenu, "Export Folded PNG…", #selector(menuExport(_:)), "e")
            _ = keyed(fileMenu, "Save Plain PNG…", #selector(menuSavePlain(_:)), "s")
            _ = keyed(fileMenu, "Back to Card", #selector(menuDemo(_:)), "k")
        case .fold:
            _ = keyed(fileMenu, "Open Audio…", #selector(menuOpen(_:)), "o")
            _ = keyed(fileMenu, "Fold", #selector(menuFold(_:)), "f")
            _ = keyed(fileMenu, "Restore", #selector(menuRestore(_:)), "d")
            _ = keyed(fileMenu, "Fold Again", #selector(menuFoldAgain(_:)), "")
            fileMenu.addItem(.separator())
            _ = keyed(fileMenu, "Export Folded WAV…", #selector(menuExport(_:)), "e")
            _ = keyed(fileMenu, "Save Plain WAV…", #selector(menuSavePlain(_:)), "s")
            _ = keyed(fileMenu, "Back to Tone", #selector(menuDemo(_:)), "k")
        case .reel:
            _ = keyed(fileMenu, "Open Movie…", #selector(menuOpen(_:)), "o")
            _ = keyed(fileMenu, "Fold", #selector(menuFold(_:)), "f")
            _ = keyed(fileMenu, "Restore", #selector(menuRestore(_:)), "d")
            _ = keyed(fileMenu, "Fold Again", #selector(menuFoldAgain(_:)), "")
            fileMenu.addItem(.separator())
            _ = keyed(fileMenu, "Export Folded Movie…", #selector(menuExport(_:)), "e")
            _ = keyed(fileMenu, "Save Plain Movie…", #selector(menuSavePlain(_:)), "s")
            _ = keyed(fileMenu, "Back to Reel", #selector(menuDemo(_:)), "k")
        }
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let media = ShellState.shared.section == .fold || ShellState.shared.section == .reel
        playMenuItem?.isHidden = !media
    }

    private func updateViewChecks() {
        guard let viewMenu else { return }
        let current = ShellState.shared.section
        for item in viewMenu.items {
            guard let raw = item.representedObject as? String, let wing = Wing(rawValue: raw) else { continue }
            item.state = wing == current ? .on : .off
        }
    }

    @discardableResult
    private func keyed(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }
}
