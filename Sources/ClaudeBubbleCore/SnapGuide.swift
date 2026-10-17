import CoreGraphics

/// Drag-to-centre snapping, like Raycast's window: within `snapIn` of the centre the dragged thing jumps to it and
/// stays there until dragged `breakOut` away, while two dashed guides mark where it sits.
public struct SnapGuide {
    public static let snapIn: CGFloat = 12
    public static let breakOut: CGFloat = 24

    public private(set) var snapped = false

    public init() {}

    /// Where the dragged thing's centre goes on one axis, given where the pointer would put it.
    public mutating func apply(_ value: CGFloat, centre: CGFloat) -> CGFloat {
        let distance = abs(value - centre)
        snapped = snapped ? distance <= Self.breakOut : distance <= Self.snapIn
        return snapped ? centre : value
    }

    public mutating func reset() { snapped = false }

    /// The two guides: either side of a thing `extent` wide, centred on `centre`.
    public static func lines(centre: CGFloat, extent: CGFloat) -> (CGFloat, CGFloat) {
        (centre - extent / 2, centre + extent / 2)
    }
}
