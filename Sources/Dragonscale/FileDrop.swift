import AppKit
import SwiftUI

/// Where one dropped file is applied. Two files always fill both wells.
enum DropLanding: Equatable {
    case first
    case second
    /// The file replaces the first picture. The whole window shows the drop outline.
    case window
}

enum DropTarget {
    /// `point` uses the top-left origin, in the same space as the well frames.
    /// A point in a well's column still counts when the vertical position misses the frame.
    /// While the second picture is the night card, a drop outside the left well replaces that card.
    static func choose(
        point: CGPoint?,
        pairOn: Bool,
        first: CGRect,
        second: CGRect,
        secondIsStandIn: Bool
    ) -> DropLanding {
        guard pairOn else { return .window }
        guard let point else { return secondIsStandIn ? .second : .window }
        if contains(second, point) { return .second }
        if contains(first, point) { return .first }
        if inColumn(second, x: point.x), !inColumn(first, x: point.x) { return .second }
        if inColumn(first, x: point.x), !inColumn(second, x: point.x) { return .first }
        return secondIsStandIn ? .second : .window
    }

    private static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        rect.width > 0 && rect.height > 0 && rect.contains(point)
    }

    private static func inColumn(_ rect: CGRect, x: CGFloat) -> Bool {
        rect.width > 0 && x >= rect.minX && x < rect.maxX
    }
}

struct FileDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onHover: (CGPoint?) -> Void
    let onDrop: ([URL], CGPoint) -> Void

    func body(content: Content) -> some View {
        content.background(FileDropCatcher(isTargeted: $isTargeted, onHover: onHover, onDrop: onDrop))
    }
}

extension View {
    /// `point` is in the view, with the origin at the top left.
    func onFileDrop(
        isTargeted: Binding<Bool>,
        hover: @escaping (CGPoint?) -> Void = { _ in },
        perform: @escaping ([URL], CGPoint) -> Void
    ) -> some View {
        modifier(FileDropModifier(isTargeted: isTargeted, onHover: hover, onDrop: perform))
    }
}

private struct FileDropCatcher: NSViewRepresentable {
    @Binding var isTargeted: Bool
    let onHover: (CGPoint?) -> Void
    let onDrop: ([URL], CGPoint) -> Void

    func makeNSView(context: Context) -> DropNSView {
        let view = DropNSView()
        view.onDrop = onDrop
        view.onHover = onHover
        view.isTargeted = $isTargeted
        return view
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.onHover = onHover
        nsView.isTargeted = $isTargeted
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DropNSView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class DropNSView: NSView {
    var onDrop: (([URL], CGPoint) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var isTargeted: Binding<Bool>?

    override var isFlipped: Bool { true }

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
        report(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasFiles(sender) else { return [] }
        report(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = topLeftPoint(sender)
        setTargeted(false)
        guard let urls = files(from: sender), !urls.isEmpty else { return false }
        onDrop?(urls, point)
        return true
    }

    private func report(_ sender: NSDraggingInfo) {
        let point = topLeftPoint(sender)
        DispatchQueue.main.async {
            self.isTargeted?.wrappedValue = true
            self.onHover?(point)
        }
    }

    /// The view is flipped, so this matches the SwiftUI frames: origin at the top left.
    private func topLeftPoint(_ sender: NSDraggingInfo) -> CGPoint {
        convert(sender.draggingLocation, from: nil)
    }

    private func setTargeted(_ value: Bool) {
        DispatchQueue.main.async {
            self.isTargeted?.wrappedValue = value
            if !value { self.onHover?(nil) }
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
