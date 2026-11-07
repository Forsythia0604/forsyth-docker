import SwiftUI
import WidgetKit

struct DockerQuitControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.forsyth.docker.quit") {
            ControlWidgetButton(action: DockerQuitControlIntent()) {
                Label("一键退出", systemImage: "power")
            }
        }
        .displayName("一键退出")
        .description("正常退出其他应用，保留名单中的应用继续运行。")
    }
}

@main
struct DockerControls: WidgetBundle {
    var body: some Widget { DockerQuitControl() }
}
