import AppKit
import Foundation
import SwiftUI

extension Notification.Name {
    static let dragonOpenFiles = Notification.Name("dragonOpenFiles")
}

enum LaunchFiles {
    static var urls: [URL] = []
}

@MainActor
final class AppModel: ObservableObject {
    @Published var key = ""
    @Published var showKey = false
    @Published var header = false
    @Published var plaintext = "Hello"
    @Published var ciphertext = ""
    @Published var stale = false
    @Published var status = "Hello, with no key, reads olleH from the top of the page."
    @Published var alertMessage: String?
    @Published var showHelp = false
    @Published var files: [URL] = []
    @Published var folders: [URL] = []
    @Published var targeted = false
    @Published var unit: DragonEngine.Unit = .byte
    @Published var folderUnit: DragonEngine.Unit = .byte
    @Published var passCount = 0
    @Published var fileHeader = true
    @Published var scrambleName = false
    @Published var compression: DragonFolder.Compression = .deflate
    @Published var crossWeave = false
    @Published var mapPass = 1
    @Published var busy = false

    private var openedNoteURL: URL?
    private var openObserver: NSObjectProtocol?

    var passes: Int? {
        passCount == 0 ? nil : passCount
    }

    var passTotal: Int {
        (try? DragonEngine.plan(key: key, passes: passes).count) ?? 1
    }

    var shownMapPass: Int {
        min(max(mapPass, 1), passTotal)
    }

    var picture: DragonEngine.CurvePicture {
        DragonEngine.picture(text: plaintext, key: key, passes: passes, mapPass: shownMapPass)
    }

    init() {
        var seededFiles: [URL] = []
        var seededFolders: [URL] = []
        for url in LaunchFiles.urls {
            switch DragonFolder.kind(url) {
            case .file: seededFiles.append(url)
            case .directory: seededFolders.append(url)
            default: break
            }
        }
        if !seededFiles.isEmpty { files = seededFiles }
        if !seededFolders.isEmpty { folders = seededFolders }
        let ready = seededFiles.count + seededFolders.count
        if ready == 1 {
            status = "\((seededFiles.first ?? seededFolders[0]).lastPathComponent) is ready."
        } else if ready > 1 {
            status = "\(ready) items are ready."
        }
        openObserver = NotificationCenter.default.addObserver(
            forName: .dragonOpenFiles,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            Task { @MainActor in
                self?.addFiles(urls)
            }
        }
    }

    func markStale() {
        if !ciphertext.isEmpty {
            stale = true
        }
    }

    func encryptNote() {
        guard plaintext.unicodeScalars.count <= 1_000_000 else {
            alertMessage = "That note is too long for the page. Drop it as a file and choose Character."
            return
        }
        do {
            ciphertext = try DragonEngine.encryptDocument(
                text: plaintext,
                key: key,
                header: header,
                passes: passes
            )
            stale = false
            status = "Encrypted. \(passSentence())"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func decryptNote() {
        let source = ciphertext.isEmpty ? plaintext : ciphertext
        guard !source.isEmpty else {
            alertMessage = "Paste a ciphertext, or type a note."
            return
        }
        guard source.unicodeScalars.count <= 1_000_000 else {
            alertMessage = "That ciphertext is too long for the page. Drop it as a file."
            return
        }
        do {
            plaintext = try DragonEngine.decryptDocument(
                data: source,
                key: key,
                passes: passes
            )
            stale = false
            status = "Restored. \(passSentence())"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func clearNote() {
        plaintext = ""
        ciphertext = ""
        stale = false
        openedNoteURL = nil
        status = "Cleared. The phrase is still there."
    }

    func openNote() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Open a UTF-8 note. The file is not changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadNote(url)
    }

    func saveCiphertext() {
        guard !ciphertext.isEmpty else {
            alertMessage = "Encrypt a note before saving the ciphertext."
            return
        }
        let suggested = openedNoteURL.map { DragonFiles.siblingPath(for: $0, decrypting: false).lastPathComponent }
            ?? "note.dragon.txt"
        save(ciphertext, suggested: suggested, title: "Save Ciphertext")
    }

    func savePlaintext() {
        guard !plaintext.isEmpty else {
            alertMessage = "There is no plaintext to save."
            return
        }
        let suggested = openedNoteURL?.lastPathComponent ?? "note.txt"
        save(plaintext, suggested: suggested, title: "Save Plaintext")
    }

    func addFiles(_ urls: [URL]) {
        if busy {
            status = "Wait for the current fold to finish."
            return
        }
        var added = 0
        var lastName = ""
        for url in urls {
            switch DragonFolder.kind(url) {
            case .directory:
                if folders.contains(where: { $0.path == url.path }) { continue }
                folders.append(url)
                lastName = url.lastPathComponent
                added += 1
            case .file:
                if files.contains(where: { $0.path == url.path }) { continue }
                files.append(url)
                lastName = url.lastPathComponent
                added += 1
            case .symlink:
                alertMessage = "\(url.lastPathComponent) is a symbolic link. Dragon Curve does not follow those."
            case .missing:
                break
            case .special:
                alertMessage = "\(url.lastPathComponent) is not a regular file or folder."
            }
        }
        if added == 1 {
            status = "\(lastName) is ready."
        } else if added > 1 {
            status = "\(added) items are ready."
        }
    }

    func removeFile(_ url: URL) {
        files.removeAll { $0.path == url.path }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.path == url.path }
    }

    func encryptFiles() {
        foldFiles(decrypting: false)
    }

    func decryptFiles() {
        foldFiles(decrypting: true)
    }

    private func foldFiles(decrypting: Bool) {
        let urls = files
        guard !urls.isEmpty else {
            alertMessage = "Drop a file first."
            return
        }
        busy = true
        let phrase = key
        let chosen = unit
        let count = passes
        let writeHeader = fileHeader
        let scramble = scrambleName
        status = decrypting
            ? "Unfolding \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")…"
            : "Folding \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")…"
        Task.detached(priority: .userInitiated) {
            do {
                let written = try DragonFiles.write(
                    urls: urls,
                    key: phrase,
                    unit: chosen,
                    passes: count,
                    header: writeHeader,
                    decrypting: decrypting,
                    scrambleName: scramble
                )
                let names = written.map(\.lastPathComponent).joined(separator: ", ")
                await MainActor.run {
                    self.busy = false
                    self.status = "Wrote \(names). The original was kept."
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.alertMessage = error.localizedDescription
                    self.status = "Stopped."
                }
            }
        }
    }

    private func loadNote(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 1_000_000 else {
                alertMessage = "That note is over 1 MB. Drop it as a file and choose Character."
                return
            }
            guard let text = String(data: data, encoding: .utf8) else {
                alertMessage = "\(url.lastPathComponent) is not UTF-8 text."
                return
            }
            plaintext = text
            ciphertext = ""
            stale = false
            openedNoteURL = url
            status = "Opened \(url.lastPathComponent)."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func save(_ text: String, suggested: String, title: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggested
        panel.title = title
        panel.message = "The opened note is left where it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let opened = openedNoteURL, DragonFiles.sameFile(opened, url) {
            alertMessage = "That would replace the opened note. Choose another name."
            return
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func encryptFolders() {
        foldFolders(decrypting: false)
    }

    func decryptFolders() {
        foldFolders(decrypting: true)
    }

    private func foldFolders(decrypting: Bool) {
        let urls = decrypting ? files : folders
        guard !urls.isEmpty else {
            alertMessage = decrypting
                ? "Drop the folder package first."
                : "Drop a folder first."
            return
        }
        busy = true
        let phrase = key
        let chosen = folderUnit
        let count = passes
        let scramble = scrambleName
        let method = compression
        let weave = crossWeave
        status = decrypting
            ? "Restoring \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) folders")…"
            : "Packing \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) folders")…"
        Task.detached(priority: .userInitiated) {
            do {
                var written: [URL] = []
                for url in urls {
                    if decrypting {
                        written.append(try DragonFolder.decode(source: url, key: phrase))
                    } else {
                        written.append(try DragonFolder.encode(
                            source: url,
                            key: phrase,
                            unit: chosen,
                            passes: count,
                            scrambleName: scramble,
                            compression: method,
                            crossWeave: weave
                        ))
                    }
                }
                let names = written.map(\.lastPathComponent).joined(separator: ", ")
                await MainActor.run {
                    self.busy = false
                    self.status = decrypting
                        ? "Restored \(names). The package was kept."
                        : "Wrote \(names). The original folder was kept."
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.alertMessage = error.localizedDescription
                    self.status = "Stopped."
                }
            }
        }
    }

    private func passSentence() -> String {
        let count = passTotal
        let noun = count == 1 ? "pass" : "passes"
        if passes != nil {
            return "\(count) \(noun)."
        }
        if key.isEmpty {
            return "No phrase, so the page is read from the top."
        }
        return "\(count) \(noun). The phrase is not stored."
    }
}
