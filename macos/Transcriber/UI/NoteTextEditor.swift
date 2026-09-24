import AppKit
import SwiftUI

/// Plain text editor that inserts two spaces on Tab.
/// Return inserts a newline. Command-Return runs `onCommandReturn` when provided.
struct NoteTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommandReturn: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommandReturn: onCommandReturn)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let contentSize = scroll.contentSize
        let textView = NoteNSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.delegate = context.coordinator
        textView.onCommandReturn = { [weak coordinator = context.coordinator] in
            coordinator?.onCommandReturn?()
        }
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor(white: 0.9, alpha: 1)
        textView.backgroundColor = NSColor(white: 0.1, alpha: 1)
        textView.insertionPointColor = .white
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NoteNSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.onCommandReturn = onCommandReturn
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onCommandReturn: (() -> Void)?

        init(text: Binding<String>, onCommandReturn: (() -> Void)?) {
            self.text = text
            self.onCommandReturn = onCommandReturn
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
    }
}

private final class NoteNSTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    private var lastCommandReturnTimestamp: TimeInterval?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCommandReturn(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleCommandReturn(event) {
            return
        }
        super.keyDown(with: event)
    }

    /// Command-Return submits. Return still inserts a newline through the text system.
    private func handleCommandReturn(_ event: NSEvent) -> Bool {
        guard Self.isCommandReturn(event), window?.firstResponder === self else { return false }
        guard let onCommandReturn else { return false }
        if event.timestamp == lastCommandReturnTimestamp { return true }
        lastCommandReturnTimestamp = event.timestamp
        onCommandReturn()
        return true
    }

    static func isCommandReturn(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard flags == .command else { return false }
        return event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode
    }

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
}
