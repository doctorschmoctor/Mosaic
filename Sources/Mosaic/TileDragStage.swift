import AppKit
import SwiftUI
import QuartzCore

/// A held tile is moved as a picture of itself. Moving the tile itself had SwiftUI place every
/// view inside it again on each frame — the thread's rows, the composer, the header — which with
/// a long conversation took longer than a frame. A picture is one Core Animation layer: moving
/// it costs nothing on the main thread. The picture is made when the header is pressed, while
/// nothing on screen moves (a drag may follow), and the tile itself is hidden under it until it
/// is let go; then the tile springs into its place from where it was dropped, as before.
@MainActor final class TileDragStage {
    /// The view the picture is shown in: it covers the tile canvas, above every tile.
    weak var view: TileStageView?
    private var picture: (id: String, image: CGImage, size: CGSize)?
    /// The moving picture: a layer that casts the lifted tile's shadow, holding the picture with
    /// the tile's rounded corners.
    private var lifted: CALayer?
    private var liftedSize: CGSize = .zero

    static let cornerRadius: CGFloat = 13
    /// How much larger a lifted tile is drawn (`TileMotion`).
    static let liftScale: CGFloat = 1.015

    /// Makes a picture of the tile at `frame` (canvas coordinates), for a drag that may follow.
    /// Nothing is made for a tile not wholly in view.
    func capture(_ id: String, frame: CGRect) {
        picture = nil
        guard let view, let hosting = view.window?.contentView, view.bounds.height > 0, lifted == nil else { return }
        let local = rect(frame, in: view)
        guard view.visibleRect.insetBy(dx: -1, dy: -1).contains(local) else { return }
        let start = CACurrentMediaTime()
        let area = hosting.convert(local, from: view)
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: area) else { return }
        hosting.cacheDisplay(in: area, to: bitmap)
        guard let image = bitmap.cgImage else { return }
        picture = (id, image, frame.size)
        TileTrace.note("picture taken in \(Int((CACurrentMediaTime() - start) * 1000)) ms")
    }

    /// Starts moving the picture of `id` from `frame`; false when there is none of this tile at
    /// this size (the tile then moves itself).
    func begin(_ id: String, frame: CGRect, lift: Bool) -> Bool {
        guard let view, let layer = view.layer, let picture, picture.id == id,
              abs(picture.size.width - frame.width) < 1, abs(picture.size.height - frame.height) < 1 else { return false }
        lifted?.removeFromSuperlayer()
        let scale = view.window?.backingScaleFactor ?? 2
        let holder = CALayer()
        holder.frame = rect(frame, in: view)
        holder.shadowColor = NSColor.black.cgColor
        holder.shadowRadius = 24
        holder.shadowOffset = CGSize(width: 0, height: -12)
        holder.shadowPath = CGPath(roundedRect: holder.bounds, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        let image = CALayer()
        image.frame = holder.bounds
        image.contents = picture.image
        image.contentsGravity = .resize
        image.contentsScale = scale
        image.cornerRadius = Self.cornerRadius
        image.cornerCurve = .continuous
        image.masksToBounds = true
        holder.addSublayer(image)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holder.shadowOpacity = 0.22
        // Larger only with motion (Reduce Motion keeps the tile's size, as TileMotion does).
        if lift { holder.transform = CATransform3DMakeScale(Self.liftScale, Self.liftScale, 1) }
        layer.addSublayer(holder)
        CATransaction.commit()
        if lift {
            // Picked up: it lifts off the board, as the tile itself did.
            holder.add(Self.spring("transform.scale", from: 1, to: Self.liftScale), forKey: "lift")
            holder.add(Self.spring("shadowOpacity", from: 0, to: 0.22), forKey: "shadow")
        }
        lifted = holder
        liftedSize = frame.size
        self.picture = nil
        return true
    }

    /// Puts the picture's top-left corner at `origin` (canvas coordinates), at once.
    func move(to origin: CGPoint) {
        guard let lifted, let view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lifted.frame = rect(CGRect(origin: origin, size: liftedSize), in: view)
        CATransaction.commit()
    }

    /// The tile is back (shown where the picture is): the picture goes on the next frame, so the
    /// two are never both missing.
    func end() {
        guard let layer = lifted else { return }
        lifted = nil
        picture = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.034) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeFromSuperlayer()
            CATransaction.commit()
        }
    }

    /// A canvas rectangle (top-left origin, growing down) in the stage view's coordinates.
    private func rect(_ canvas: CGRect, in view: NSView) -> CGRect {
        CGRect(x: canvas.minX, y: view.bounds.height - canvas.maxY, width: canvas.width, height: canvas.height)
    }

    /// The tiles' spring (`WorkspaceStore.tileSpring`: response 0.3 s, damping 0.86) for Core Animation.
    private static func spring(_ keyPath: String, from: Double, to: Double) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = pow(2 * .pi / 0.3, 2)
        animation.damping = 4 * .pi * 0.86 / 0.3
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}

/// The view the held tile's picture moves in. It draws nothing itself and takes no clicks.
final class TileStageView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The stage, laid out over the whole tile canvas.
struct TileStage: NSViewRepresentable {
    let stage: TileDragStage
    func makeNSView(context: Context) -> TileStageView {
        let view = TileStageView()
        stage.view = view
        return view
    }
    func updateNSView(_ view: TileStageView, context: Context) { stage.view = view }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TileStageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
