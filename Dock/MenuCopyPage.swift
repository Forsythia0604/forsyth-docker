import AppKit
import SwiftUI

private typealias MenuCopyUIState<Value> = SwiftUI.State<Value>

@MainActor
struct MenuCopyPage: View {
    @ObservedObject var store: DockerStore
    @ObservedObject private var menus = MenuCopyService.shared
    @MenuCopyUIState private var search = ""
    @MenuCopyUIState private var allowMenuBar = true
    @MenuCopyUIState private var showOnlyDock = true

    private var dockApplications: [CatalogApplication] {
        let running = Set(NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }.compactMap(\.bundleIdentifier))
        var available = Set(store.catalog.filter(\.installed).map(\.id))
        available.formUnion(running)
        available.formUnion(store.configuration.rules.filter { $0.value.placement == .pinned }.keys)
        let ids = PlacementResolver.menuCopyIDs(configuration: store.configuration, running: running, available: available)
        let catalog = Dictionary(uniqueKeysWithValues: store.catalog.map { ($0.id, $0) })
        return ids.map { id in
            if let app = catalog[id] { return app }
            let rule = store.rule(for: id)
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            return CatalogApplication(id: id, name: id == "com.apple.finder" ? "访达" : rule.name,
                                      path: url?.path ?? rule.path ?? "", installed: url != nil || rule.path != nil)
        }
    }

    private var applications: [CatalogApplication] {
        let dock = dockApplications
        let dockIDs = Set(dock.map(\.id))
        let catalogIDs = Set(store.catalog.map(\.id))
        return (store.orderedCatalog + dock.filter { !catalogIDs.contains($0.id) }).filter { app in
            (app.id == "com.apple.finder" || !DockerConfiguration.protectedIDs.contains(app.id))
                && (!showOnlyDock || dockIDs.contains(app.id) || menus.archive.reports[app.id] != nil)
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("菜单复制").font(.system(size: 25, weight: .medium))
                Text("尽量把应用的快捷操作带到 Docker 右键菜单，并如实记录读取结果。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Label(menus.trusted ? "已允许读取应用菜单" : "需要允许 Docker 读取应用菜单",
                          systemImage: menus.trusted ? "checkmark.circle" : "hand.raised")
                    Spacer()
                    if !menus.trusted { Button("打开辅助功能设置", action: menus.requestPermission) }
                    Button("重新检查授权", action: menus.refreshPermission)
                }
                Text("窗口助手的授权与 Docker 分开。此功能只在扫描或使用菜单时读取应用界面。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Toggle("原生 Dock 读取失败时，尝试复制应用菜单栏", isOn: $allowMenuBar)
                    .toggleStyle(.switch).controlSize(.small)
                Text("替代来源会标为“部分复制”，并放入“应用菜单”子菜单。无法可靠读取的项目会跳过，并说明原因。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("一键扫描只包含 Docker 独立图标与叠放成员。系统菜单可能短暂出现；未运行应用若无法读取，会在结果中说明。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("右键时更新窗口和网页标签页列表", isOn: Binding(
                    get: { menus.liveWindowsEnabled }, set: { menus.setLiveWindowsEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Text("显示当前窗口及网页标题，点击切换。Safari 等浏览器开放的标签页也会列出；读取不完整时只显示已读取数量，并在结果里说明。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 270)
                Toggle("仅 Dock 与已扫描", isOn: $showOnlyDock).toggleStyle(.checkbox)
                Spacer()
                if menus.scanning {
                    ProgressView().controlSize(.small)
                    Button("停止扫描", action: menus.cancel)
                } else {
                    Button("一键扫描 Dock 应用") {
                        menus.scan(dockApplications, allowMenuBar: allowMenuBar)
                    }.disabled(!menus.trusted || menus.invoking || DockerStore.isPreview)
                }
            }
            if !menus.progress.isEmpty { Text(menus.progress).font(.callout).foregroundStyle(.secondary) }
            if !menus.storageMessage.isEmpty { Text(menus.storageMessage).font(.callout).foregroundStyle(.red) }
            if DockerStore.isPreview { Text("界面预览不扫描应用，也不更改已保存的菜单。").font(.caption).foregroundStyle(.secondary) }

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(applications) { app in
                    applicationRow(app)
                    Divider()
                }
            }
            if applications.isEmpty { Text("没有匹配的应用。").foregroundStyle(.secondary) }
        }.onAppear { menus.refreshPermission() }
    }

    private func applicationRow(_ app: CatalogApplication) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.system(size: 13, weight: .medium))
                    Text(store.runningIDs.contains(app.id) ? "正在运行" : "未运行").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let saved = menus.archive.menus[app.id] {
                    Toggle("在右键菜单显示", isOn: Binding(get: { saved.enabled }, set: { menus.setEnabled($0, for: app.id) }))
                        .toggleStyle(.switch).controlSize(.small).fixedSize()
                    Button("移除") { menus.remove(app.id) }.disabled(menus.scanning || menus.invoking)
                }
                Button(menus.archive.menus[app.id] == nil ? "复制菜单" : "重新扫描") {
                    menus.scan([app], allowMenuBar: allowMenuBar)
                }.disabled(menus.scanning || menus.invoking || !menus.trusted || DockerStore.isPreview)
            }
            if let report = menus.archive.reports[app.id] {
                HStack(spacing: 8) {
                    Text(report.outcome.title).foregroundStyle(report.outcome == .copied ? .green : .secondary)
                    if let source = report.source { Text(source.title + " · \(report.commandCount) 个项目") }
                    Spacer()
                    Text(report.date.formatted(date: .abbreviated, time: .shortened))
                }.font(.caption)
                Text(report.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let live = menus.liveSnapshots[app.id] {
                Text(live.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let saved = menus.archive.menus[app.id] {
                DisclosureGroup("查看已复制项目（\(saved.commandCount)）") {
                    ForEach(saved.items) { entry in MenuCopyEntryView(entry: entry) }
                }.font(.caption)
            }
        }.padding(.vertical, 15)
    }
}

private struct MenuCopyEntryView: View {
    let entry: CopiedMenuItem
    var body: some View {
        if entry.children.isEmpty {
            Text(entry.title + (entry.enabled ? "" : "（原应用当前不可用）"))
                .foregroundStyle(entry.enabled ? .primary : .secondary).padding(.vertical, 2)
        } else {
            DisclosureGroup(entry.title) {
                ForEach(entry.children) { child in MenuCopyEntryView(entry: child) }
            }.padding(.vertical, 2)
        }
    }
}
