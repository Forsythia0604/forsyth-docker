import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// Explicitly name the value-storage wrapper when building with the command-line SDK.
private typealias UIState<Value> = SwiftUI.State<Value>

private struct DockerPage: Identifiable {
    let id: String
    let title: String
    let symbol: String
    static let all: [Self] = [
        .init(id: "overview", title: "总览", symbol: "square.grid.2x2"),
        .init(id: "apps", title: "应用管理", symbol: "app.badge"),
        .init(id: "stacks", title: "叠放管理", symbol: "square.stack.3d.up"),
        .init(id: "hidden", title: "隐藏应用", symbol: "eye.slash"),
        .init(id: "menus", title: "菜单复制", symbol: "list.bullet.rectangle"),
        .init(id: "appearance", title: "Dock 外观", symbol: "slider.horizontal.3"),
        .init(id: "displays", title: "显示器与锁定", symbol: "display"),
        .init(id: "windows", title: "窗口避让", symbol: "rectangle.split.2x2"),
        .init(id: "quit", title: "一键退出", symbol: "power"),
        .init(id: "settings", title: "设置与关于", symbol: "gearshape")
    ]
}

@MainActor
struct DockerRootView: View {
    @ObservedObject var store: DockerStore
    @ObservedObject var quit: QuitService
    var authorizeWindow: () -> Void
    var authorizeNative: () -> Void
    var showWindow: () -> Void
    @UIState private var search = ""
    @UIState private var filter = "all"
    @UIState private var selectedGroup: String?
    @UIState private var editingGroup: StackConfiguration?
    @UIState private var deletingGroup: StackConfiguration?
    @UIState private var addingToGroup: StackConfiguration?
    @UIState private var hiddenScope = "running"
    @UIState private var loginEnabled = SMAppService.mainApp.status == .enabled
    @UIState private var showQuitConfirm = false
    private let groupIcons: [(String, String)] = [
        ("square.stack.3d.up", "应用缩略图"), ("custom:globe", "浏览器"), ("custom:sparkles", "AI"),
        ("custom:bubble.left.and.bubble.right", "通讯"), ("custom:graduationcap", "学习"),
        ("custom:doc.text", "文档"), ("custom:hammer", "开发"), ("custom:music.note", "音乐"), ("custom:folder", "文件夹")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    Text("Docker").foregroundStyle(.secondary)
                    Text("/").foregroundStyle(.tertiary)
                    Text(DockerPage.all.first(where: { $0.id == store.selectedPage })?.title ?? "总览")
                    Spacer()
                    if DockerStore.isPreview { Text("界面预览").font(.caption).foregroundStyle(.secondary) }
                }.font(.callout).padding(.horizontal, 28).frame(height: 48)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch store.selectedPage {
                        case "apps": applicationsPage
                        case "stacks": stacksPage
                        case "hidden": hiddenAppsPage
                        case "menus": MenuCopyPage(store: store)
                        case "appearance": appearancePage
                        case "displays": displaysPage
                        case "windows": windowsPage
                        case "quit": quitPage
                        case "settings": settingsPage
                        default: overviewPage
                        }
                    }.padding(28).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                HStack {
                    Text(store.message.isEmpty ? store.nativeDockStatus : store.message).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Text("Forsyth")
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 9)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
        .sheet(item: $editingGroup) { group in groupEditor(group) }
        .sheet(item: $addingToGroup) { group in groupMembersPicker(group) }
        .confirmationDialog("删除叠放「\(deletingGroup?.name ?? "")」？", isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })) {
            Button("删除叠放", role: .destructive) {
                if let group = deletingGroup { store.deleteGroup(group.id) }
                selectedGroup = nil; deletingGroup = nil
            }
        } message: { Text("其中的应用会改为“仅运行时显示”，应用程序不会被卸载。") }
        .confirmationDialog("退出选中的应用？", isPresented: $showQuitConfirm) {
            Button("正常退出选中应用") { quit.run() }
        } message: { Text("应用如有未保存内容，会显示自己的保存提示。不会强制结束进程。") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 37, height: 37)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Docker").font(.system(size: 22, weight: .medium))
                    Text("by Forsyth").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 22)
            ScrollView {
              VStack(alignment: .leading, spacing: 6) {
               ForEach(DockerPage.all) { page in
                Button {
                    if store.selectedPage != page.id { search = ""; filter = "all" }
                    store.selectedPage = page.id
                    if page.id == "quit" && !quit.processing { quit.preview() }
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: page.symbol).frame(width: 19)
                        Text(page.title)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 13).padding(.vertical, 11)
                        .background(store.selectedPage == page.id ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("page-\(page.id)")
               }
              }
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(store.nativeDockEffective ? Color.green : Color.secondary).frame(width: 6, height: 6).padding(.top, 5)
                    Text(store.nativeDockStatus).fixedSize(horizontal: false, vertical: true)
                }
                Text("Docker 1.0 · Forsyth").foregroundStyle(.tertiary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(14)
        }.padding(.horizontal, 10).frame(width: 213).frame(maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .medium))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15, content: content)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func configurationBinding<T>(_ key: WritableKeyPath<DockerConfiguration, T>) -> Binding<T> {
        Binding(get: { store.configuration[keyPath: key] }, set: { value in store.change { $0[keyPath: key] = value } })
    }

    private func setting(_ title: String, detail: String, key: WritableKeyPath<DockerConfiguration, Bool>) -> some View {
        Toggle(isOn: configurationBinding(key)) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }.toggleStyle(.switch).controlSize(.small)
    }

    private var filteredApps: [CatalogApplication] {
        store.orderedCatalog.filter { app in
            let rule = store.rule(for: app.id)
            guard search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || app.id.localizedCaseInsensitiveContains(search) else { return false }
            if store.selectedPage == "stacks" {
                return rule.placement == .group && (selectedGroup == nil || rule.groupID == selectedGroup)
            }
            if store.selectedPage == "hidden" {
                return !DockerConfiguration.protectedIDs.contains(app.id)
                    && (hiddenScope == "all" || store.runningIDs.contains(app.id))
            }
            return filter == "all" || rule.placement.rawValue == filter
        }
    }

    private var applicationsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                heading("应用管理", "设置独立固定图标、运行时显示与退出保留名单。")
                Spacer()
                Button("添加应用…", action: addApplication)
            }
            HStack(spacing: 12) {
                Picker("筛选", selection: $filter) {
                    Text("全部").tag("all"); Text("固定").tag("pinned"); Text("运行时").tag("running")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer()
                searchField
            }
            applicationTable
        }
    }

    private var stacksPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                heading("叠放管理", "管理叠放成员、封面应用与排列顺序。")
                Spacer()
                Button("新建叠放", systemImage: "plus") { editingGroup = .init(name: "") }.buttonStyle(.borderedProminent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(store.configuration.groups) { group in
                        Button {
                            selectedGroup = selectedGroup == group.id ? nil : group.id
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: group.symbol.replacingOccurrences(of: "custom:", with: ""))
                                Text(group.name)
                                Text("\(store.configuration.rules.values.filter { $0.groupID == group.id }.count)").foregroundStyle(.secondary)
                            }.padding(.horizontal, 13).padding(.vertical, 9)
                                .background(selectedGroup == group.id ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                            .onDrag { NSItemProvider(object: ("docker-group:" + group.id) as NSString) }
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                acceptText(providers) { value in
                                    if value.hasPrefix("docker-group:") {
                                        let fromID = String(value.dropFirst(13))
                                        store.change { c in
                                            guard let from = c.groups.firstIndex(where: { $0.id == fromID }),
                                                  let to = c.groups.firstIndex(where: { $0.id == group.id }) else { return }
                                            let item = c.groups.remove(at: from); c.groups.insert(item, at: min(to, c.groups.count))
                                        }
                                    } else if store.catalog.contains(where: { $0.id == value }) {
                                        store.updateRule(value) { $0.placement = .group; $0.groupID = group.id }
                                    }
                                }
                            }
                            .contextMenu {
                                Button("编辑叠放…") { editingGroup = group }
                                Button("向前移动") { store.moveGroup(group.id, by: -1) }
                                Button("向后移动") { store.moveGroup(group.id, by: 1) }
                                Divider()
                                Button("删除叠放…", role: .destructive) { deletingGroup = group }
                            }
                    }
                }
            }
            if let group = store.configuration.groups.first(where: { $0.id == selectedGroup }) {
                HStack {
                    Text("正在查看：\(group.name)").font(.caption).foregroundStyle(.secondary)
                    Button("编辑") { editingGroup = group }
                    Button("添加成员…") { addingToGroup = group }
                    Button("查看全部叠放") { selectedGroup = nil }
                    Spacer()
                }.controlSize(.small)
            }
            HStack { Spacer(); searchField }
            applicationTable
            Label("可拖动应用到上方叠放，拖动叠放或应用行调整顺序。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                .accessibilityIdentifier("app-search")
            Button { store.scanApplications() } label: { Image(systemName: "arrow.clockwise") }
                .help("重新扫描已安装应用").disabled(store.scanning)
        }
    }

    private var applicationTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("应用").frame(maxWidth: .infinity, alignment: .leading)
                Text("Dock 显示").frame(width: 154, alignment: .leading)
                Text(store.selectedPage == "stacks" ? "叠放分组" : "显示位置").frame(width: 130, alignment: .leading)
                Text("退出时保留").frame(width: 76)
                Spacer().frame(width: 24)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            LazyVStack(spacing: 0) {
                ForEach(filteredApps) { app in applicationRow(app) }
                if filteredApps.isEmpty {
                    Text(store.scanning ? "正在扫描应用…" : "没有符合条件的应用。")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(35)
                }
            }
        }
    }

    private var hiddenAppsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("隐藏应用", "查看正在运行的应用，单独控制它们是否出现在 Dock。")
            HStack {
                Picker("显示范围", selection: $hiddenScope) {
                    Text("正在运行").tag("running"); Text("全部应用").tag("all")
                }.pickerStyle(.segmented).frame(width: 230).labelsHidden()
                Spacer(); searchField
            }
            Text("当前列表 \(filteredApps.count) 个应用 · 已隐藏 \(filteredApps.filter { store.rule(for: $0.id).placement == .hidden }.count) 个")
                .font(.caption).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(filteredApps) { app in
                    HStack(spacing: 12) {
                        Image(nsImage: store.icon(for: app)).resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name)
                            Text(store.runningIDs.contains(app.id) ? "正在运行" : "未运行")
                                .font(.caption).foregroundStyle(store.runningIDs.contains(app.id) ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Toggle("隐藏", isOn: Binding(
                            get: { store.rule(for: app.id).placement == .hidden },
                            set: { hidden in store.setHidden(hidden, for: app.id) }
                        )).toggleStyle(.switch).controlSize(.small).disabled(!app.installed)
                            .accessibilityLabel("在 Dock 中隐藏 \(app.name)")
                    }.padding(.vertical, 12)
                    Divider()
                }
                if filteredApps.isEmpty { Text("当前没有符合条件的应用。").foregroundStyle(.secondary).padding(35) }
            }
            Text("隐藏后应用继续运行。关闭隐藏会恢复它原来的显示方式；退出保留名单在“应用管理”中设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func applicationRow(_ app: CatalogApplication) -> some View {
        let rule = store.rule(for: app.id)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: store.icon(for: app)).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.callout).lineLimit(1).help(app.name)
                        Text(!app.installed ? "未安装" : store.runningIDs.contains(app.id) ? "运行中" : "未运行")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Picker("\(app.name)的 Dock 显示方式", selection: Binding(get: { store.rule(for: app.id).placement }, set: { mode in
                    store.updateRule(app.id) {
                        $0.placement = mode
                        $0.groupID = mode == .group ? (selectedGroup ?? store.configuration.groups.first?.id) : nil
                    }
                })) {
                    if rule.placement == .group || rule.placement == .hidden { Text(rule.placement.title).tag(rule.placement) }
                    Text(AppPlacement.pinned.title).tag(AppPlacement.pinned)
                    Text(AppPlacement.running.title).tag(AppPlacement.running)
                }.labelsHidden().frame(width: 154).disabled(!app.installed)
                Group {
                    if rule.placement == .group && store.selectedPage == "stacks" {
                        Picker("\(app.name)所属叠放", selection: Binding(get: { store.rule(for: app.id).groupID ?? "" }, set: { id in
                            store.updateRule(app.id) { $0.groupID = id }
                        })) {
                            ForEach(store.configuration.groups) { group in Text(group.name).tag(group.id) }
                        }.labelsHidden()
                    } else if rule.placement == .group {
                        Button("前往叠放管理") { selectedGroup = rule.groupID; store.selectedPage = "stacks" }.font(.caption)
                    } else if rule.placement == .hidden {
                        Button("前往隐藏应用") { store.selectedPage = "hidden" }.font(.caption)
                    } else {
                        Text(rule.placement == .hidden ? "不占 Dock 位置" : rule.placement == .pinned ? "独立固定图标" : "随运行状态显示")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.frame(width: 130, alignment: .leading)
                Toggle("退出时保留 \(app.name)", isOn: Binding(get: { store.rule(for: app.id).keepOnQuit }, set: { value in
                    store.updateRule(app.id) { $0.keepOnQuit = value }
                })).labelsHidden().toggleStyle(.checkbox).frame(width: 76)
                Menu {
                    Button("打开应用") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }.disabled(!app.installed)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }.disabled(!app.installed)
                    if let groupID = rule.groupID {
                        Button("设为叠放最上面的应用") { store.setTopApplication(app.id, for: groupID) }
                    }
                    Divider()
                    Button("向前移动") { store.moveApplication(app.id, by: -1) }
                    Button("向后移动") { store.moveApplication(app.id, by: 1) }
                    if store.configuration.displayPolicy == .app {
                        Menu("激活时将 Dock 移到") {
                            Button("应用窗口所在屏幕") { store.updateRule(app.id) { $0.displayUUID = nil } }
                            ForEach(store.screens.keys.sorted(), id: \.self) { id in
                                Button(store.screens[id] ?? id) { store.updateRule(app.id) { $0.displayUUID = id } }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }.padding(.vertical, 11).contentShape(Rectangle())
                .onDrag { NSItemProvider(object: app.id as NSString) }
                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                    acceptText(providers) { id in
                        guard id != app.id, store.catalog.contains(where: { $0.id == id }) else { return }
                        var order = store.orderedCatalog.map(\.id)
                        order.removeAll { $0 == id }
                        guard let target = order.firstIndex(of: app.id) else { return }
                        order.insert(id, at: target); store.change { $0.applicationOrder = order }
                    }
                }
            Divider()
        }
    }

    private func acceptText(_ providers: [NSItemProvider], action: @escaping @MainActor (String) -> Void) -> Bool {
        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String else { return }
            Task { @MainActor in action(text) }
        }
        return true
    }

    private func groupEditor(_ group: StackConfiguration) -> some View {
        GroupEditor(group: group, symbols: groupIcons, existing: store.configuration.groups,
                    members: store.orderedCatalog.filter { store.rule(for: $0.id).groupID == group.id }) { updated in
            store.change { c in
                if let index = c.groups.firstIndex(where: { $0.id == updated.id }) { c.groups[index] = updated }
                else { c.groups.append(updated) }
            }
            editingGroup = nil
        } onCancel: { editingGroup = nil }
    }

    private func groupMembersPicker(_ group: StackConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加到「\(group.name)」").font(.title2)
            TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.orderedCatalog.filter { app in
                        app.installed && !DockerConfiguration.protectedIDs.contains(app.id)
                            && store.rule(for: app.id).groupID != group.id
                            && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search))
                    }) { app in
                        HStack {
                            Image(nsImage: store.icon(for: app)).resizable().frame(width: 28, height: 28)
                            Text(app.name); Spacer()
                            Button("加入") { store.updateRule(app.id) { $0.placement = .group; $0.groupID = group.id } }
                        }
                    }
                }
            }
            HStack { Spacer(); Button("完成") { addingToGroup = nil; search = "" }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 470, height: 480)
    }

    private func addApplication() {
        let panel = NSOpenPanel(); panel.title = "选择应用程序"; panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !DockerConfiguration.protectedIDs.contains(id) else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
            store.updateRule(id) { $0.path = url.path; $0.name = name }
        }
        store.scanApplications()
    }

    private var overviewPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("桌面控制台", "应用、Dock 与窗口，集中管理。")
            panel {
                HStack(spacing: 15) {
                    Image(systemName: "dock.rectangle").font(.system(size: 32))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.nativeDockEffective ? "Docker 正在接管 Dock" : store.nativeDockStatus).font(.title3)
                        Text(store.nativeDockEffective ? "系统 Dock 完全隐藏，自定义 Dock 已接管应用入口。" : "可在此查看真实运行状态与权限。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !store.nativePermission && store.configuration.nativeDockHidden {
                    Button("打开辅助功能设置…", action: authorizeNative)
                    Text("请允许内置的 DockLock 隐藏组件；窗口避让由「Dock 窗口助手」单独授权。").font(.caption).foregroundStyle(.secondary)
                }
            }
            panel {
                setting("显示 Docker Dock", detail: "收起后，仍可从菜单栏打开控制台。", key: \.dockVisible)
                Divider()
                setting("窗口自动避让", detail: "最大化和分屏布局为 Dock 留出空间。", key: \.avoidanceEnabled)
                Divider()
                setting("会议模式", detail: "临时收起 Docker Dock，系统 Dock 继续隐藏。", key: \.meetingMode)
            }
            HStack {
                Button("管理应用", systemImage: "app.badge") { store.selectedPage = "apps" }
                Button("管理叠放", systemImage: "square.stack.3d.up") { store.selectedPage = "stacks" }
                Button("一键退出其他应用…", systemImage: "power") { quit.preview(); store.selectedPage = "quit" }
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var appearancePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("Dock 外观", "应用布局与显示习惯，分别设置。")
            panel {
                setting("显示 Docker Dock", detail: "控制自定义 Dock 是否显示。", key: \.dockVisible)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("程序列表固定在访达右侧")
                    Text("点击打开系统原生应用列表与搜索。").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Text("图标大小")
                    Spacer()
                    Slider(value: configurationBinding(\.iconSize), in: 40...112, step: 1).frame(width: 230)
                    Text("\(Int(store.configuration.iconSize)) pt").monospacedDigit().frame(width: 48)
                }
                Divider()
                Picker("叠放展开方式", selection: configurationBinding(\.stackStyle)) {
                    Text("扇形").tag("fan"); Text("网格").tag("grid")
                }.frame(maxWidth: 400)
                Text("应用较多时自动改用可滚动网格，避免超出屏幕。").font(.caption).foregroundStyle(.secondary)
                Divider()
                setting("显示运行指示", detail: "在运行中的应用图标下显示指示点。", key: \.showRunningIndicators)
                setting("显示通知角标", detail: "系统可提供角标时显示，分组内自动汇总。", key: \.showBadges)
            }
            panel {
                Text("Liquid Glass").font(.headline)
                Picker("玻璃材质", selection: configurationBinding(\.glassStyle)) {
                    Text("Liquid Glass · 标准").tag("regular")
                    Text("Liquid Glass · 清透").tag("clear")
                }.frame(maxWidth: 430)
                HStack {
                    Text("透明度")
                    Spacer()
                    Slider(value: configurationBinding(\.glassTransparency), in: 0...1, step: 0.01).frame(width: 230)
                        .accessibilityLabel("Liquid Glass 透明度")
                    Text("\(Int((store.configuration.glassTransparency * 100).rounded()))%").monospacedDigit().frame(width: 48)
                }
                Text("左侧更浓，右侧更透。保留原生玻璃的折射与高光，应用图标始终清晰。")
                    .font(.caption).foregroundStyle(.secondary)
                if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    Label("系统已开启“降低透明度”，玻璃会遵循该设置。", systemImage: "accessibility").font(.caption).foregroundStyle(.secondary)
                }
            }
            panel {
                Text("系统 Dock").font(.headline)
                Label(store.nativeDockStatus, systemImage: store.nativeDockEffective ? "checkmark.circle" : "clock")
                Text("Docker 正常运行时持续隐藏系统 Dock，并阻止所有屏幕的边缘唤出。真正退出 Docker 后恢复。")
                    .font(.callout).foregroundStyle(.secondary)
                Button(store.configuration.nativeDockHidden ? "恢复系统 Dock 并暂停接管" : "重新接管并隐藏系统 Dock") {
                    store.change { $0.nativeDockHidden.toggle() }
                }
            }
        }
    }

    private var displaysPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("显示器与锁定", "选择 Docker Dock 出现的屏幕。")
            panel {
                ForEach(store.screens.keys.sorted(), id: \.self) { id in
                    HStack(spacing: 14) {
                        Image(systemName: "display").font(.system(size: 28)).frame(width: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(store.screens[id] ?? "显示器")
                            Text(store.configuration.homeDisplayUUID == id ? "默认显示器" : "已连接").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(store.configuration.homeDisplayUUID == id ? "已设为默认" : "设为默认") {
                            let arrangement = store.screens.keys.sorted().joined(separator: "+")
                            store.change { $0.homeDisplayUUID = id; $0.arrangementHomes[arrangement] = id }
                        }
                    }
                }
                if store.screens.isEmpty { Text(DockerStore.isPreview ? "预览模式未启动显示器控制。" : "正在读取显示器…").foregroundStyle(.secondary) }
            }
            panel {
                Picker("显示策略", selection: configurationBinding(\.displayPolicy)) {
                    ForEach(DisplayPolicy.allCases) { Text($0.title).tag($0) }
                }
                if store.configuration.displayPolicy == .pointer {
                    HStack {
                        Text("鼠标停留时间")
                        Slider(value: configurationBinding(\.pointerFollowDelay), in: 0.25...3, step: 0.05).frame(width: 200)
                        Text(String(format: "%.2f 秒", store.configuration.pointerFollowDelay)).monospacedDigit()
                    }
                }
                if store.configuration.displayPolicy == .app {
                    Text("在「应用管理」每个应用的更多菜单中，设置激活时使用的显示器。").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                setting("会议模式", detail: "临时收起自定义 Dock，退出会议模式后恢复。", key: \.meetingMode)
                setting("会议应用运行时自动收起", detail: "默认检测 Zoom、腾讯会议和 Microsoft Teams。", key: \.hideForMeetingApps)
                Text("断开显示器时自动回到可用屏幕；重新连接后恢复该显示器组合的选择。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var windowsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("窗口避让", "窗口布局停在 Dock 上方，保留 8 pt 间距。")
            panel {
                setting("窗口自动避让 Dock", detail: "仅处理最大化与系统平铺。手动拖动、拉边框后保留你的位置。", key: \.avoidanceEnabled)
                Divider()
                Label(store.helperStatus, systemImage: store.helperTrusted ? "checkmark.shield" : "lock.shield")
                HStack {
                    Button(store.helperTrusted ? "查看窗口控制权限…" : "授权窗口助手…", action: authorizeWindow)
                    Text(store.helperTrusted ? "已授权" : "首次使用需要系统授权").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("真正进入系统全屏时暂时收起 Dock；普通应用打开、最大化或尺寸受限时，Dock 始终保留在屏幕底部。")
                    .font(.callout).foregroundStyle(.secondary)
                Label("⌃⌥ Return：将当前窗口最大化到 Dock 上方", systemImage: "keyboard").font(.callout)
                Text("拖动 Dock 的外边缘可调整大小。拖动时暂停窗口调整，松手后只更新仍处于最大化或平铺的窗口。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var quitPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                heading("一键退出", "退出其他应用，保留常用工具。")
                Spacer()
                Button("刷新退出清单") { quit.preview() }.disabled(quit.processing)
            }
            panel {
                Text("退出时保留").font(.headline)
                let names = store.catalog.filter { store.rule(for: $0.id).keepOnQuit }.map(\.name).sorted()
                Text(names.isEmpty ? "尚未选择保留应用。" : names.joined(separator: "、")).font(.callout)
                Text("Finder、Docker 与必要后台组件始终保留。可在「应用管理」逐项调整。").font(.caption).foregroundStyle(.secondary)
            }
            panel {
                Label("控制中心 · 1×1", systemImage: "switch.2").font(.headline)
                Text("打开控制中心的“编辑控制”，在 Docker 分类中添加“一键退出”，并选择“小”尺寸（1×1）。")
                Text("点击后按当前保留名单正常退出其他应用，未保存内容仍由各应用提示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            panel {
                setting("退出完成后清理系统 Dock 最近使用记录", detail: "所有选中应用退出后才执行，保留固定项目。", key: \.clearRecentsOnQuit)
                Divider()
                ForEach($quit.entries) { $entry in
                    HStack {
                        Toggle(entry.name, isOn: $entry.selected).toggleStyle(.checkbox).disabled(quit.processing || entry.status != "等待退出")
                        Spacer()
                        Text(entry.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(quit.summary.isEmpty ? "点击刷新退出清单，查看将退出的应用。" : quit.summary)
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    if quit.processing {
                        if quit.waitingApplicationName != nil {
                            Button("保留当前应用并继续") { quit.skipWaitingApplication() }
                        }
                        ProgressView().controlSize(.small)
                        Button("停止后续退出", role: .cancel) { quit.cancel() }
                    } else {
                        Button("正常退出选中应用…") { showQuitConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(!quit.entries.contains { $0.selected && $0.status == "等待退出" } || DockerStore.isPreview)
                    }
                    Spacer()
                    Button("仅清理最近使用记录") { quit.clearRecents() }.disabled(quit.processing || DockerStore.isPreview)
                }
            }
        }.onAppear { if quit.entries.isEmpty && !quit.processing { quit.preview() } }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("设置与关于", "启动、快捷键与本机配置。")
            panel {
                Toggle("登录时启动 Docker", isOn: $loginEnabled).toggleStyle(.switch).controlSize(.small)
                    .onChange(of: loginEnabled) { _, value in
                        guard !DockerStore.isPreview else { return }
                        do {
                            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                        } catch { store.message = "登录启动设置未更改：\(error.localizedDescription)"; loginEnabled = SMAppService.mainApp.status == .enabled }
                    }
                Text("关闭主窗口后继续运行；从菜单栏重新打开。真正退出 Docker 会恢复系统 Dock。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Picker("外观", selection: configurationBinding(\.appearance)) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }.frame(maxWidth: 400)
                Divider()
                setting("启用显示／隐藏控制台快捷键", detail: "默认 ⌃⌥⌘D。与其他应用冲突时会提示。", key: \.mainShortcutEnabled)
                Picker("快捷键按键", selection: configurationBinding(\.shortcutKeyCode)) {
                    Text("D").tag(UInt32(2)); Text("空格").tag(UInt32(49)); Text("F12").tag(UInt32(111))
                }.frame(maxWidth: 400)
                Picker("修饰键", selection: configurationBinding(\.shortcutModifiers)) {
                    Text("⌃⌥⌘").tag(UInt32(0x1900)); Text("⌃⌥").tag(UInt32(0x1800)); Text("⌥⌘").tag(UInt32(0x0900))
                }.frame(maxWidth: 400)
            }
            panel {
                Text("配置与恢复").font(.headline)
                HStack {
                    Button("导出配置…") { store.exportConfiguration() }
                    Button("导入配置…") { store.importConfiguration() }
                    Button("显示配置文件") { NSWorkspace.shared.activateFileViewerSelecting([store.configURL]) }
                }
                Text("配置保存在本机，修改时自动备份。导入前校验文件，不受支持的版本不会覆盖当前配置。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button(store.configuration.nativeDockHidden ? "恢复系统 Dock 并暂停 Docker Dock" : "重新接管 Dock") {
                    store.change { $0.nativeDockHidden.toggle() }
                }
                Text("系统 Dock 恢复组件会在主程序意外退出后撤销接管。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Docker").font(.title2)
                    Text("Designed & developed by Forsyth").font(.callout)
                    Text("版本 1.0.0 · 本机运行，无需账户").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("第三方致谢") {
                    if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

@MainActor
private struct GroupEditor: View {
    @UIState var group: StackConfiguration
    let symbols: [(String, String)]
    let existing: [StackConfiguration]
    let members: [CatalogApplication]
    var onSave: (StackConfiguration) -> Void
    var onCancel: () -> Void
    private var normalizedName: String { group.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool { !normalizedName.isEmpty && normalizedName.count <= 40 && !existing.contains { $0.id != group.id && $0.name == normalizedName } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing.contains(where: { $0.id == group.id }) ? "编辑叠放" : "新建叠放").font(.title2)
            TextField("叠放名称", text: $group.name).textFieldStyle(.roundedBorder)
            Picker("图标", selection: $group.symbol) {
                if !symbols.contains(where: { $0.0 == group.symbol }) { Text("当前图标").tag(group.symbol) }
                ForEach(symbols, id: \.0) { symbol, title in Label(title, systemImage: symbol.replacingOccurrences(of: "custom:", with: "")).tag(symbol) }
            }
            .onChange(of: group.symbol) { _, symbol in
                if symbol.hasPrefix("custom:") { group.topApplicationID = nil }
            }
            Picker("最上面的应用", selection: Binding(get: { group.topApplicationID ?? "" }, set: { id in
                group.topApplicationID = id.isEmpty ? nil : id
                if !id.isEmpty { group.symbol = "square.stack.3d.up" }
            })) {
                Text("自动（按应用顺序）").tag("")
                ForEach(members) { app in Text(app.name).tag(app.id) }
            }.disabled(members.isEmpty)
            Text(members.isEmpty ? "添加应用后，可指定显示在最上面的应用。" : "指定应用会显示在叠放最前面，展开顺序保持不变。")
                .font(.caption).foregroundStyle(.secondary)
            Text("保存后，可将应用拖入叠放，或从应用行的分组菜单中选择。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { group.name = normalizedName; onSave(group) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid)
            }
        }.padding(26).frame(width: 410).tint(.primary)
    }
}
