import AppKit
import SwiftUI

struct FileDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func body(content: Content) -> some View {
        content.background(FileDropCatcher(isTargeted: $isTargeted, onDrop: onDrop))
    }
}

extension View {
    func onFileDrop(isTargeted: Binding<Bool>, perform: @escaping ([URL]) -> Void) -> some View {
        modifier(FileDropModifier(isTargeted: isTargeted, onDrop: perform))
    }
}

private struct FileDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> DropNSView {
        let view = DropNSView()
        view.onDrop = onDrop
        view.isTargeted = $isTargeted
        return view
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.isTargeted = $isTargeted
    }
}

final class DropNSView: NSView {
    var onDrop: (([URL]) -> Void)?
    var isTargeted: Binding<Bool>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let board = NSPasteboard(name: .drag)
        let hasFile = board.canReadObject(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ])
        return hasFile ? self : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        setTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        guard let urls = files(from: sender), !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func setTargeted(_ value: Bool) {
        DispatchQueue.main.async {
            self.isTargeted?.wrappedValue = value
        }
    }

    private func hasFiles(_ sender: NSDraggingInfo) -> Bool {
        files(from: sender)?.isEmpty == false
    }

    private func files(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL]
    }
}
