import Foundation

@main
struct ConfigurationTests {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { fatalError("FAILED: \(message)") }
        }
        var config = DockerConfiguration.initial()
        config.rules["test.pinned"] = .init(name: "固定", placement: .pinned)
        config.rules["test.running"] = .init(name: "运行", placement: .running)
        config.rules["test.stopped"] = .init(name: "未运行", placement: .running)
        config.rules["test.hidden"] = .init(name: "隐藏", placement: .hidden, keepOnQuit: false)
        config.rules["test.grouped"] = .init(name: "分组", placement: .group, groupID: "ai")
        let available: Set<String> = ["test.pinned", "test.running", "test.stopped", "test.hidden", "test.grouped"]
        let running: Set<String> = ["test.running", "test.hidden", "test.grouped"]
        let standalone = PlacementResolver.standaloneIDs(configuration: config, running: running, available: available)
        check(standalone.contains("test.pinned"), "A stopped pinned application remains visible")
        check(standalone.contains("test.running"), "A running default application appears")
        check(!standalone.contains("test.stopped"), "A stopped runtime-only application disappears")
        check(!standalone.contains("test.hidden"), "A running hidden application stays hidden")
        check(!standalone.contains("test.grouped"), "A grouped running app is not duplicated")
        check(standalone.first == "com.apple.finder", "Finder is always present")
        config.applicationOrder = ["test.running", "test.pinned"]
        check(PlacementResolver.standaloneIDs(configuration: config, running: running, available: available) == ["com.apple.finder", "test.running", "test.pinned"], "Explicit app ordering is preserved")
        config.rules["test.preserved"] = .init(placement: .hidden, keepOnQuit: true)
        let targets = PlacementResolver.quitTargets(regularIDs: running.union(["test.preserved", "com.apple.finder", "com.apple.dock", "local.codex.native-dock-preview"]),
                                                    rules: config.rules, ownID: "local.codex.native-dock-preview")
        check(targets.contains("test.hidden"), "Hidden display does not imply exemption from quitting")
        check(!targets.contains("test.preserved"), "Preservation applies independently of display")
        check(!targets.contains("com.apple.finder") && !targets.contains("com.apple.dock") && !targets.contains("local.codex.native-dock-preview"), "System and Docker processes are protected")
        let encoder = JSONEncoder()
        let roundTrip = try DockerConfiguration.decodeValidated(encoder.encode(config))
        check(roundTrip == config, "Configuration round-trip retains unicode names and application rules")
        let before = config
        do { _ = try DockerConfiguration.decodeValidated(Data(#"{"schemaVersion":99}"#.utf8)); fatalError("Unsupported version accepted") }
        catch { check(config == before, "Unsupported import leaves live configuration untouched") }
        do { _ = try DockerConfiguration.decodeValidated(Data("broken".utf8)); fatalError("Corrupt data accepted") }
        catch { check(true, "Corrupt import is rejected") }
        let minimal = try DockerConfiguration.decodeValidated(Data(#"{"schemaVersion":1}"#.utf8))
        check(minimal.groups.count == 3 && minimal.nativeDockHidden, "Missing top-level fields receive defaults")
        check(minimal.showApplicationLibrary && minimal.glassStyle == "regular", "Existing configurations gain the library and full Liquid Glass material")
        let slots = PlacementResolver.dockSlotIDs(configuration: config, standaloneIDs: standalone)
        check(Array(slots.prefix(2)) == ["com.apple.finder", PlacementResolver.libraryID], "Application library is fixed immediately after Finder")
        var withoutLibrary = config; withoutLibrary.showApplicationLibrary = false
        check(PlacementResolver.dockSlotIDs(configuration: withoutLibrary, standaloneIDs: standalone) == slots, "Legacy unpin preferences cannot remove the fixed application library")
        withoutLibrary.normalize()
        check(withoutLibrary.showApplicationLibrary, "Normalization keeps the application library fixed")
        var hiddenRule = ApplicationRule(name: "test", placement: .group, groupID: "browsers", keepOnQuit: true)
        hiddenRule.setHidden(true, validGroups: ["browsers"])
        check(hiddenRule.placement == .hidden && hiddenRule.keepOnQuit, "Hiding preserves quit protection")
        hiddenRule.setHidden(false, validGroups: ["browsers"])
        check(hiddenRule.placement == .group && hiddenRule.groupID == "browsers", "Unhiding restores prior stack membership")
        hiddenRule.setHidden(true, validGroups: ["browsers"])
        hiddenRule.setHidden(false, validGroups: [])
        check(hiddenRule.placement == .running && hiddenRule.groupID == nil, "Deleted stack safely falls back when unhiding")
        let memberOrder = ["test.first", "test.second", "test.third"]
        check(PlacementResolver.coverIDs(memberIDs: memberOrder, topApplicationID: "test.third") == ["test.third", "test.first", "test.second"], "Selected application appears at the front of the stack cover")
        check(memberOrder.first == "test.first", "Changing the cover does not change the expanded application order")
        check(PlacementResolver.coverIDs(memberIDs: memberOrder, topApplicationID: "missing") == memberOrder, "Unavailable cover choice falls back without duplicating a member")
        var coverConfig = DockerConfiguration.initial()
        coverConfig.groups[0].topApplicationID = "com.google.Chrome"
        coverConfig.glassTransparency = 0.37
        coverConfig.normalize()
        let coverRoundTrip = try DockerConfiguration.decodeValidated(encoder.encode(coverConfig))
        check(coverRoundTrip.groups[0].topApplicationID == "com.google.Chrome" && coverRoundTrip.glassTransparency == 0.37, "Cover and transparency persist across launch and import")
        coverConfig.rules["com.google.Chrome"]?.placement = .hidden
        coverConfig.normalize()
        check(coverConfig.groups[0].topApplicationID == nil, "Moving the cover application out of its group clears the stale cover")
        coverConfig.glassTransparency = 10; coverConfig.glassStyle = "unsupported"
        coverConfig.normalize()
        check(coverConfig.glassTransparency == 1 && coverConfig.glassStyle == "regular", "Material imports are clamped to supported rendering values")
        coverConfig.glassTransparency = -.infinity; coverConfig.shortcutModifiers = 0x1B00
        coverConfig.normalize()
        check(coverConfig.glassTransparency == 0.65 && coverConfig.shortcutModifiers == 0x1900, "Invalid glass values and legacy shortcut modifiers are migrated")
        var edited = DockerConfiguration()
        edited.groups = [.init(id: "first", name: "第一组", topApplicationID: "test.a"),
                         .init(id: "second", name: "第二组", topApplicationID: "test.c")]
        edited.rules = [
            "test.a": .init(name: "应用 A", path: "/Applications/A.app", placement: .group, groupID: "first", keepOnQuit: true, displayUUID: "screen"),
            "test.b": .init(placement: .group, groupID: "first"),
            "test.c": .init(placement: .group, groupID: "second"),
            "test.d": .init(placement: .group, groupID: "second"),
            "test.e": .init(placement: .group, groupID: "second"),
            "test.hidden": .init(placement: .hidden, previousPlacement: .pinned),
            "test.pinned": .init(placement: .pinned), "test.tail": .init(placement: .pinned)
        ]
        edited.applicationOrder = ["test.pinned", "test.a", "test.d", "test.c", "test.b", "test.e", "test.tail"]
        edited.replaceGroupMembers(["test.b", "test.hidden", "test.c", "test.new", "test.c", "com.apple.finder", ""], in: "first")
        check(edited.orderedMemberIDs(in: "first") == ["test.b", "test.hidden", "test.c", "test.new"], "Quick editing saves the exact displayed member order and rejects duplicate or protected entries")
        check(edited.rules["test.a"]?.placement == .running && edited.rules["test.a"]?.groupID == nil, "Removing a member changes it to runtime-only display")
        check(edited.rules["test.a"]?.name == "应用 A" && edited.rules["test.a"]?.path == "/Applications/A.app" && edited.rules["test.a"]?.keepOnQuit == true && edited.rules["test.a"]?.displayUUID == "screen", "Removing a member preserves its application and independent preferences")
        check(edited.orderedMemberIDs(in: "second") == ["test.d", "test.e"], "Moving a member between stacks preserves the remaining stack order")
        check(edited.groups.allSatisfy { $0.topApplicationID == nil }, "Removing or transferring cover applications resets stale covers")
        check(edited.rules["test.hidden"]?.previousPlacement == nil, "Adding a hidden application clears its old hidden-placement state")
        let afterRemoval = PlacementResolver.standaloneIDs(configuration: edited, running: ["test.a"], available: Set(edited.rules.keys))
        check(afterRemoval == ["com.apple.finder", "test.pinned", "test.a", "test.tail"], "A removed running member appears in Dock without disturbing existing standalone order")
        check(!PlacementResolver.standaloneIDs(configuration: edited, running: [], available: Set(edited.rules.keys)).contains("test.a"), "A removed stopped member no longer occupies a Dock slot")
        let editedRoundTrip = try DockerConfiguration.decodeValidated(encoder.encode(edited))
        check(editedRoundTrip == edited, "Edited membership and order survive saving and reloading")
        let beforeMissingGroup = edited
        edited.replaceGroupMembers(["test.a"], in: "deleted")
        check(edited == beforeMissingGroup, "A stale editor cannot recreate a deleted stack or move its apps")
        edited.replaceGroupMembers([], in: "first")
        check(edited.orderedMemberIDs(in: "first").isEmpty && edited.groups.count == 2, "Removing the last member leaves an editable empty stack")
        config.groups.removeAll { $0.id == "ai" }
        config.normalize()
        check(config.rules["test.grouped"]?.placement == .running && config.rules["test.grouped"]?.groupID == nil, "Deleted groups release their apps without uninstalling them")
        config.iconSize = .infinity
        config.pointerFollowDelay = -.infinity
        config.normalize()
        check(config.iconSize == 81 && config.pointerFollowDelay == 0.7, "Invalid geometry values cannot reach rendering")
        config.rules["local.codex.native-dock-preview"] = .init(placement: .group, groupID: "browsers")
        config.rules["com.apple.finder"] = .init(placement: .hidden)
        config.normalize()
        check(config.rules["local.codex.native-dock-preview"]?.placement == .hidden, "Imported rules cannot duplicate background control components")
        check(config.rules["com.apple.finder"]?.placement == .pinned && config.rules["com.apple.finder"]?.keepOnQuit == true, "Imported rules cannot hide or quit Finder")
        var partition = DockerConfiguration.initial()
        var random: UInt64 = 0xF07517
        let modes = AppPlacement.allCases
        var runningRandom = Set<String>(), availableRandom = Set<String>()
        for i in 0..<200 {
            random = random &* 6364136223846793005 &+ 1
            let id = "partition.\(i)", mode = modes[Int((random >> 32) % 4)]
            partition.rules[id] = .init(placement: mode, groupID: mode == .group ? "ai" : nil)
            availableRandom.insert(id)
            if random & 1 == 0 { runningRandom.insert(id) }
        }
        let visibleRandom = Set(PlacementResolver.standaloneIDs(configuration: partition, running: runningRandom, available: availableRandom))
        for id in availableRandom {
            let mode = partition.rules[id]!.placement
            check(visibleRandom.contains(id) == (mode == .pinned || (mode == .running && runningRandom.contains(id))), "Exclusive placement partition: \(id)")
        }
        print("PASS: \(assertions) configuration and lifecycle-policy assertions")
    }
}
