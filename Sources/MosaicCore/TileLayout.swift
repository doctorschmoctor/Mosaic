import Foundation
import CoreGraphics

public struct TileDivider: Identifiable, Equatable {
    public enum Kind: Hashable { case gridColumn(Int), row(Int), column(Int) }
    public let kind: Kind
    public let frame: CGRect
    public var id: Kind { kind }
    public var movesHorizontally: Bool {
        switch kind { case .row: return false; default: return true }
    }
}

public struct TilePlan {
    public let size: CGSize
    public let order: [String]
    public let frames: [String: CGRect]
    public let dividers: [TileDivider]
    public let rowSizes: [CGFloat]
    public let columnSizes: [CGFloat]
}

public enum TileLayout {
    public static let gap: CGFloat = 9
    public static let inset: CGFloat = 4
    public static let minimumHeight: CGFloat = 235
    public static let minimumWidth: CGFloat = 275

    /// `topInset` keeps the top of the canvas free (Focus puts its chip row there): the plan's
    /// size still covers the whole viewport, and the tiles sit below the inset.
    public static func plan(order: [String], viewport: CGSize, layout: WorkspaceLayout,
                            gridFractions: [Int: CGFloat] = [:], rowWeights: [CGFloat] = [],
                            columnWeights: [CGFloat] = [], topInset: CGFloat = 0) -> TilePlan {
        let count = order.count
        let rows = layout == .grid ? max(1, (count + 1) / 2) : 1
        // The grid always fits the window: rows share its height, shrinking below their preferred
        // minimum when many are open rather than scrolling. Columns may extend sideways.
        let size = CGSize(width: layout == .columns ? max(viewport.width, CGFloat(count) * 300 + CGFloat(max(0, count - 1)) * gap + inset * 2) : viewport.width,
                          height: viewport.height)
        let top = max(0, min(topInset, size.height))
        let bounds = CGRect(x: 0, y: top, width: size.width, height: size.height - top).insetBy(dx: inset, dy: inset)
        var frames: [String: CGRect] = [:]
        var dividers: [TileDivider] = []
        var rowSizes: [CGFloat] = []
        var columnSizes: [CGFloat] = []
        if layout == .grid {
            rowSizes = distribute(total: bounds.height - CGFloat(rows - 1) * gap, count: rows, minimum: minimumHeight, weights: rowWeights)
            var y = bounds.minY
            for row in 0..<rows {
                let index = row * 2
                guard index < count else { break }
                let height = rowSizes[row]
                if index + 1 < count {
                    let available = bounds.width - gap
                    let fraction = gridFractions[row] ?? 0.5
                    let width = min(max(available * fraction, minimumWidth), available - minimumWidth)
                    frames[order[index]] = CGRect(x: bounds.minX, y: y, width: width, height: height)
                    frames[order[index + 1]] = CGRect(x: bounds.minX + width + gap, y: y, width: available - width, height: height)
                    dividers.append(TileDivider(kind: .gridColumn(row), frame: CGRect(x: bounds.minX + width, y: y, width: gap, height: height)))
                } else { frames[order[index]] = CGRect(x: bounds.minX, y: y, width: bounds.width, height: height) }
                y += height
                if row + 1 < rows {
                    dividers.append(TileDivider(kind: .row(row), frame: CGRect(x: bounds.minX, y: y, width: bounds.width, height: gap)))
                    y += gap
                }
            }
        } else if layout == .columns {
            columnSizes = distribute(total: bounds.width - CGFloat(max(0, count - 1)) * gap, count: count, minimum: 300, weights: columnWeights)
            var x = bounds.minX
            for index in order.indices {
                let width = columnSizes[index]
                frames[order[index]] = CGRect(x: x, y: bounds.minY, width: width, height: bounds.height)
                x += width
                if index + 1 < count {
                    dividers.append(TileDivider(kind: .column(index), frame: CGRect(x: x, y: bounds.minY, width: gap, height: bounds.height)))
                    x += gap
                }
            }
        } else if let first = order.first { frames[first] = bounds }
        return TilePlan(size: size, order: order, frames: frames, dividers: dividers, rowSizes: rowSizes, columnSizes: columnSizes)
    }

    /// Preserve proportions while guaranteeing minimum sizes after a window resize.
    public static func distribute(total: CGFloat, count: Int, minimum: CGFloat, weights: [CGFloat]) -> [CGFloat] {
        guard count > 0 else { return [] }
        let floor = min(minimum, max(0, total / CGFloat(count)))
        let weights = weights.count == count ? weights.map { max(0.001, $0) } : Array(repeating: 1, count: count)
        var result = Array(repeating: CGFloat.zero, count: count)
        var remaining = Set(0..<count)
        var available = total
        while !remaining.isEmpty {
            let sum = remaining.reduce(CGFloat.zero) { $0 + weights[$1] }
            let small = remaining.filter { available * weights[$0] / sum < floor }
            if small.isEmpty {
                for index in remaining { result[index] = available * weights[index] / sum }
                break
            }
            for index in small { result[index] = floor; available -= floor; remaining.remove(index) }
        }
        return result
    }

    public static func resizedPair(_ sizes: [CGFloat], at index: Int, delta: CGFloat, minimum: CGFloat) -> [CGFloat] {
        guard sizes.indices.contains(index), sizes.indices.contains(index + 1) else { return sizes }
        var result = sizes
        let total = sizes[index] + sizes[index + 1]
        result[index] = min(max(sizes[index] + delta, minimum), total - minimum)
        result[index + 1] = total - result[index]
        return result
    }
}

public struct TileDragSession: Equatable {
    public let id: String
    public let origin: CGRect
    public var translation: CGSize = .zero
    public private(set) var order: [String]
    public var frame: CGRect { origin.offsetBy(dx: translation.width, dy: translation.height) }
    public init(id: String, origin: CGRect, order: [String]) { self.id = id; self.origin = origin; self.order = order }
    public mutating func update(translation: CGSize, plan: TilePlan) {
        self.translation = translation
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // A smaller landing area avoids jitter when crossing gaps or tile edges.
        guard let target = order.first(where: { candidate in
            guard let rect = plan.frames[candidate] else { return false }
            return rect.insetBy(dx: min(30, rect.width * 0.12), dy: min(30, rect.height * 0.12)).contains(center)
        }), target != id, let sourceIndex = order.firstIndex(of: id), let targetIndex = order.firstIndex(of: target) else { return }
        order.remove(at: sourceIndex)
        order.insert(id, at: targetIndex)
    }
}
