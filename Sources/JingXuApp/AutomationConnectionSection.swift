import SwiftUI

struct AutomationConnectionSection: View {
    @ObservedObject var connection: AutomationConnection
    var body: some View {
        Section("AI 助手连接") {
            Toggle("允许 AI 助手连接", isOn: Binding(get: { connection.enabled }, set: { connection.setEnabled($0) }))
                .disabled(connection.changing)
            HStack {
                TextField("本机端口", value: $connection.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 190)
                    .disabled(connection.enabled || connection.changing)
                if connection.changing { ProgressView().controlSize(.small) }
            }
            if connection.enabled {
                Text(connection.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                HStack {
                    Button("复制 Codex 连接配置") { connection.copyConfiguration() }
                    Button("重置连接密钥") { connection.setEnabled(true, resetKey: true) }
                }.disabled(connection.changing)
                Text("Codex 可读取当前选择的预览和参数，保存可撤销的调色。批量和导出先在 Codex 展示清单并确认。重置密钥后需更新 Codex 配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(connection.status).font(.caption).textSelection(.enabled)
        }
    }
}
