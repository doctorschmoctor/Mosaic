import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// The To field of a new-message tile: chosen people as chips, a text field that suggests contacts
/// and existing conversations (including groups) as you type, and the suggestions below it.
struct RecipientField: View {
    @Environment(WorkspaceStore.self) private var store
    let draftID: String
    @State private var query = ""
    @State private var showsAll = false
    @FocusState private var focused: Bool

    private var draft: ComposeDraft { store.composeDrafts[draftID] ?? ComposeDraft() }
    private var suggestions: [RecipientSuggestion] {
        guard focused || showsAll || !query.isEmpty else { return [] }
        guard showsAll || !query.isEmpty else { return [] }
        return store.recipientSuggestions(for: query, excluding: draftID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text("To:").font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 3)
                WrapLayout(spacing: 6) {
                    ForEach(draft.recipients) { recipient in chip(recipient) }
                    TextField("", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .frame(minWidth: 120)
                        .focused($focused)
                        .onSubmit(commit)
                        .onKeyPress(.delete) {
                            // Backspace in an empty field removes the last person.
                            guard query.isEmpty, let last = draft.recipients.last else { return .ignored }
                            store.removeRecipient(last, from: draftID)
                            return .handled
                        }
                        .accessibilityLabel("Recipients")
                }
                Button { showsAll.toggle(); focused = true } label: {
                    Image(systemName: "plus.circle").font(.system(size: 15)).foregroundStyle(.primary)
                }.buttonStyle(.plain).help("Choose from your conversations")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color.primary.opacity(0.035))
            Divider().opacity(0.6)
            if !suggestions.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(suggestions) { suggestion in suggestionRow(suggestion) }
                    }.padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
                Divider().opacity(0.6)
            }
        }
        .onAppear { focused = true }
        .onChange(of: draft.recipients.count) { _, _ in showsAll = false }
    }

    private func chip(_ recipient: Recipient) -> some View {
        HStack(spacing: 4) {
            Text(recipient.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button { store.removeRecipient(recipient, from: draftID) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain).accessibilityLabel("Remove \(recipient.name)")
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(.white)
        .background(Palette.accent, in: Capsule())
        .help(recipient.address)
    }

    private func suggestionRow(_ suggestion: RecipientSuggestion) -> some View {
        Button { choose(suggestion) } label: {
            HStack(spacing: 10) {
                switch suggestion {
                case .contact(let recipient):
                    Avatar(conversation: Conversation(id: recipient.id, name: recipient.name, participants: [recipient.address]), size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        highlighted(recipient.name).font(.system(size: 12, weight: .medium))
                        Text(Recipient.display(recipient.address)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .conversation(let conversation):
                    Avatar(conversation: conversation, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        highlighted(conversation.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(conversation.participants.map { Recipient.display(store.name(for: $0)) }.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if conversation.isGroup { Image(systemName: "chevron.right.circle").font(.system(size: 14)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileControlStyle())
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
        focused = true
    }
    /// Return takes the first suggestion (a typed handle counts as one).
    private func commit() {
        if let first = suggestions.first { choose(first) }
        else if !query.isEmpty, draft.hasRecipients { store.requestComposerFocus(draftID) }
    }
}

/// Lays out its children left to right, wrapping to new lines as needed.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : maxX, height: y + lineHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineHeight + spacing; lineHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
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
