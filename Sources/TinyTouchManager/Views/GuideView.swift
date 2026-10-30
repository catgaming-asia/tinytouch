import AppKit
import SwiftUI

/// Full user guide, in-app so it stays available without the MrOld website.
struct GuideView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Hướng dẫn sử dụng TinyTouch Manager")
                    .font(.title2.weight(.semibold))
                Text("Mọi thứ trang web touch.mrold.xyz và app tinyTouch cũ làm được, nay nằm trong app này – kể cả khi web không còn hoạt động.")
                    .foregroundStyle(.secondary)

                GuideSection("1. Bắt đầu nhanh (lần đầu dùng)", icon: "flag.checkered", expanded: true) {
                    Steps([
                        "Cắm tinyTouch vào cổng USB. Biểu tượng vân tay trên menu bar chuyển sang 🟢 \"Đã kết nối\".",
                        "Menu bar → \"Cấp quyền Trợ năng…\" → bật TinyTouch Manager trong Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Trợ năng.",
                        "Mục Ghép đôi Mac → \"Tạo mã & ghép đôi tự động\" → chạm ngón đã đăng ký vào cảm biến.",
                        "Mục Tự động mở khóa → đặt Mật khẩu mặc định (thường là mật khẩu đăng nhập Mac).",
                        "Bật \"Khởi động cùng macOS\" (menu bar hoặc mục Tự động mở khóa).",
                        "Khóa màn hình (⌃⌘Q) rồi chạm vân tay để thử. Xem kết quả ở mục Nhật ký.",
                    ])
                    Jump("Mở Ghép đôi Mac", .pairing)
                }

                GuideSection("2. Hai cách tinyTouch gõ mật khẩu", icon: "key.horizontal") {
                    Bullet("Mật khẩu trên chip (mục Vân tay & Mật khẩu → Gán mật khẩu): lưu mã hóa trong tinyTouch, thiết bị tự gõ ở chế độ HID trên mọi máy (Mac/Windows/Linux), không cần app. Mỗi ngón 1–5 một mật khẩu riêng.")
                    Bullet("Mật khẩu Mac qua ghép đôi (mục Tự động mở khóa): lưu trong Keychain của Mac. Khi vân tay khớp, thiết bị gửi sự kiện có chữ ký, app kiểm tra ngữ cảnh rồi gửi mật khẩu đã mã hóa để thiết bị gõ. Có thêm lớp Bảo vệ: chỉ gõ ở màn hình khóa, hộp thoại xác thực, ô mật khẩu hoặc sudo.")
                    Note("Nếu dùng cách 2, nên để trống mật khẩu trên chip của ngón đó để lớp Bảo vệ của app có tác dụng.")
                }

                GuideSection("3. Đăng ký vân tay", icon: "touchid") {
                    Steps([
                        "Mục Vân tay & Mật khẩu → chọn ngón (1 Ngón trỏ, 2 Ngón giữa, 3 Ngón áp út, 4 Ngón cái, 5 Ngón út) → Đăng ký.",
                        "Chọn \"Đa góc – 6 lần chạm\" (chính xác hơn) hoặc \"Nhanh – 2 lần chạm\".",
                        "Nếu đã có vân tay, chạm ngón chủ sở hữu trước để mở khóa cấu hình.",
                        "Làm theo hộp thoại: đặt ngón → nhấc ra → đặt lại, mỗi lần nghiêng nhẹ một góc khác.",
                    ])
                    Note("Mọi thay đổi cấu hình (chế độ, mật khẩu, phím, Passkeys, ghép đôi, firmware) đều cần chạm vân tay chủ sở hữu.")
                    Jump("Mở Vân tay & Mật khẩu", .fingers)
                }

                GuideSection("4. Chế độ HID và PIV", icon: "switch.2") {
                    Bullet("HID (khuyên dùng): tinyTouch là bàn phím USB tự gõ mật khẩu. Dùng được ở màn hình khóa, Safari, 1Password, Terminal sudo… trên mọi hệ điều hành.")
                    Bullet("PIV: Mac nhận tinyTouch là thẻ SmartCard (chứng chỉ X.509, CryptoTokenKit) để đăng nhập macOS và sudo. Ở màn hình khóa, ô nhập sẽ hỏi PIN.")
                    Jump("Mở Chế độ hoạt động", .mode)
                }

                GuideSection("5. Phím sau khi điền & thời gian chờ", icon: "keyboard") {
                    Bullet("Chọn chuỗi phím tinyTouch bấm sau khi gõ mật khẩu: Enter, Enter→Space, Tab→Enter (cho ô 2FA/OTP), Enter×2, hoặc Không bấm. Có thể tự ghép tối đa 3 phím.")
                    Bullet("Chờ giữa các phím: tăng nếu ứng dụng bỏ sót phím Enter/Tab.")
                    Bullet("Chờ khi đánh thức: tăng (500–1500 ms) nếu ký tự đầu mật khẩu bị mất khi Mac vừa thức dậy.")
                    Jump("Mở Phím sau khi điền", .keys)
                }

                GuideSection("6. Tự động mở khóa – các công tắc", icon: "lock.open") {
                    Bullet("Mở khóa màn hình: cho phép gõ mật khẩu khi màn hình đang khóa.")
                    Bullet("Bảo vệ – chỉ nhập tại ô mật khẩu: chỉ gõ khi con trỏ ở ô mật khẩu, khi hộp thoại xác thực macOS đang mở, hoặc khi màn hình khóa. Cần quyền Trợ năng.")
                    Bullet("Xác thực sudo (Terminal): cho phép gõ khi Terminal/iTerm/Warp… đang hỏi mật khẩu sudo.")
                    Bullet("Đèn LED nhắc nhở: đèn trên tinyTouch sáng khi Mac đang chờ mật khẩu (lệnh LED_PROMPT), tự tắt sau thời gian đã chọn hoặc khi đã chạm.")
                    Bullet("Khởi động cùng macOS: app tự chạy khi đăng nhập.")
                    Jump("Mở Tự động mở khóa", .unlock)
                }

                GuideSection("7. Ghép đôi nhiều máy", icon: "link") {
                    Bullet("Một tinyTouch ghép được tối đa 8 máy. Mỗi Mac có khóa ghép đôi riêng trong Keychain.")
                    Bullet("Ghép đôi lại sẽ tạo khóa mới và tự gỡ khóa cũ của Mac này khỏi thiết bị.")
                    Bullet("Gỡ máy không dùng nữa trong danh sách để máy đó không mở khóa được.")
                }

                GuideSection("8. Passkeys FIDO2", icon: "person.badge.key") {
                    Bullet("Danh sách Passkeys được khóa bằng vân tay: bấm \"Xác thực vân tay để xem\".")
                    Bullet("Có thể xóa từng Passkey hoặc xóa toàn bộ. Thao tác không hoàn tác được.")
                    Jump("Mở Passkeys", .passkeys)
                }

                GuideSection("9. Firmware – cập nhật, sao lưu, cứu hộ", icon: "cpu") {
                    Bullet("Không cần cài thêm công cụ: app tự nói chuyện với bootloader ESP32-S3 (giống esptool-js trên trang web).")
                    Bullet("\"Kiểm tra chip (chỉ đọc)\": đưa thiết bị vào bootloader, đọc MAC và trạng thái bảo mật (mã hóa flash, Secure Boot) rồi khởi động lại – không ghi gì.")
                    Bullet("Nguồn 1 – Web MrOld: tải đúng gói theo MAC chip (số serial TT-<MAC>), kiểm tra SHA-256. Khi web sập, app dùng bản đã lưu trên máy.")
                    Bullet("Nguồn 2 – File trên máy: chọn file .bin. App từ chối gói của chip khác hoặc gói không mã hóa cho chip đã mã hóa.")
                    Bullet("App tự sao lưu manifest và gói riêng của thiết bị vào ~/Library/Application Support/TinyTouchManager/firmware mỗi lần kết nối.")
                    Bullet("Cứu hộ: nếu tinyTouch không chạy, giữ nút BOOT khi cắm USB để vào chế độ nạp, rồi bấm \"Cứu hộ: nạp lại gói đã lưu\".")
                    Note("Không rút cáp USB khi đang nạp. Thiết bị MrOld bật mã hóa flash – chỉ nạp gói dành cho đúng chip của bạn. Không nạp firmware của repo zimengxiong/tinytouch.")
                    Jump("Mở Firmware", .firmware)
                }

                GuideSection("10. Lệnh Terminal (tinytouch)", icon: "terminal") {
                    Text("Cài lệnh một lần:").font(.callout)
                    Code("sudo ln -sf \"/Applications/TinyTouch Manager.app/Contents/Resources/bin/tinytouch\" /usr/local/bin/tinytouch")
                    Code("""
                    tinytouch status                  # chế độ, vân tay, cảm biến, firmware
                    tinytouch mode hid | piv          # chuyển chế độ
                    tinytouch set-password <1-5>      # mật khẩu trên chip cho ngón
                    tinytouch clear-password <1-5>
                    tinytouch post-key enter,space    # phím sau khi điền
                    tinytouch post-key-delay <ms>
                    tinytouch wake-delay <ms>
                    tinytouch enroll <1-5> [2|6]
                    tinytouch passkeys | hosts | ports
                    tinytouch raw STATUS              # lệnh thô
                    """)
                    Note("Khi app đang chạy, lệnh đi qua app nên không tranh cổng serial.")
                }

                GuideSection("11. Khắc phục sự cố", icon: "wrench.and.screwdriver") {
                    Bullet("\"Cổng đang được ứng dụng khác sử dụng\": thoát app khác đang mở tinyTouch (app cũ, trang web Chrome, Arduino…), rồi bấm Thử kết nối lại.")
                    Bullet("Chạm mà không gõ: xem mục Nhật ký – dòng \"Bỏ qua lần chạm\" cho biết lý do (chưa ghép đôi, chưa lưu mật khẩu Mac, không ở ô mật khẩu…).")
                    Bullet("Sau khi cập nhật app: macOS có thể hỏi quyền Keychain → chọn \"Luôn cho phép\"; và có thể phải tắt/bật lại TinyTouch Manager trong Trợ năng.")
                    Bullet("Ký tự đầu bị mất khi vừa mở máy: tăng \"Chờ khi đánh thức\".")
                    Bullet("Bàn phím không phải US/ABC: thiết bị gõ theo bố cục US – hãy dùng bố cục ABC ở màn hình khóa.")
                    Bullet("Nhật ký đầy đủ lưu tại ~/Library/Logs/TinyTouchManager.log (không chứa mật khẩu).")
                    HStack {
                        Button("Mở file nhật ký") { NSWorkspace.shared.open(FileLog.url) }
                        Button("Mở cài đặt Trợ năng") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }

                GuideSection("12. Khôi phục cài đặt gốc", icon: "exclamationmark.triangle") {
                    Bullet("Mục Nâng cao → gõ RESET → chạm vân tay. Xóa toàn bộ vân tay, mật khẩu trên chip, máy đã ghép và Passkeys.")
                    Bullet("Sau đó: đăng ký lại vân tay, ghép đôi lại các Mac, đặt lại mật khẩu.")
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

// MARK: - Building blocks

private struct GuideSection<Content: View>: View {
    let title: String
    let icon: String
    @State private var expanded: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, icon: String, expanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        _expanded = State(initialValue: expanded)
        self.content = content
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: icon).font(.headline)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct Steps: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1).").font(.body.monospacedDigit().weight(.semibold)).frame(width: 22, alignment: .trailing)
                Text(item).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Code: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct Jump: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let section: AppSection
    init(_ title: String, _ section: AppSection) {
        self.title = title
        self.section = section
    }

    var body: some View {
        Button(title) { model.selection = section }.buttonStyle(.link)
    }
}
