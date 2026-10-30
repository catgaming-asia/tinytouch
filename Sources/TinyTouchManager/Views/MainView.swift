import SwiftUI
import TinyTouchCore

struct MainView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { ConnectionBadge().padding(10) }
        } detail: {
            Group {
                switch model.selection ?? .overview {
                case .guide: GuideView()
                case .overview: OverviewView()
                case .fingers: FingersView()
                case .mode: ModeView()
                case .keys: PostKeyView()
                case .passkeys: PasskeysView()
                case .pairing: PairingView()
                case .unlock: UnlockSettingsView()
                case .firmware: FirmwareView()
                case .logs: LogsView()
                case .advanced: AdvancedView()
                }
            }
            .navigationTitle((model.selection ?? .overview).title)
            .toolbar {
                ToolbarItem {
                    Button {
                        Task { try? await model.refresh() }
                    } label: {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.connection.isConnected || model.busy)
                    .help("Đọc lại trạng thái thiết bị")
                }
            }
        }
        .sheet(item: Binding(
            get: { model.authPrompt.map { IdentifiedPrompt(prompt: $0) } },
            set: { if $0 == nil { model.authPrompt = nil } }
        )) { item in
            AuthPromptSheet(prompt: item.prompt)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
    }
}

private struct IdentifiedPrompt: Identifiable {
    let prompt: AuthPrompt
    var id: String { prompt.title }
}

struct ConnectionBadge: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .searching: return .gray
        case .failed: return .red
        }
    }

    private var title: String {
        switch model.connection {
        case .connected: return "Đã kết nối"
        case .connecting: return "Đang kết nối…"
        case .searching: return "Chưa cắm thiết bị"
        case .failed: return "Lỗi kết nối"
        }
    }

    private var detail: String? {
        switch model.connection {
        case let .connected(path), let .connecting(path): return path
        case let .failed(message): return message
        case .searching: return nil
        }
    }
}

struct AuthPromptSheet: View {
    let prompt: AuthPrompt

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: prompt.lift ? "hand.raised" : "touchid")
                .font(.system(size: 56))
                .foregroundStyle(prompt.lift ? .orange : .accentColor)
                .symbolEffectPulse()
            Text(prompt.title).font(.title3.weight(.semibold))
            Text(prompt.message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let step = prompt.step, let total = prompt.total, total > 1 {
                ProgressView(value: Double(min(step, total)), total: Double(total)) {
                    Text("Bước \(min(step, total))/\(total)")
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(28)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}

private extension View {
    @ViewBuilder
    func symbolEffectPulse() -> some View {
        if #available(macOS 14.0, *) {
            symbolEffect(.pulse)
        } else {
            self
        }
    }
}

/// Shared "not connected" placeholder for device sections.
struct RequiresDevice<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @ViewBuilder var content: () -> Content

    var body: some View {
        if model.connection.isConnected {
            content()
        } else {
            VStack(spacing: 12) {
                Image(systemName: "cable.connector").font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Chưa kết nối tinyTouch").font(.title3.weight(.semibold))
                Text(hint).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                Button("Thử kết nối lại") { model.reconnect() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var hint: String {
        if case let .failed(message) = model.connection { return message }
        return "Cắm tinyTouch vào cổng USB. App sẽ tự nhận thiết bị."
    }
}
