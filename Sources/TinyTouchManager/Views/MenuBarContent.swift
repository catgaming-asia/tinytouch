import SwiftUI
import TinyTouchCore

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var opener: WindowOpener { WindowOpener(openWindow: openWindow) }

    var body: some View {
        Text(statusTitle)
        if let path = model.port?.path {
            Text(path)
        }

        Divider()

        Toggle("Mở khóa màn hình", isOn: $model.unlockEnabled)
        Toggle("Bảo vệ: Chỉ nhập tại ô mật khẩu", isOn: $model.guardEnabled)
        Menu("Đèn LED nhắc nhở khi cần mật khẩu") {
            Toggle("Bật đèn nhắc nhở", isOn: $model.promptLedEnabled)
            Divider()
            Picker("Tự tắt sau", selection: $model.promptLedTimeoutMinutes) {
                ForEach(PromptLedMonitor.timeoutChoices, id: \.self) { minutes in
                    Text(minutes == 0 ? "Không giới hạn" : "\(minutes) phút").tag(minutes)
                }
            }
            .pickerStyle(.inline)
        }
        Toggle("Xác thực sudo (Terminal)", isOn: $model.sudoEnabled)
        Toggle("Khởi động cùng macOS", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))

        Divider()

        Button("Mở trình quản lý thiết bị…") { opener.open(.overview) }
            .keyboardShortcut("o")
        Button("Cài đặt & Mật khẩu…") { opener.open(.unlock) }
            .keyboardShortcut(",")
        Button("Quản lý ghép đôi thiết bị…") { opener.open(.pairing) }
            .keyboardShortcut("p")
        Button("Xem nhật ký hoạt động…") { opener.open(.logs) }
            .keyboardShortcut("l")

        if !model.accessibilityTrusted {
            Divider()
            Button("⚠️ Cấp quyền Trợ năng…") { SystemContext.requestAccessibility() }
        }

        Divider()

        Text("Phiên bản App: v\(AppModel.appVersion)")
        Text("Phiên bản FW: \(model.status.map { "v\($0.firmwareVersion)" } ?? "—")")

        Divider()

        Button("Thoát TinyTouch Manager") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusTitle: String {
        switch model.connection {
        case .connected: return "🟢 tinyTouch: Đã kết nối"
        case .connecting: return "🟡 tinyTouch: Đang kết nối…"
        case .searching: return "⚪️ tinyTouch: Chưa cắm thiết bị"
        case .failed: return "🔴 tinyTouch: Lỗi kết nối"
        }
    }
}
