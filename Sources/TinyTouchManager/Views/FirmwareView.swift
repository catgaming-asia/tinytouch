import AppKit
import SwiftUI
import TinyTouchCore

struct FirmwareView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FirmwareContent(updater: model.firmware)
    }
}

private struct FirmwareContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var updater: FirmwareUpdater
    @State private var confirm = false
    @State private var confirmRecovery = false
    @State private var useLocalFile = false
    @State private var localFile: URL?

    var body: some View {
        Form {
            Section("Phiên bản") {
                LabeledContent("Trên thiết bị", value: model.status.map { "v\($0.firmwareVersion)" } ?? "—")
                LabeledContent("Mới nhất (MrOld)", value: updater.manifest.map { "v\($0.version) · \($0.releaseDate ?? "")" } ?? "Đang kiểm tra…")
                if updater.isNewer(than: model.status?.firmwareVersion) {
                    Label("Có bản cập nhật firmware mới.", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                } else if updater.manifest != nil && model.status != nil {
                    Label("Firmware đã là bản mới nhất.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }

            Section {
                if let backup = updater.backup {
                    Label("Đã lưu gói firmware v\(backup.version) của thiết bị này", systemImage: "externaldrive.fill.badge.checkmark")
                        .foregroundStyle(.green)
                } else {
                    Label("Chưa có gói dự phòng cho thiết bị này", systemImage: "externaldrive.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                if updater.usingCachedManifest {
                    Text("Web MrOld đang không truy cập được – đang dùng manifest đã lưu.").foregroundStyle(.orange)
                }
                if let error = updater.backupError { Text(error).foregroundStyle(.red) }
                HStack {
                    Button("Sao lưu ngay") { Task { await updater.backupDevicePackage() } }
                        .disabled(!model.connection.isConnected)
                    Button("Mở thư mục") { NSWorkspace.shared.open(FirmwareUpdater.cacheDirectory) }
                }
            } header: {
                Text("Gói dự phòng offline")
            } footer: {
                Text("App tự lưu manifest và gói firmware riêng của thiết bị (đã mã hóa theo chip, tìm theo MAC trong số serial TT-…) để cập nhật/cứu hộ khi web MrOld không hoạt động. Lưu tại ~/Library/Application Support/TinyTouchManager/firmware.")
            }

            Section {
                LabeledContent("esptool", value: updater.esptoolPath ?? "Chưa cài")
                if updater.esptoolPath == nil {
                    Text("Cài công cụ nạp bằng lệnh:  brew install esptool").font(.callout.monospaced()).textSelection(.enabled)
                }
                Picker("Nguồn firmware", selection: $useLocalFile) {
                    Text("Tải từ web MrOld (tự dùng bản đã lưu khi web sập)").tag(false)
                    Text("Chọn file .bin trên máy").tag(true)
                }
                .pickerStyle(.radioGroup)
                if useLocalFile {
                    HStack {
                        Text(localFile?.path ?? "Chưa chọn file").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Chọn file…", action: pickFile)
                    }
                }
                Button("Cập nhật firmware…") { confirm = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connection.isConnected || updater.isRunning || updater.esptoolPath == nil || model.busy || !sourceReady)
                Button("Cứu hộ: nạp lại gói đã lưu (thiết bị đang ở chế độ nạp)…") { confirmRecovery = true }
                    .disabled(updater.isRunning || updater.esptoolPath == nil || model.connection.isConnected || !sourceReady)
                    .help("Dùng khi tinyTouch không chạy được: giữ nút BOOT khi cắm USB để vào chế độ nạp.")
                if updater.phase == .flashing || updater.progress > 0 {
                    ProgressView(value: updater.progress) { Text("Đang nạp: \(Int(updater.progress * 100))%") }
                }
                if case let .failed(message) = updater.phase {
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                }
            } header: {
                Text("Cập nhật")
            } footer: {
                Text("Quy trình giống trang web: chạm vân tay → thiết bị vào chế độ nạp → đọc MAC chip → tải đúng gói (riêng theo thiết bị hoặc gói chung) → kiểm tra SHA-256 → nạp tại 0x10000. Không rút cáp trong lúc nạp.")
            }

            if !updater.lines.isEmpty {
                Section("Tiến trình") {
                    ScrollView {
                        Text(updater.lines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 220)
                }
            }
        }
        .formStyle(.grouped)
        .task { await updater.loadManifest() }
        .confirmationDialog("Cập nhật firmware tinyTouch?", isPresented: $confirm) {
            Button("Bắt đầu cập nhật") { updater.start(source: source) }
        } message: {
            Text("Thiết bị sẽ khởi động lại vào chế độ nạp. Không rút cáp USB cho tới khi hoàn tất.")
        }
        .confirmationDialog("Nạp lại firmware ở chế độ cứu hộ?", isPresented: $confirmRecovery) {
            Button("Nạp lại") { updater.start(recovery: true, source: source) }
        } message: {
            Text("App đọc MAC chip rồi nạp đúng gói của thiết bị (ưu tiên bản đã lưu trên máy). Không rút cáp USB cho tới khi hoàn tất.")
        }
    }

    private var source: FirmwareUpdater.Source { useLocalFile ? (localFile.map { .local($0) } ?? .web) : .web }
    private var sourceReady: Bool { !useLocalFile || localFile != nil }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "bin") ?? .data]
        panel.directoryURL = FirmwareUpdater.cacheDirectory
        panel.message = "Chọn gói firmware tinyTouch (.bin)"
        if panel.runModal() == .OK { localFile = panel.url }
    }
}
