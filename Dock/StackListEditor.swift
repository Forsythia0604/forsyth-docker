import AppKit
import SwiftUI

private typealias StackEditorState<Value> = SwiftUI.State<Value>

@MainActor
final class StackListEditorController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(groupID: String, store: DockerStore, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 510),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "编辑叠放列表"
        window.contentMinSize = NSSize(width: 660, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: StackListEditor(groupID: groupID, store: store) { [weak self] members in
            store.setGroupMembers(members, for: groupID)
            self?.close()
        } onCancel: { [weak self] in self?.close() })
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

@MainActor
private struct StackListEditor: View {
    let groupID: String
    @ObservedObject var store: DockerStore
    var onSave: ([String]) -> Void
    var onCancel: () -> Void
    @StackEditorState private var memberIDs: [String]
    @StackEditorState private var originalMembers: [String]
    @StackEditorState private var search = ""

    init(groupID: String, store: DockerStore, onSave: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.groupID = groupID
        self.store = store
        self.onSave = onSave
        self.onCancel = onCancel
        let members = store.configuration.orderedMemberIDs(in: groupID)
        _memberIDs = StackEditorState(initialValue: members)
        _originalMembers = StackEditorState(initialValue: members)
    }

    private var group: StackConfiguration? { store.configuration.groups.first { $0.id == groupID } }
    private var membershipChanged: Bool { store.configuration.orderedMemberIDs(in: groupID) != originalMembers }
    private var available: [CatalogApplication] {
        let selected = Set(memberIDs)
        return store.orderedCatalog.filter {
            $0.installed && !DockerConfiguration.protectedIDs.contains($0.id) && !selected.contains($0.id)
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.id.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("编辑「\(group?.name ?? "叠放")」的列表").font(.title2)
                Text("添加、移除或调整顺序，保存后立即更新 Dock。").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("叠放中的应用（\(memberIDs.count)）").font(.headline)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(memberIDs, id: \.self) { id in memberRow(record(for: id)) }
                            if memberIDs.isEmpty {
                                Text("还没有应用\n从右侧添加到这个叠放。")
                                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 55)
                            }
                        }.padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("stack-member-list")
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Text("添加应用").font(.headline)
                    TextField("搜索应用", text: $search).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("stack-app-search")
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(available) { app in availableRow(app) }
                            if available.isEmpty {
                                Text(store.scanning ? "正在读取应用…" : "没有符合条件的应用。")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                            }
                        }.padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.frame(maxWidth: .infinity)
            }
            if group == nil {
                Text("这个叠放已被删除，请关闭此窗口。").font(.callout).foregroundStyle(.secondary)
            } else if membershipChanged {
                HStack {
                    Text("列表已在其他位置更新，请重新载入后编辑。").font(.callout).foregroundStyle(.secondary)
                    Button("重新载入") {
                        originalMembers = store.configuration.orderedMemberIDs(in: groupID)
                        memberIDs = originalMembers
                    }
                }
            }
            HStack {
                Text("移除后，应用仅在运行时显示。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(memberIDs) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(group == nil || membershipChanged)
                    .accessibilityIdentifier("save-stack-list")
            }
        }.padding(24).frame(minWidth: 660, minHeight: 420)
            .background(Color(nsColor: .windowBackgroundColor)).tint(.primary)
    }

    private func record(for id: String) -> CatalogApplication {
        if let app = store.catalog.first(where: { $0.id == id }) { return app }
        let rule = store.rule(for: id)
        return CatalogApplication(id: id, name: rule.name.isEmpty ? id : rule.name, path: rule.path ?? "", installed: false)
    }

    private func memberRow(_ app: CatalogApplication) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: store.icon(for: app)).resizable().frame(width: 28, height: 28)
            Text(app.name).lineLimit(1).help(app.name).frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                Button { move(app.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(memberIDs.first == app.id).help("向上移动")
                    .accessibilityLabel("向上移动 \(app.name)")
                Button { move(app.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(memberIDs.last == app.id).help("向下移动")
                    .accessibilityLabel("向下移动 \(app.name)")
                Button { memberIDs.removeAll { $0 == app.id } } label: { Image(systemName: "minus.circle") }
                    .help("从叠放中移除").accessibilityLabel("从叠放中移除 \(app.name)")
            }.buttonStyle(.borderless).controlSize(.small)
        }.padding(.horizontal, 4).padding(.vertical, 8).contentShape(Rectangle())
            .contextMenu { Button("从叠放中移除") { memberIDs.removeAll { $0 == app.id } } }
    }

    private func availableRow(_ app: CatalogApplication) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: store.icon(for: app)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1).help(app.name)
                if let source = store.configuration.groups.first(where: { $0.id == store.rule(for: app.id).groupID }), source.id != groupID {
                    Text("将从「\(source.name)」移入").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { memberIDs.append(app.id) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless).help("添加到叠放").accessibilityLabel("添加 \(app.name) 到叠放")
        }.padding(.horizontal, 4).padding(.vertical, 8)
    }

    private func move(_ id: String, by distance: Int) {
        guard let from = memberIDs.firstIndex(of: id) else { return }
        let to = max(0, min(memberIDs.count - 1, from + distance))
        memberIDs.remove(at: from)
        memberIDs.insert(id, at: to)
    }
}
