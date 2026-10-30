import AppKit
import SwiftUI
import TinyTouchCore

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var removing: String?

    var body: some View {
        RequiresDevice {
            Form {
                Section {
                    LabeledContent("Trạng thái", value: model.isPaired ? "Đã ghép đôi" : "Chưa ghép đôi")
                    if let id = model.thisMacHostID {
                        LabeledContent("Mã máy này", value: id).textSelection(.enabled)
                    }
                    Button(model.isPaired ? "Ghép đôi lại (tạo mã mới)" : "⚡ Tạo mã & ghép đôi tự động") { model.pairThisMac() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy)
                } header: {
                    Text("Mac này")
                } footer: {
                    Text("Tạo khóa ghép đôi ngẫu nhiên 32 byte, lưu trong Keychain của Mac và gửi cho thiết bị (cần chạm vân tay). Sau đó, mỗi lần chạm, thiết bị gửi sự kiện có chữ ký và Mac trả lại mật khẩu đã mã hóa để thiết bị tự gõ.")
                }

                Section {
                    if let ids = model.hostIDs {
                        if ids.isEmpty { Text("Chưa có máy nào.").foregroundStyle(.secondary) }
                        ForEach(ids, id: \.self) { id in
                            HStack {
                                Image(systemName: id == model.thisMacHostID ? "laptopcomputer" : "desktopcomputer")
                                Text(id).font(.body.monospaced())
                                if id == model.thisMacHostID { Text("(Mac này)").foregroundStyle(.secondary) }
                                Spacer()
                                Button("Gỡ", role: .destructive) { removing = id }
                            }
                        }
                    } else {
                        Text("Firmware không hỗ trợ liệt kê máy đã ghép.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Máy đã ghép với thiết bị (\(model.hostIDs?.count ?? model.status?.hidHosts ?? 0)/8)")
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
            .confirmationDialog("Gỡ máy \(removing ?? "") khỏi tinyTouch?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }
            )) {
                Button("Gỡ ghép đôi", role: .destructive) { if let removing { model.removeHost(removing) } }
            } message: {
                Text("Máy đó sẽ không mở khóa bằng tinyTouch được nữa cho tới khi ghép đôi lại.")
            }
        }
    }
}

// MARK: - Auto unlock settings & Mac passwords

struct UnlockSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingSlot: Int?
    @State private var deletingSlot: Int?

    var body: some View {
        Form {
            Section {
                Toggle("Mở khóa màn hình", isOn: $model.unlockEnabled)
                Toggle("Bảo vệ: chỉ nhập tại ô mật khẩu", isOn: $model.guardEnabled)
                Toggle("Xác thực sudo trong Terminal", isOn: $model.sudoEnabled)
                Toggle("Đèn LED nhắc nhở khi cần mật khẩu", isOn: $model.promptLedEnabled)
                Picker("Đèn tự tắt sau", selection: $model.promptLedTimeoutMinutes) {
                    ForEach(PromptLedMonitor.timeoutChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Không giới hạn" : "\(minutes) phút").tag(minutes)
                    }
                }
                .disabled(!model.promptLedEnabled)
                Toggle("Khởi động cùng macOS", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            } header: {
                Text("Tự động mở khóa")
            } footer: {
                Text("Khi bật Bảo vệ, Mac chỉ gửi mật khẩu khi màn hình đang khóa, hộp thoại xác thực của macOS đang mở, hoặc con trỏ đang ở ô mật khẩu. Với Terminal, chỉ khi sudo đang hỏi mật khẩu.")
            }

            Section {
                HStack {
                    Image(systemName: model.accessibilityTrusted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .foregroundStyle(model.accessibilityTrusted ? .green : .orange)
                    Text(model.accessibilityTrusted ? "Đã cấp quyền Trợ năng" : "Chưa cấp quyền Trợ năng – cần để nhận biết ô mật khẩu")
                    Spacer()
                    if !model.accessibilityTrusted {
                        Button("Cấp quyền…") { SystemContext.requestAccessibility() }
                        Button("Mở Cài đặt") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
            } header: {
                Text("Quyền hệ thống")
            }

            Section {
                passwordRow(slot: 0, title: "Mật khẩu mặc định (mọi ngón)")
                ForEach(1...5, id: \.self) { slot in
                    passwordRow(slot: slot, title: "\(SlotInfo(id: slot).name) (ngón \(slot))")
                }
            } header: {
                Text("Mật khẩu Mac lưu trong Keychain")
            } footer: {
                Text("Dùng cho mở khóa qua ghép đôi: mật khẩu nằm trong Keychain của Mac này, chỉ gửi sang thiết bị (đã mã hóa) khi vân tay khớp. Ngón nào không có mật khẩu riêng sẽ dùng mật khẩu mặc định.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshMacState() }
        .sheet(item: $editingSlot.identified) { slot in
            PasswordSheet(title: slot.value == 0 ? "Mật khẩu Mac mặc định" : "Mật khẩu Mac cho ngón \(slot.value)",
                          note: "Thường là mật khẩu đăng nhập của Mac này. Được lưu trong Keychain.") { password in
                editingSlot = nil
                if let password { model.saveMacPassword(slot: slot.value, password: password) }
            }
        }
        .confirmationDialog("Xóa mật khẩu đã lưu?", isPresented: $deletingSlot.isPresent) {
            Button("Xóa", role: .destructive) { if let deletingSlot { model.deleteMacPassword(slot: deletingSlot) } }
        }
    }

    private func passwordRow(slot: Int, title: String) -> some View {
        let saved = model.macPasswordSlots.contains(slot)
        return HStack {
            Image(systemName: saved ? "key.fill" : "key").foregroundStyle(saved ? Color.accentColor : .secondary)
            Text(title)
            Spacer()
            Text(saved ? "Đã lưu" : "Chưa lưu").foregroundStyle(.secondary)
            Button(saved ? "Đổi" : "Đặt") { editingSlot = slot }
            if saved { Button("Xóa", role: .destructive) { deletingSlot = slot } }
        }
    }
}

// MARK: - Logs & console

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""
    @State private var showTraffic = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(filtered) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(symbol(entry.kind))
                        Text(entry.message)
                            .font(entry.kind == .tx || entry.kind == .rx ? .callout.monospaced() : .callout)
                            .foregroundStyle(color(entry.kind))
                            .textSelection(.enabled)
                    }
                    .id(entry.id)
                }
                .onChange(of: model.logs.count) { _ in
                    if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Toggle("Hiện lệnh TX/RX", isOn: $showTraffic).toggleStyle(.checkbox)
                TextField("Gửi lệnh thô tới thiết bị (vd: STATUS)", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(send)
                    .disabled(!model.connection.isConnected)
                Button("Gửi", action: send).disabled(command.isEmpty || !model.connection.isConnected)
                Button("Xóa nhật ký") { model.clearLogs() }
            }
            .padding(10)
        }
    }

    private var filtered: [LogEntry] {
        showTraffic ? model.logs : model.logs.filter { $0.kind != .tx && $0.kind != .rx }
    }

    private func send() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        showTraffic = true
        model.sendRaw(text)
        command = ""
    }

    private func symbol(_ kind: LogEntry.Kind) -> String {
        switch kind {
        case .info: return "ℹ️"
        case .success: return "✅"
        case .warning: return "⚠️"
        case .error: return "❌"
        case .tx: return "→"
        case .rx: return "←"
        }
    }

    private func color(_ kind: LogEntry.Kind) -> Color {
        switch kind {
        case .error: return .red
        case .warning: return .orange
        case .tx: return .blue
        case .rx: return .secondary
        default: return .primary
        }
    }
}
