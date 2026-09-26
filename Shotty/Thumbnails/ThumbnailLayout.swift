import CoreGraphics
import Foundation

/// Pure stack rules from the build contract: 8 pt gaps, 160 pt maximum previews,
/// newest card nearest the anchor, and an "N more" row instead of offscreen cards.
enum ThumbnailLayout {
    static let gap: CGFloat = 8
    static let overflowRowHeight: CGFloat = 32

    static func previewHeight(width: CGFloat) -> CGFloat {
        // A stable card ratio gives hover controls breathing room and keeps the stack calm.
        min(ThumbnailSize.maximumPreviewHeight, max(140, (width * 8 / 11).rounded()))
    }

    /// Fill the card edge to edge, without distorting the source or adding letterboxing.
    static func imageRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// `heights` is newest first. Returns how many of the newest cards fit in `available`
    /// together with, when some remain, the overflow row. At least one card
    /// stays visible so a very short display still offers the newest capture.
    static func visibleCount(heights: [CGFloat], available: CGFloat) -> Int {
        var used: CGFloat = 0
        for (index, height) in heights.enumerated() {
            let remaining = heights.count - index - 1
            let next = used + height + (index > 0 ? gap : 0)
            let reserve = remaining > 0 ? gap + overflowRowHeight : 0
            if next + reserve > available { return max(1, index) }
            used = next
        }
        return heights.count
    }

    /// Top-to-bottom display order: bottom anchors put the newest card at the bottom.
    static func displayOrder<Card>(_ newestFirst: [Card], placement: ThumbnailPlacement) -> [Card] {
        switch placement {
        case .bottomLeft, .bottomRight: newestFirst.reversed()
        default: newestFirst
        }
    }

    static func anchoredLeft(_ placement: ThumbnailPlacement) -> Bool {
        [.topLeft, .leftCenter, .bottomLeft].contains(placement)
    }
}

/// Accumulates one trackpad scroll gesture. A swipe dismisses only when the fingers moved at
/// least 60 pt toward the anchored screen edge with clearly horizontal intent.
struct ThumbnailSwipe {
    static let threshold: CGFloat = 60
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0

    mutating func reset() { dx = 0; dy = 0 }

    /// Deltas are physical finger movement: positive x is rightward.
    mutating func add(dx: CGFloat, dy: CGFloat) { self.dx += dx; self.dy += dy }

    func dismisses(anchoredLeft: Bool) -> Bool {
        let towardEdge = anchoredLeft ? -dx : dx
        return towardEdge >= Self.threshold && abs(dx) > 2 * abs(dy)
    }
}

/// Auto-close time elapses only while nothing pauses the card, so hover, keyboard use,
/// an open editor, or a failed save never race the timeout.
struct ThumbnailCountdown {
    private(set) var remaining: [UUID: TimeInterval] = [:]

    mutating func start(_ id: UUID, seconds: TimeInterval) { remaining[id] = seconds }
    mutating func cancel(_ id: UUID) { remaining.removeValue(forKey: id) }
    var isEmpty: Bool { remaining.isEmpty }

    /// Advances unpaused cards and returns the expired ones, oldest deadline first.
    mutating func advance(by elapsed: TimeInterval, isPaused: (UUID) -> Bool) -> [UUID] {
        var expired: [(UUID, TimeInterval)] = []
        for (id, value) in remaining where !isPaused(id) {
            let next = value - elapsed
            if next <= 0 { expired.append((id, next)); remaining.removeValue(forKey: id) } else { remaining[id] = next }
        }
        return expired.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
