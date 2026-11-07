import Foundation
import CoreGraphics

@main
struct WindowBehaviorTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(value(), message)
        }
        let native = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let fitted = CGRect(x: 0, y: 105, width: 1200, height: 695)
        let floating = CGRect(x: 80, y: 0, width: 500, height: 370)
        var state = WindowIntent()
        check(state.resolve(frame: native, nativeSource: native) == native, "Native maximize is managed")
        state.applied(source: native, target: fitted, actual: fitted)
        check(state.resolve(frame: fitted, nativeSource: native) == native, "Resizing Dock retains original maximize intent")
        state.userDragged(to: floating)
        check(state.resolve(frame: floating, nativeSource: nil) == nil, "Manual overlap is not corrected")
        check(state.manuallyPlaced, "Manual override is retained")
        state.userDragged(to: native)
        check(state.resolve(frame: native, nativeSource: native) == nil, "Manual resize to a full-screen-shaped frame remains manual")
        check(state.resolve(frame: native, nativeSource: native) == nil, "Changing the Dock alone cannot take over a manual window")
        var second = WindowIntent()
        check(second.resolve(frame: native, nativeSource: native) == native, "Different window with identical geometry is independently managed")
        check(state.resolve(frame: floating, nativeSource: nil) == nil, "Free window is preserved")
        check(state.resolve(frame: native, nativeSource: native) == native, "Later native maximize opts back into avoidance")
        state.userDragged(to: floating)
        state.applied(source: native, target: fitted, actual: fitted)
        check(!state.manuallyPlaced, "Explicit maximize resets manual override")
        check(!WindowIntent.isManualDrag(initial: native, final: fitted, dragged: false, changedDuringDrag: false), "Zoom-button resize is not a drag")
        check(!WindowIntent.isManualDrag(initial: native, final: native, dragged: true, changedDuringDrag: false), "Text selection does not surrender maximize intent")
        check(WindowIntent.isManualDrag(initial: native, final: floating, dragged: true, changedDuringDrag: false), "Dragging a border or title bar is manual")
        check(WindowIntent.isManualDrag(initial: native, final: native, dragged: true, changedDuringDrag: true), "Dragging back to the starting frame still preserves manual intent")
        check(WindowIntent.isManualDrag(initial: native, final: floating, dragged: false, changedDuringDrag: false, pointerTravel: 30), "Native drag is manual even when intermediate drag events are absent")
        check(!WindowIntent.isManualDrag(initial: native, final: fitted, dragged: false, changedDuringDrag: false, pointerTravel: 2), "Zoom-button click jitter must not override native maximize intent")
        check(!WindowIntent.isManualDrag(initial: native, final: native, dragged: false, changedDuringDrag: false, pointerTravel: 30), "Pointer movement without a window change remains a content interaction")
        check(!WindowIntent.isManualDrag(initial: native, final: fitted, dragged: false, changedDuringDrag: false, pointerTravel: .infinity), "Invalid pointer evidence does not create a manual override")
        check(WindowIntent.isManualDrag(initial: native, final: native, dragged: false, changedDuringDrag: true, pointerTravel: 30), "Observed movement back to the same frame is still manual without intermediate events")
        check(DockResizeMetrics.size(start: 81, verticalDelta: 20) == 101, "Upward drag enlarges Dock")
        check(DockResizeMetrics.size(start: 81, verticalDelta: -20) == 61, "Downward drag shrinks Dock")
        check(DockResizeMetrics.size(start: 81, verticalDelta: -1000) == 40, "Minimum size is enforced")
        check(DockResizeMetrics.size(start: 81, verticalDelta: 1000) == 112, "Maximum size is enforced")
        check(DockResizeMetrics.size(start: 81, verticalDelta: .infinity) == 81, "Invalid pointer delta is rejected")
        check(DockResizeMetrics.size(start: 81, translation: CGPoint(x: 40, y: 0), edge: .right, slotCount: 8, scale: 1) == 91, "Right edge accounts for centered Dock width")
        check(DockResizeMetrics.size(start: 81, translation: CGPoint(x: -40, y: 0), edge: .left, slotCount: 8, scale: 1) == 91, "Left edge expands symmetrically")
        check(DockResizeMetrics.size(start: 81, translation: CGPoint(x: 0, y: 10), edge: .top, slotCount: 8, scale: 0.5) == 101, "Top edge handles scaled Dock geometry")
        check(DockResizeMetrics.size(start: 81, translation: CGPoint(x: 0, y: 20), edge: .bottom, slotCount: 8, scale: 1) == 61, "Bottom edge adjusts size while keeping screen anchoring")
        let oldPacket = Data(#"{"schemaVersion":1,"session":"old","processID":1,"timestamp":1,"enabled":true,"commands":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(DockWindowPacket.self, from: oldPacket)
        check(decoded.dockResizing == nil, "Old packets remain decodable")
        func status(_ code: String, fullscreen: Bool? = nil) -> DockWindowStatus {
            var value = DockWindowStatus(schemaVersion: 1, session: "test", timestamp: 0, trusted: true,
                code: code, suppressDock: true, adjustedWindows: 0, policyVersion: "1.1.0")
            value.nativeFullscreen = fullscreen
            return value
        }
        check(!status("windowSizeConstrained").shouldSuppressDock, "Normal app minimum size must not hide the Dock")
        check(status("fullScreen").shouldSuppressDock, "Native fullscreen may hide the Dock")
        check(status("userInteracting", fullscreen: true).shouldSuppressDock, "Pointer activity inside native fullscreen does not reveal the Dock")
        check(!status("windowSizeConstrained", fullscreen: false).shouldSuppressDock, "Explicit non-fullscreen status keeps Dock visible")
        print("PASS: \(count) drag, resize, independent-window and protocol assertions")
    }
}
