import Foundation

@main
struct MenuCopyTests {
    static func main() throws {
        let newWindow = CopiedMenuStep(title: "New Window", identifier: nil)
        let quit = CopiedMenuStep(title: "Quit", identifier: nil)
        expect(newWindow.uniqueIndex(in: [quit, newWindow]) == 1, "reordered items resolve by identity, not old row")
        expect(newWindow.uniqueIndex(in: [quit]) == nil, "removed command does not execute another row")
        expect(newWindow.uniqueIndex(in: [newWindow, newWindow]) == nil, "ambiguous titles are refused")
        let first = CopiedMenuStep(title: "Document", identifier: "first")
        let second = CopiedMenuStep(title: "Document", identifier: "second")
        expect(second.uniqueIndex(in: [second, first]) == 0, "stable identifiers distinguish equal titles")
        expect(second.uniqueIndex(in: [first]) == nil, "missing identifier never falls back to same title")
        expect(second.uniqueIndex(in: [second, second]) == nil, "duplicate identifiers are refused")
        expect(second.uniqueIndex(in: [.init(title: "Different document", identifier: "second")]) == nil,
               "changed command title requires a rescan")

        let file = CopiedMenuStep(title: "文件", identifier: "file-menu")
        let command = CopiedMenuItem(title: "新建窗口", path: [file, newWindow], enabled: false, checked: true, children: [])
        let root = CopiedMenuItem(title: "文件", path: [file], enabled: true, checked: false, children: [command])
        let app = CopiedApplicationMenu(id: "test.app", name: "测试应用", applicationPath: "/Applications/Test.app",
                                         source: .applicationMenu, capturedAt: Date(timeIntervalSince1970: 10),
                                         items: [root], enabled: false)
        var archive = MenuCopyArchive()
        archive.menus[app.id] = app
        archive.reports[app.id] = MenuCopyReport(id: app.id, name: app.name, date: app.capturedAt,
                                               outcome: .partial, source: .applicationMenu, commandCount: 1,
                                               detail: "原生 Dock 无法读取，已标明替代来源。")
        archive.liveWindowsEnabled = false
        let restored = try JSONDecoder().decode(MenuCopyArchive.self, from: JSONEncoder().encode(archive))
        let saved = restored.menus[app.id]!
        expect(saved.source == .applicationMenu && !saved.enabled, "source and display opt-out survive restart")
        expect(saved.items[0].children[0].path == [file, newWindow], "nested target paths survive restart")
        expect(!saved.items[0].children[0].enabled && saved.items[0].children[0].checked,
               "unavailable state and checkmarks survive restart")
        expect(saved.commandCount == 1 && restored.reports[app.id]?.outcome == .partial,
               "partial copies retain truthful results and leaf counts")
        expect(restored.liveWindowsEnabled == false, "live-window opt-out survives restart")
        let legacy = try JSONDecoder().decode(MenuCopyArchive.self, from: Data("{\"schemaVersion\":1,\"menus\":{},\"reports\":{}}".utf8))
        expect(legacy.liveWindowsEnabled != false, "archives without the new optional preference keep the default")
        var configuration = DockerConfiguration()
        configuration.groups = [.init(id: "group", name: "测试叠放")]
        configuration.rules = [
            "pinned": .init(placement: .pinned), "grouped-stopped": .init(placement: .group, groupID: "group"),
            "hidden": .init(placement: .hidden), "not-on-dock": .init(placement: .running)
        ]
        let ids = PlacementResolver.menuCopyIDs(configuration: configuration, running: ["running", "hidden"],
                                                 available: ["pinned", "grouped-stopped", "hidden", "not-on-dock", "running"])
        expect(Set(ids) == ["com.apple.finder", "pinned", "running", "grouped-stopped"],
               "one-click scope matches standalone icons and stack members only")
        expect(ids.contains("grouped-stopped"), "stopped stack members remain in the scan scope")
        expect(!ids.contains(PlacementResolver.libraryID) && Set(ids).count == ids.count,
               "utility tiles and duplicate application IDs are excluded")
        print("Menu copy tests passed (16 checks)")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
