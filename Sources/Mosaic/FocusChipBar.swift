import SwiftUI
import AppKit
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// One entry in the focus-mode conversation switcher.
struct FocusChip: Equatable, Identifiable {
    let id: String
    let name: String
    let initials: String
    let isGroup: Bool
    let isSelected: Bool
    /// Something in it is unread (or a message arrived while you were elsewhere).
    var hasUnread = false
    /// Its composer holds something unsent.
    var hasDraft = false

    init(conversation: Conversation, isSelected: Bool, hasUnread: Bool = false, hasDraft: Bool = false) {
        id = conversation.id; name = conversation.name; initials = conversation.initials
        isGroup = conversation.isGroup; self.isSelected = isSelected; self.hasUnread = hasUnread; self.hasDraft = hasDraft
    }
    init(id: String, name: String, initials: String, isGroup: Bool = false, isSelected: Bool = false, hasUnread: Bool = false, hasDraft: Bool = false) {
        self.id = id; self.name = name; self.initials = initials; self.isGroup = isGroup; self.isSelected = isSelected
        self.hasUnread = hasUnread; self.hasDraft = hasDraft
    }

    /// The chips for a set of open tiles, in tile order, with the focused one selected and the
    /// unread and drafted ones marked.
    static func chips(for tiles: [Conversation], focusedID: String?, unread: Set<String> = [], drafts: Set<String> = []) -> [FocusChip] {
        tiles.map { FocusChip(conversation: $0, isSelected: $0.id == focusedID, hasUnread: unread.contains($0.id), hasDraft: drafts.contains($0.id)) }
    }
}

/// The row of conversation chips shown above the tile in Focus layout. It is a single AppKit view
/// that draws and hit-tests every chip itself: the row sits on the window's title bar strip, where
/// SwiftUI controls do not receive clicks reliably but AppKit views that refuse window dragging do.
struct FocusChipBar: NSViewRepresentable {
    static let height: CGFloat = 36
    var chips: [FocusChip]
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> ChipBarView {
        let view = ChipBarView()
        view.chips = chips
        view.onSelect = onSelect
        return view
    }
    func updateNSView(_ view: ChipBarView, context: Context) {
        view.onSelect = onSelect
        if view.chips != chips { view.chips = chips }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChipBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.contentWidth, height: Self.height)
    }

    final class ChipBarView: NSView, NSViewToolTipOwner {
        static let spacing: CGFloat = 8
        static let avatarSize: CGFloat = 22
        static let horizontalPadding: CGFloat = 10
        static let maximumNameWidth: CGFloat = 180
        /// The narrowest a name is cut to before chips show their pictures only.
        static let minimumNameWidth: CGFloat = 36
        var chips: [FocusChip] = [] { didSet { invalidateLayout() } }
        var onSelect: ((String) -> Void)?
        private(set) var frames: [CGRect] = []
        /// How wide each chip's name is drawn: its full width while the row fits, cut to share
        /// the room when it does not (a narrow window with four tiles), nothing at all when even
        /// short names would not fit. A name that is cut shows in full as a tooltip, and
        /// VoiceOver always reads it.
        private(set) var nameWidths: [CGFloat] = []
        private var pressedIndex: Int?
        private var elements: [PressableAccessibilityElement] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel("Open conversations")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var isOpaque: Bool { false }

        private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        private static let initialsFont = NSFont.systemFont(ofSize: 7, weight: .semibold)

        /// The width the chips need when laid out in one row with their names in full.
        var contentWidth: CGFloat {
            zip(chips, chips.map(fullNameWidth)).reduce(0) { $0 + chipWidth($1.0, name: $1.1) } + CGFloat(max(0, chips.count - 1)) * Self.spacing
        }
        private func fullNameWidth(_ chip: FocusChip) -> CGFloat {
            let measured = (chip.name as NSString).size(withAttributes: [.font: Self.nameFont]).width.rounded(.up)
            return min(measured, Self.maximumNameWidth)
        }
        /// Room after the name for the unread dot and the draft mark.
        static let markWidth: CGFloat = 11
        private func marksWidth(_ chip: FocusChip) -> CGFloat {
            CGFloat((chip.hasUnread ? 1 : 0) + (chip.hasDraft ? 1 : 0)) * Self.markWidth
        }
        private func chipWidth(_ chip: FocusChip, name: CGFloat) -> CGFloat {
            Self.horizontalPadding + Self.avatarSize + (name > 0 ? 7 + name : 0) + marksWidth(chip) + Self.horizontalPadding
        }
        /// The names' widths for a row `width` wide (unlimited when zero): every name in full if
        /// they fit; otherwise the long ones are cut to one shared width, so short names stay whole.
        static func fittedNameWidths(_ full: [CGFloat], room: CGFloat?) -> [CGFloat] {
            guard let room, full.reduce(0, +) > room else { return full }
            // The largest cut-off width at which every name, cut, fits in the room.
            var remaining = room
            var cap: CGFloat = 0
            let sorted = full.sorted()
            for (index, width) in sorted.enumerated() {
                let share = remaining / CGFloat(sorted.count - index)
                if width <= share { remaining -= width; cap = width } else { cap = share; break }
            }
            cap = cap.rounded(.down)
            guard cap >= minimumNameWidth else { return full.map { _ in 0 } }
            return full.map { min($0, cap) }
        }
        private func invalidateLayout() {
            let full = chips.map(fullNameWidth)
            // Everything but the names: the pictures, padding, marks, the gap before each name and between chips.
            let fixed = chips.reduce(0) { $0 + chipWidth($1, name: 0) + 7 } + CGFloat(max(0, chips.count - 1)) * Self.spacing
            nameWidths = Self.fittedNameWidths(full, room: bounds.width > 0 ? bounds.width - fixed : nil)
            var x: CGFloat = 0
            frames = zip(chips, nameWidths).map { chip, name in
                let frame = CGRect(x: x, y: 0, width: chipWidth(chip, name: name), height: FocusChipBar.height)
                x += frame.width + Self.spacing
                return frame
            }
            removeAllToolTips()
            for (index, frame) in frames.enumerated() where nameWidths[index] < full[index] {
                addToolTip(frame, owner: self, userData: nil)
            }
            // One accessibility button per chip, so VoiceOver can switch conversations too.
            elements = zip(chips, frames).map { chip, frame in
                let element = PressableAccessibilityElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel("Show \(chip.name)" + (chip.hasUnread ? ", unread" : "") + (chip.hasDraft ? ", draft" : ""))
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(frame)
                element.onPress = { [weak self] in self?.onSelect?(chip.id) }
                return element
            }
            setAccessibilityChildren(elements as [Any])
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
        override func setFrameSize(_ newSize: NSSize) {
            let widthChanged = newSize.width != frame.width
            super.setFrameSize(newSize)
            if widthChanged { invalidateLayout() } else { needsDisplay = true }
        }
        func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
            chipIndex(at: point).map { chips[$0].name } ?? ""
        }
        override func resetCursorRects() {
            for frame in frames { addCursorRect(frame, cursor: .pointingHand) }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        /// The chip under a point in this view's coordinates, if any.
        func chipIndex(at point: NSPoint) -> Int? { frames.firstIndex { $0.contains(point) } }

        override func mouseDown(with event: NSEvent) {
            pressedIndex = chipIndex(at: convert(event.locationInWindow, from: nil))
            needsDisplay = true
        }
        override func mouseUp(with event: NSEvent) {
            defer { pressedIndex = nil; needsDisplay = true }
            guard let pressedIndex, chipIndex(at: convert(event.locationInWindow, from: nil)) == pressedIndex,
                  chips.indices.contains(pressedIndex) else { return }
            onSelect?(chips[pressedIndex].id)
        }

        override func draw(_ dirtyRect: NSRect) {
            for (index, chip) in chips.enumerated() where frames.indices.contains(index) {
                let frame = frames[index]
                if chip.isSelected || pressedIndex == index {
                    let fill = chip.isSelected ? NSColor.controlBackgroundColor : NSColor.labelColor.withAlphaComponent(0.06)
                    fill.setFill()
                    NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()
                }
                // Avatar: a gray disc with initials (or the group symbol), as in the sidebar and tile headers.
                let avatar = CGRect(x: frame.minX + Self.horizontalPadding, y: frame.midY - Self.avatarSize / 2,
                                    width: Self.avatarSize, height: Self.avatarSize)
                NSColor.systemGray.setFill()
                NSBezierPath(ovalIn: avatar).fill()
                if chip.isGroup, let symbol = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold).applying(.init(paletteColors: [.white]))) {
                    let size = symbol.size
                    symbol.draw(in: CGRect(x: avatar.midX - size.width / 2, y: avatar.midY - size.height / 2, width: size.width, height: size.height))
                } else {
                    let initials = chip.initials as NSString
                    let attributes: [NSAttributedString.Key: Any] = [.font: Self.initialsFont, .foregroundColor: NSColor.white]
                    let size = initials.size(withAttributes: attributes)
                    initials.draw(at: CGPoint(x: avatar.midX - size.width / 2, y: avatar.midY - size.height / 2), withAttributes: attributes)
                }
                let shownName = nameWidths.indices.contains(index) ? nameWidths[index] : 0
                let nameX = shownName > 0 ? avatar.maxX + 7 : avatar.maxX
                let nameRect = CGRect(x: nameX, y: frame.minY, width: shownName, height: frame.height)
                // After the name: a blue dot for unread, an orange one for a draft.
                var markX = nameRect.maxX + 5
                for (shown, color) in [(chip.hasUnread, NSColor.systemBlue), (chip.hasDraft, NSColor.systemOrange)] where shown {
                    color.setFill()
                    NSBezierPath(ovalIn: CGRect(x: markX, y: frame.midY - 3, width: 6, height: 6)).fill()
                    markX += Self.markWidth
                }
                guard shownName > 0 else { continue }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let attributes: [NSAttributedString.Key: Any] = [.font: Self.nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
                let textHeight = (chip.name as NSString).size(withAttributes: attributes).height
                (chip.name as NSString).draw(in: CGRect(x: nameRect.minX, y: nameRect.midY - textHeight / 2, width: nameRect.width, height: textHeight),
                                            withAttributes: attributes)
            }
        }
    }
}
