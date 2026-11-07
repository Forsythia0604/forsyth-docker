import Foundation
import CoreGraphics

struct WindowIntent: Sendable {
    private(set) var manuallyPlaced = false
    private(set) var source: CGRect?
    private(set) var target: CGRect?
    private(set) var observed: CGRect?

    static func near(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func isManualDrag(initial: CGRect, final: CGRect, dragged: Bool, changedDuringDrag: Bool,
                             pointerTravel: CGFloat = 0) -> Bool {
        // Final pointer displacement also covers an interaction whose
        // intermediate drag events were not observed by the helper.
        let pointerMoved = pointerTravel.isFinite && pointerTravel >= 3
        return (dragged || pointerMoved) && (changedDuringDrag || !near(initial, final))
    }

    mutating func userDragged(to frame: CGRect) {
        manuallyPlaced = true
        source = nil; target = nil; observed = frame
    }

    /// Geometry changes alone never revoke manual placement. A later native
    /// layout must actually change this window before it can become managed.
    mutating func resolve(frame: CGRect, nativeSource: CGRect?) -> CGRect? {
        if let observed, Self.near(frame, observed) {
            return manuallyPlaced ? nil : source
        }
        observed = frame
        if let nativeSource {
            manuallyPlaced = false; source = nativeSource; target = nil
            return nativeSource
        }
        source = nil; target = nil
        return nil
    }

    mutating func applied(source: CGRect, target: CGRect, actual: CGRect) {
        manuallyPlaced = false
        self.source = source; self.target = target; observed = actual
    }
}
