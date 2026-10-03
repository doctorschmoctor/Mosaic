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

    init(conversation: Conversation, isSelected: Bool) {
        id = conversation.id; name = conversation.name; initials = conversation.initials
        isGroup = conversation.isGroup; self.isSelected = isSelected
    }
    init(id: String, name: String, initials: String, isGroup: Bool = false, isSelected: Bool = false) {
        self.id = id; self.name = name; self.initials = initials; self.isGroup = isGroup; self.isSelected = isSelected
    }

    /// The chips for a set of open tiles, in tile order, with the focused one selected.
    static func chips(for tiles: [Conversation], focusedID: String?) -> [FocusChip] {
        tiles.map { FocusChip(conversation: $0, isSelected: $0.id == focusedID) }
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

    final class ChipBarView: NSView {
        static let spacing: CGFloat = 8
        static let avatarSize: CGFloat = 22
        static let horizontalPadding: CGFloat = 10
        static let maximumNameWidth: CGFloat = 180
        var chips: [FocusChip] = [] { didSet { invalidateLayout() } }
        var onSelect: ((String) -> Void)?
        private(set) var frames: [CGRect] = []
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

        /// The width the chips need when laid out in one row.
        var contentWidth: CGFloat {
            let widths = chips.map(chipWidth)
            return widths.reduce(0, +) + CGFloat(max(0, chips.count - 1)) * Self.spacing
        }
        private func nameWidth(_ chip: FocusChip) -> CGFloat {
            let measured = (chip.name as NSString).size(withAttributes: [.font: Self.nameFont]).width.rounded(.up)
            return min(measured, Self.maximumNameWidth)
        }
        private func chipWidth(_ chip: FocusChip) -> CGFloat {
            Self.horizontalPadding + Self.avatarSize + 7 + nameWidth(chip) + Self.horizontalPadding
        }
        private func invalidateLayout() {
            var x: CGFloat = 0
            frames = chips.map { chip in
                let frame = CGRect(x: x, y: 0, width: chipWidth(chip), height: FocusChipBar.height)
                x += frame.width + Self.spacing
                return frame
            }
            // One accessibility button per chip, so VoiceOver can switch conversations too.
            elements = zip(chips, frames).map { chip, frame in
                let element = PressableAccessibilityElement()
                element.setAccessibilityRole(.button)
                element.setAccessibilityLabel("Show \(chip.name)")
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
            super.setFrameSize(newSize)
            needsDisplay = true
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
                let nameX = avatar.maxX + 7
                let nameRect = CGRect(x: nameX, y: frame.minY, width: frame.maxX - Self.horizontalPadding - nameX, height: frame.height)
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
