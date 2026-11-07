import Foundation

@main
struct CornerPolicyTests {
    static func main() {
        let screen = DisplaySnapshot(id: 1, uuid: "test", name: "Test", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let layout = DisplayLayout([screen])
        let zones = EdgeGuardPlanner.zones(for: ["test"], edge: .bottom, in: layout, band: 3)
        var engine = PointerClampEngine(configuration: GuardConfiguration(zones: zones, keepHotCorners: true, cornerSize: 6, cornerGrace: 0.3))
        let corner = CGPoint(x: 1919, y: 1079)
        precondition(engine.process(point: corner, modifiers: [], now: 10) == .pass)
        precondition(engine.process(point: corner, modifiers: [], now: 10.2) == .pass)
        precondition(engine.process(point: corner, modifiers: [], now: 10.5) == .clamp(CGPoint(x: 1919, y: 1077)))
        precondition(engine.process(point: CGPoint(x: 960, y: 1079), modifiers: [], now: 11) == .clamp(CGPoint(x: 960, y: 1077)))
        precondition(engine.process(point: CGPoint(x: 960, y: 500), modifiers: [], now: 12) == .pass)
        precondition(engine.process(point: corner, modifiers: [], now: 13) == .pass)
        print("PASS: 6 hot-corner and guarded-edge boundary assertions")
    }
}
