import SwiftUI
import TinyTouchCore

// MARK: - Overview

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RequiresDevice {
            Form {
                if let status = model.status {
                    Section("Thiết bị") {
                        LabeledContent("Chế độ hiện tại", value: status.mode?.title ?? "—")
                        LabeledContent("Vân tay đã lưu", value: "\(status.fingerprints)")
                        LabeledContent("Cảm biến vân tay", value: status.sensor == "ok" ? "Hoạt động tốt" : status.sensor)
                        LabeledContent("Passkeys FIDO2", value: passkeySummary)
                        LabeledContent("Firmware", value: "\(status.firmware) v\(status.firmwareVersion) (protocol \(status.protocolVersion))")
                        LabeledContent("Serial", value: model.port?.serialNumber ?? "—")
                        LabeledContent("Cổng", value: model.port?.path ?? "—")
                    }
                    Section("Gõ phím") {
                        LabeledContent("Phím sau khi điền", value: status.postKey)
                        LabeledContent("Chờ giữa các phím", value: "\(status.postKeyDelay) ms")
                        LabeledContent("Chờ khi đánh thức", value: "\(status.wakeDelay) ms")
                    }
                    Section("Mac này") {
                        LabeledContent("Ghép đôi", value: model.isPaired ? "Đã ghép đôi" : "Chưa ghép đôi")
                        LabeledContent("Máy đã ghép với thiết bị", value: "\(status.hidHosts)")
                        LabeledContent("Mật khẩu Mac (Keychain)", value: model.macPasswordSlots.isEmpty ? "Chưa lưu" : "Đã lưu \(model.macPasswordSlots.count)")
                        LabeledContent("Quyền Trợ năng", value: model.accessibilityTrusted ? "Đã cấp" : "Chưa cấp")
                    }
                } else {
                    ProgressView()
                }
            }
            .formStyle(.grouped)
        }
    }

    private var passkeySummary: String {
        if model.passkeysLocked { return "🔒 Cần xác thực để xem" }
        return model.passkeys.map { "\($0.count)" } ?? "—"
    }
}

// MARK: - Fingers & chip passwords

struct FingersView: View {
    @EnvironmentObject private var model: AppModel
    @State private var enrollSlot: Int?
    @State private var passwordSlot: Int?
    @State private var clearSlot: Int?

    var body: some View {
        RequiresDevice {
            Form {
                Section {
                    ForEach(model.slots) { slot in
                        HStack(spacing: 12) {
                            Text("\(slot.id)")
                                .font(.headline.monospacedDigit())
                                .frame(width: 26, height: 26)
                                .background(slot.enrolled ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slot.name).font(.body.weight(.medium))
                                HStack(spacing: 8) {
                                    tag(slot.enrolled ? "Đã đăng ký vân tay" : "Chưa đăng ký", on: slot.enrolled)
                                    tag(slot.hasChipPassword ? "Có mật khẩu trên chip" : "Chưa có mật khẩu chip", on: slot.hasChipPassword)
                                }
                            }
                            Spacer()
                            Button(slot.enrolled ? "Đăng ký lại" : "Đăng ký") { enrollSlot = slot.id }
                            Button("Gán mật khẩu") { passwordSlot = slot.id }
                            Button("Xóa mật khẩu") { clearSlot = slot.id }
                                .disabled(!slot.hasChipPassword)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("5 ngón tay – 5 mật khẩu riêng")
                } footer: {
                    Text("Mật khẩu trên chip được thiết bị tự gõ ở chế độ HID, không cần app (Mac/Windows/Linux). Mỗi thay đổi cần chạm vân tay chủ sở hữu.")
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
            .sheet(item: $enrollSlot.identified) { slot in
                EnrollSheet(slot: slot.value) { touches in
                    enrollSlot = nil
                    afterSheet { model.enroll(slot: slot.value, touches: touches) }
                }
            }
            .sheet(item: $passwordSlot.identified) { slot in
                PasswordSheet(title: "Mật khẩu trên chip cho \(SlotInfo(id: slot.value).name)",
                              note: "Mật khẩu được lưu mã hóa trên chip tinyTouch.") { password in
                    passwordSlot = nil
                    if let password { afterSheet { model.setChipPassword(slot: slot.value, password: password) } }
                }
            }
            .confirmationDialog("Xóa mật khẩu trên chip của ngón \(clearSlot ?? 0)?", isPresented: $clearSlot.isPresent) {
                Button("Xóa", role: .destructive) { if let slot = clearSlot { model.clearChipPassword(slot: slot) } }
            }
        }
    }

    private func tag(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((on ? Color.green : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(on ? Color.green : Color.secondary)
    }
}

struct EnrollSheet: View {
    let slot: Int
    let start: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var touches = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Đăng ký \(SlotInfo(id: slot).name)").font(.title3.weight(.semibold))
            Picker("Kiểu đăng ký", selection: $touches) {
                Text("Đa góc – 6 lần chạm (chính xác hơn)").tag(6)
                Text("Nhanh – 2 lần chạm").tag(2)
            }
            .pickerStyle(.radioGroup)
            Text("Đặt thẳng ngón tay, áp trọn tâm vân tay vào giữa cảm biến. Với kiểu đa góc, mỗi lần chạm hãy nghiêng nhẹ ngón tay sang một góc khác.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Hủy") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Bắt đầu") { start(touches) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

struct PasswordSheet: View {
    let title: String
    let note: String
    let completion: (String?) -> Void
    @State private var password = ""
    @State private var confirm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            SecureField("Mật khẩu", text: $password)
            SecureField("Nhập lại mật khẩu", text: $confirm)
            if !confirm.isEmpty && confirm != password {
                Text("Hai lần nhập không khớp").font(.caption).foregroundStyle(.red)
            }
            Text(note).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Hủy") { completion(nil) }.keyboardShortcut(.cancelAction)
                Button("Lưu") { completion(password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || password != confirm)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Mode

struct ModeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        RequiresDevice {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    modeCard(.hid, icon: "keyboard", badge: "Khuyên dùng",
                             text: "Bàn phím tự động gõ. Điền mật khẩu ở mọi nơi (màn hình khóa Mac/Win, Safari, 1Password, Terminal sudo…).",
                             bullets: ["Hỗ trợ 5 ngón tay tương ứng 5 tài khoản/mật khẩu riêng", "Cắm là dùng trên Mac, Windows và Linux"])
                    modeCard(.piv, icon: "creditcard", badge: "SmartCard",
                             text: "Mac nhận tinyTouch là thẻ thông minh SmartCard. Xác thực bằng chứng chỉ số X.509 cho đăng nhập macOS và sudo.",
                             bullets: ["Bảo mật mã hóa phần cứng X.509", "Mở khóa màn hình đăng nhập macOS và sudo"])
                }
                .padding(20)
            }
        }
    }

    private func modeCard(_ mode: DeviceMode, icon: String, badge: String, text: String, bullets: [String]) -> some View {
        let active = model.status?.mode == mode
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.title2)
                Text(mode.rawValue.uppercased() + " Mode").font(.title3.weight(.semibold))
                Spacer()
                Text(active ? "Đang dùng" : badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((active ? Color.green : Color.accentColor).opacity(0.15), in: Capsule())
            }
            Text(text).foregroundStyle(.secondary)
            ForEach(bullets, id: \.self) { Label($0, systemImage: "checkmark").font(.callout) }
            Spacer(minLength: 0)
            Button(active ? "Đang kích hoạt" : "Kích hoạt \(mode.rawValue.uppercased()) Mode") { model.setMode(mode) }
                .buttonStyle(.borderedProminent)
                .disabled(active || model.busy)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.green : Color.clear, lineWidth: 2))
    }
}

// MARK: - Post key

struct PostKeyView: View {
    @EnvironmentObject private var model: AppModel
    @State private var custom = ["enter", "none", "none"]
    @State private var keyDelay = 50.0
    @State private var wakeDelay = 0.0

    var body: some View {
        RequiresDevice {
            Form {
                Section {
                    ForEach(PostKey.presets, id: \.value) { preset in
                        HStack {
                            Image(systemName: current == preset.value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(current == preset.value ? Color.accentColor : .secondary)
                            VStack(alignment: .leading) {
                                Text(preset.title).font(.body.weight(.medium))
                                Text(preset.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if current != preset.value {
                                Button("Chọn") { model.setPostKey(preset.value) }
                            }
                        }
                    }
                } header: {
                    Text("Chuỗi phím sau khi điền mật khẩu (chỉ HID Mode)")
                } footer: {
                    Text("Hiện tại: \(current)")
                }

                Section("Tự ghép chuỗi (tối đa 3 phím)") {
                    HStack {
                        ForEach(0..<3, id: \.self) { index in
                            Picker("Phím \(index + 1)", selection: $custom[index]) {
                                ForEach(PostKey.keys, id: \.value) { Text($0.title).tag($0.value) }
                            }
                        }
                    }
                    HStack {
                        Text("Kết quả: \(PostKey.normalize(custom.joined(separator: ",")) ?? "—")").foregroundStyle(.secondary)
                        Spacer()
                        Button("Lưu chuỗi tùy chỉnh") { model.setPostKey(custom.joined(separator: ",")) }
                    }
                }

                Section {
                    Slider(value: $keyDelay, in: 0...1000, step: 10) {
                        Text("Chờ giữa các phím: \(Int(keyDelay)) ms")
                    }
                    HStack {
                        ForEach([0, 50, 100, 200, 500], id: \.self) { value in
                            Button("\(value)ms") { keyDelay = Double(value) }
                        }
                        Spacer()
                        Button("Lưu") { model.setPostKeyDelay(Int(keyDelay)) }
                            .disabled(Int(keyDelay) == model.status?.postKeyDelay)
                    }
                } header: {
                    Text("Thời gian chờ giữa các phím kết thúc")
                }

                Section {
                    Slider(value: $wakeDelay, in: 0...3000, step: 100) {
                        Text("Chờ khi đánh thức máy: \(Int(wakeDelay)) ms")
                    }
                    HStack {
                        ForEach([0, 500, 1000, 1500, 2000], id: \.self) { value in
                            Button("\(value)ms") { wakeDelay = Double(value) }
                        }
                        Spacer()
                        Button("Lưu") { model.setWakeDelay(Int(wakeDelay)) }
                            .disabled(Int(wakeDelay) == model.status?.wakeDelay)
                    }
                } header: {
                    Text("Thời gian chờ khi đánh thức máy")
                } footer: {
                    Text("Tăng giá trị này nếu ký tự đầu của mật khẩu bị mất khi máy vừa thức dậy từ chế độ ngủ.")
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
            .onAppear(perform: load)
            .onChange(of: model.status) { _ in load() }
        }
    }

    private var current: String { model.status?.postKey ?? "enter" }

    private func load() {
        guard let status = model.status else { return }
        let parts = status.postKey.split(separator: ",").map(String.init)
        custom = (0..<3).map { $0 < parts.count ? parts[$0] : "none" }
        keyDelay = Double(status.postKeyDelay)
        wakeDelay = Double(status.wakeDelay)
    }
}

// MARK: - Passkeys

struct PasskeysView: View {
    @EnvironmentObject private var model: AppModel
    @State private var deleting: Passkey?
    @State private var confirmClear = false

    var body: some View {
        RequiresDevice {
            Form {
                if model.passkeysLocked || model.passkeys == nil {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(model.passkeysLocked ? "Danh sách Passkeys được bảo vệ bằng vân tay." : "Chưa đọc được danh sách Passkeys.",
                                  systemImage: "lock.fill")
                            Button("Xác thực vân tay để xem") { model.unlockPasskeys() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else if let passkeys = model.passkeys {
                    Section {
                        if passkeys.isEmpty {
                            Text("Chưa có Passkey nào trên chip.").foregroundStyle(.secondary)
                        }
                        ForEach(passkeys) { passkey in
                            HStack {
                                Image(systemName: "person.badge.key.fill").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading) {
                                    Text(passkey.rpId ?? "Không rõ tên miền").font(.body.weight(.medium))
                                    Text("Tài khoản: \(passkey.user ?? "—") · Đã dùng: \(passkey.counter ?? 0) lần · ID: \(shortID(passkey.id))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { deleting = passkey } label: { Image(systemName: "trash") }
                            }
                        }
                    } header: {
                        Text("Passkeys trên chip (\(passkeys.count))")
                    }
                    if !passkeys.isEmpty {
                        Section {
                            Button("Xóa toàn bộ Passkeys…", role: .destructive) { confirmClear = true }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.busy)
            .confirmationDialog("Xóa Passkey cho \(deleting?.rpId ?? "")?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            )) {
                Button("Xóa", role: .destructive) { if let deleting { model.deletePasskey(deleting) } }
            }
            .confirmationDialog("Xóa toàn bộ Passkeys trên chip? Không thể hoàn tác.", isPresented: $confirmClear) {
                Button("Xóa toàn bộ", role: .destructive) { model.clearPasskeys() }
            }
        }
    }

    private func shortID(_ id: String) -> String {
        id.count > 16 ? "\(id.prefix(8))…\(id.suffix(6))" : id
    }
}

// MARK: - Advanced

struct AdvancedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmText = ""

    var body: some View {
        RequiresDevice {
            Form {
                Section {
                    Text("Xóa toàn bộ vân tay, mật khẩu trên chip, máy đã ghép đôi và Passkeys FIDO2. Thiết bị khởi động lại về trạng thái xuất xưởng.")
                    TextField("Gõ RESET để xác nhận", text: $confirmText)
                        .textFieldStyle(.roundedBorder)
                    Button("Khôi phục cài đặt gốc", role: .destructive) {
                        confirmText = ""
                        model.factoryReset()
                    }
                    .disabled(confirmText != "RESET" || model.busy)
                } header: {
                    Text("Khôi phục cài đặt gốc")
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Helpers

struct IdentifiedInt: Identifiable {
    let value: Int
    var id: Int { value }
}

extension Binding where Value == Int? {
    var identified: Binding<IdentifiedInt?> {
        Binding<IdentifiedInt?>(
            get: { wrappedValue.map(IdentifiedInt.init) },
            set: { wrappedValue = $0?.value }
        )
    }

    var isPresent: Binding<Bool> {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

/// Runs `action` after a dismissing sheet has finished animating, so the next sheet can appear.
@MainActor
func afterSheet(_ action: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { action() }
}
