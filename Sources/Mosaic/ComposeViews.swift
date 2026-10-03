import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// The To field of a new-message tile: chosen people as chips, a text field that suggests contacts
/// and existing conversations (including groups) as you type, and the suggestions below it. The
/// list is driven by the mouse (hover highlights, click chooses) and the keyboard (arrows move,
/// Return chooses, Backspace in an empty field removes the last person).
struct RecipientField: View {
    static let lineHeight: CGFloat = 22
    @Environment(WorkspaceStore.self) private var store
    let draftID: String
    @State private var query = ""
    @State private var showsAll = false
    @State private var selection = 0

    private var draft: ComposeDraft { store.composeDrafts[draftID] ?? ComposeDraft() }
    private var suggestions: [RecipientSuggestion] {
        guard showsAll || !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return store.recipientSuggestions(for: query, excluding: draftID)
    }

    var body: some View {
        let suggestions = suggestions
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text("To:").font(.system(size: 13)).foregroundStyle(.secondary).frame(height: Self.lineHeight)
                WrapLayout(spacing: 6, lineHeight: Self.lineHeight) {
                    ForEach(draft.recipients) { recipient in chip(recipient) }
                    RecipientTextField(text: $query, takesFocus: true) { command in handle(command, suggestions) }
                        .accessibilityLabel("Recipients")
                }
                Button { showsAll.toggle() } label: {
                    Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(.primary)
                        .frame(height: Self.lineHeight)
                }.buttonStyle(.plain).help("Choose from your conversations")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.primary.opacity(0.035))
            Divider().opacity(0.6)
            if !suggestions.isEmpty {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                suggestionRow(suggestion, index: index).id(suggestion.id)
                            }
                        }.padding(6)
                    }
                    .frame(maxHeight: 268)
                    .onChange(of: selection) { _, index in
                        if suggestions.indices.contains(index) { scroller.scrollTo(suggestions[index].id) }
                    }
                }
                Divider().opacity(0.6)
            }
        }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: draft.recipients.count) { _, _ in showsAll = false; selection = 0 }
    }

    private func chip(_ recipient: Recipient) -> some View {
        HStack(spacing: 5) {
            Text(recipient.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button { store.removeRecipient(recipient, from: draftID) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain).accessibilityLabel("Remove \(recipient.name)")
        }
        .padding(.horizontal, 9)
        .frame(height: Self.lineHeight)
        .foregroundStyle(.white)
        .background(Palette.accent, in: Capsule())
        .help(recipient.address)
    }

    private func suggestionRow(_ suggestion: RecipientSuggestion, index: Int) -> some View {
        let selected = index == selection
        return Button { choose(suggestion) } label: {
            HStack(spacing: 10) {
                switch suggestion {
                case .contact(let recipient):
                    Avatar(conversation: Conversation(id: recipient.id, name: recipient.name, participants: [recipient.address]), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        highlighted(recipient.name).font(.system(size: 12, weight: .medium))
                        Text(Recipient.display(recipient.address)).font(.system(size: 11)).foregroundStyle(selected ? .primary : .secondary)
                    }
                case .conversation(let conversation):
                    Avatar(conversation: conversation, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        highlighted(conversation.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(conversation.participants.map { Recipient.display(store.name(for: $0)) }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if conversation.isGroup { Image(systemName: "chevron.right.circle").font(.system(size: 14)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Palette.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in if inside { selection = index } }
    }

    /// The typed text in blue inside a name, as Messages does.
    private func highlighted(_ text: String) -> Text {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(text) }
        return Text(text[..<range.lowerBound]) + Text(text[range]).foregroundColor(Palette.accent) + Text(text[range.upperBound...])
    }

    private func choose(_ suggestion: RecipientSuggestion) {
        switch suggestion {
        case .contact(let recipient): store.addRecipient(recipient, to: draftID)
        case .conversation(let conversation): store.addressDraft(draftID, to: conversation)
        }
        query = ""
        showsAll = false
        selection = 0
    }
    /// Keys from the text field. Returns true when the key was used here.
    private func handle(_ command: RecipientTextField.Command, _ suggestions: [RecipientSuggestion]) -> Bool {
        switch command {
        case .moveDown:
            guard !suggestions.isEmpty else { return false }
            selection = min(selection + 1, suggestions.count - 1); return true
        case .moveUp:
            guard !suggestions.isEmpty else { return false }
            selection = max(selection - 1, 0); return true
        case .submit:
            if suggestions.indices.contains(selection) { choose(suggestions[selection]); return true }
            if let first = suggestions.first { choose(first); return true }
            // Nothing to pick: Return moves on to the message once someone is addressed.
            if draft.hasRecipients { store.requestComposerFocus(draftID); return true }
            return false
        case .deleteBackwardWhenEmpty:
            guard let last = draft.recipients.last else { return false }
            store.removeRecipient(last, from: draftID); return true
        case .cancel:
            // Esc closes the new message.
            store.close(draftID)
            return true
        }
    }
}

/// The To field's text input, in AppKit so that Backspace, the arrow keys and Return reach the
/// recipient list before the field's own editor acts on them, and so the field takes the keyboard
/// when its tile appears.
struct RecipientTextField: NSViewRepresentable {
    enum Command { case deleteBackwardWhenEmpty, moveUp, moveDown, submit, cancel }
    @Binding var text: String
    var takesFocus = false
    let onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.cell = CenteredTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.lineBreakMode = .byClipping
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.wantsInitialFocus = takesFocus
        return field
    }
    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }
    /// At least room for a few words, and all the room its line has (see WrapLayout); as tall as the
    /// chips beside it, with the text centered in that height by the cell.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusingTextField, context: Context) -> CGSize? {
        CGSize(width: max(140, proposal.width ?? 140), height: proposal.height ?? RecipientField.lineHeight)
    }

    /// Draws single-line text vertically centered in a cell taller than the text, where
    /// NSTextFieldCell would draw it along the top.
    final class CenteredTextFieldCell: NSTextFieldCell {
        private func centered(_ rect: NSRect) -> NSRect {
            let textHeight = cellSize(forBounds: rect).height
            let inset = (rect.height - textHeight) / 2
            guard inset > 0 else { return rect }
            return NSRect(x: rect.minX, y: rect.minY + inset, width: rect.width, height: textHeight)
        }
        override func drawingRect(forBounds rect: NSRect) -> NSRect { super.drawingRect(forBounds: centered(rect)) }
        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        }
        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: centered(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RecipientTextField
        init(_ parent: RecipientTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.deleteBackward(_:)):
                return textView.string.isEmpty ? parent.onCommand(.deleteBackwardWhenEmpty) : false
            case #selector(NSResponder.moveDown(_:)): return parent.onCommand(.moveDown)
            case #selector(NSResponder.moveUp(_:)): return parent.onCommand(.moveUp)
            case #selector(NSResponder.insertNewline(_:)): return parent.onCommand(.submit)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.cancel)
            default: return false
            }
        }
    }

    final class FocusingTextField: NSTextField {
        var wantsInitialFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard wantsInitialFocus, let window else { return }
            wantsInitialFocus = false
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}

/// Lays out its children left to right, wrapping to new lines as needed. Children are measured at
/// their ideal size, so a text field does not claim a whole line; the last child is given whatever
/// room is left on its line, which is how the To field grows beside the chips before wrapping.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineHeight: CGFloat = 22

    private struct Line { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0 }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            let last = lines.count - 1
            let needed = lines[last].items.isEmpty ? size.width : lines[last].width + spacing + size.width
            if !lines[last].items.isEmpty, needed > width { lines.append(Line()) }
            let current = lines.count - 1
            lines[current].width = lines[current].items.isEmpty ? size.width : lines[current].width + spacing + size.width
            lines[current].items.append((index, size))
        }
        // The last child takes the rest of its line.
        if let lastLine = lines.indices.last, let lastItem = lines[lastLine].items.indices.last {
            let extra = max(0, width - lines[lastLine].width)
            lines[lastLine].items[lastItem].size.width += extra
            lines[lastLine].width += extra
        }
        return lines
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let lines = lines(for: subviews, width: width)
        return CGSize(width: width, height: CGFloat(lines.count) * lineHeight + CGFloat(max(0, lines.count - 1)) * spacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in line.items {
                let height = min(item.size.height, lineHeight)
                subviews[item.index].place(at: CGPoint(x: x, y: y + (lineHeight - height) / 2), anchor: .topLeading,
                                           proposal: ProposedViewSize(width: item.size.width, height: height))
                x += item.size.width + spacing
            }
            y += lineHeight + spacing
        }
    }
}

/// A title-bar-strip button drawn and hit-tested in AppKit (SwiftUI buttons do not get presses
/// there): a symbol with a hover highlight that runs an action on click.
struct StripButton: NSViewRepresentable {
    var symbol: String
    var label: String
    let action: () -> Void

    func makeNSView(context: Context) -> ButtonView { let view = ButtonView(); apply(view); return view }
    func updateNSView(_ view: ButtonView, context: Context) { apply(view) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ButtonView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 28, height: proposal.height ?? 28)
    }
    private func apply(_ view: ButtonView) {
        view.action = action
        view.setAccessibilityLabel(label)
        view.toolTip = label
        if view.symbol != symbol { view.symbol = symbol; view.needsDisplay = true }
    }

    final class ButtonView: NSView {
        var symbol = ""
        var action: (() -> Void)?
        private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
        private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
        private var tracking: NSTrackingArea?

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { hovered = true }
        override func mouseExited(with event: NSEvent) { hovered = false }
        override func mouseDown(with event: NSEvent) { pressed = true }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action?()
        }
        override func accessibilityPerformPress() -> Bool { action?(); return true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

        override func draw(_ dirtyRect: NSRect) {
            if hovered || pressed {
                NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium).applying(.init(paletteColors: [.secondaryLabelColor]))) else { return }
            let size = image.size
            image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}
