import AppKit
import SwiftUI

/// Plain monospaced editor. Substitutions stay off so a ciphertext is not rewritten.
struct InkTextView: NSViewRepresentable {
    @Binding var text: String
    var onEdit: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onEdit: onEdit)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(srgbRed: 0.95, green: 0.91, blue: 0.82, alpha: 1)
        textView.insertionPointColor = NSColor(srgbRed: 0.86, green: 0.68, blue: 0.36, alpha: 1)
        textView.backgroundColor = NSColor(srgbRed: 0.14, green: 0.11, blue: 0.09, alpha: 1)
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEdit = onEdit
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEdit: () -> Void

        init(text: Binding<String>, onEdit: @escaping () -> Void) {
            self.text = text
            self.onEdit = onEdit
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            guard text.wrappedValue != view.string else { return }
            text.wrappedValue = view.string
            onEdit()
        }
    }
}
