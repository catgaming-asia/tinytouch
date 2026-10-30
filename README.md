# TinyTouch Manager

Ứng dụng macOS (Swift/SwiftUI, chạy trên menu bar) để quản lý khóa vân tay **tinyTouch của MrOld**.
App gộp hai phần:

- toàn bộ tính năng của trang web controller (`touch.mrold.xyz/controller`), để không phụ thuộc vào web;
- các tính năng chạy nền của `tinyTouch.app` gốc: mở khóa màn hình, chế độ bảo vệ, đèn LED nhắc nhở, sudo, khởi động cùng macOS.

Kèm theo là lệnh `tinytouch` dùng trong Terminal, có cùng các lệnh như tờ hướng dẫn của MrOld.

## Tính năng

| Mục | Chức năng |
| --- | --- |
| Tổng quan | Chế độ, số vân tay, cảm biến, firmware, serial, Passkeys |
| Vân tay & Mật khẩu | Đăng ký 5 ngón (6 lần chạm đa góc hoặc 2 lần chạm nhanh), gán/xóa mật khẩu trên chip cho từng ngón |
| Chế độ hoạt động | Chuyển HID ↔ PIV |
| Phím sau khi điền | Mẫu có sẵn (Enter, Enter→Space, Tab→Enter, Enter×2, Không bấm), tự ghép tối đa 3 phím, thời gian chờ giữa các phím, thời gian chờ khi đánh thức máy |
| Passkeys FIDO2 | Xem (cần chạm vân tay), xóa từng Passkey, xóa toàn bộ |
| Ghép đôi Mac | Tạo khóa ghép đôi và gửi cho thiết bị, liệt kê và gỡ các máy đã ghép (tối đa 8) |
| Tự động mở khóa | Mở khóa màn hình, chỉ nhập tại ô mật khẩu, sudo trong Terminal, đèn LED nhắc nhở (tự tắt sau 1/2/5/10 phút), khởi động cùng macOS, mật khẩu Mac lưu trong Keychain (mặc định và theo từng ngón) |
| Firmware | So phiên bản; cập nhật từ **web MrOld** hoặc **file .bin trên máy**; chế độ **cứu hộ** khi thiết bị đang ở chế độ nạp; tự sao lưu gói firmware của thiết bị để dùng khi không có mạng |
| Nhật ký | Nhật ký hoạt động, xem lệnh gửi/nhận (TX/RX), gửi lệnh thô |
| Nâng cao | Khôi phục cài đặt gốc (phải gõ `RESET` để xác nhận) |
| Hướng dẫn | Hướng dẫn đầy đủ ngay trong app: bắt đầu nhanh, từng tính năng, lệnh CLI, firmware, khắc phục sự cố |

Nhật ký hoạt động được ghi ra `~/Library/Logs/TinyTouchManager.log`, không chứa mật khẩu hay khóa.

Mọi thay đổi cấu hình đều làm như trang web: `CONFIG_UNLOCK` (chạm vân tay chủ sở hữu) → lệnh → `CONFIG_LOCK`.

## Cài đặt

Cần macOS 13 trở lên và Xcode (hoặc Command Line Tools) có Swift 5.10 trở lên.

```bash
scripts/build-app.sh --install
```

Script này build `dist/TinyTouch Manager.app` và `dist/tinytouch`, chép app vào `/Applications`, đồng thời chép `firmware-backup/` vào bộ nhớ đệm offline của app.

Nên ký app bằng chứng chỉ Apple Development của bạn. Khi đó quyền Trợ năng và Keychain được giữ lại sau mỗi lần cập nhật app; nếu ký ad-hoc, macOS sẽ hỏi lại quyền sau mỗi lần build:

```bash
security find-identity -v -p codesigning
TINYTOUCH_SIGN_IDENTITY="Apple Development: Tên (TEAMID)" scripts/build-app.sh --install
```

Sau khi cài:

1. Mở **TinyTouch Manager**. Biểu tượng vân tay sẽ hiện trên menu bar.
2. Cấp quyền **Trợ năng** (menu → "Cấp quyền Trợ năng…"). App cần quyền này để biết con trỏ có đang ở ô mật khẩu không.
3. Vào **Ghép đôi Mac** → "Tạo mã & ghép đôi tự động", rồi chạm vân tay.
4. Vào **Tự động mở khóa** → đặt mật khẩu Mac (mật khẩu mặc định hoặc theo từng ngón).
5. Bật **Khởi động cùng macOS**.

Lệnh CLI:

```bash
sudo ln -sf "/Applications/TinyTouch Manager.app/Contents/Resources/bin/tinytouch" /usr/local/bin/tinytouch
```

```
tinytouch status
tinytouch mode hid|piv
tinytouch set-password <1-5>
tinytouch clear-password <1-5>
tinytouch post-key enter,space
tinytouch post-key-delay <ms>
tinytouch wake-delay <ms>
tinytouch enroll <1-5> [2|6]
tinytouch passkeys
tinytouch hosts
tinytouch raw STATUS
```

Khi app đang chạy, CLI gửi lệnh qua app (socket `~/Library/Application Support/TinyTouchManager/control.sock`), nên hai bên không tranh cổng serial. Khi app không chạy, CLI tự mở cổng serial.

## Cập nhật firmware

Mục **Firmware** có hai nguồn:

1. **Web MrOld**: tải manifest và gói firmware. Manifest lấy từ `touch.mrold.xyz/controller/firmware/manifest.json`. Gói riêng của thiết bị được chọn theo MAC chip; số serial USB `TT-<MAC>` chính là MAC này. Nếu web không truy cập được, app dùng bản đã lưu.
2. **File trên máy**: chọn một file `.bin`. App kiểm tra SHA-256 với manifest, và từ chối nạp nếu là gói của chip khác hoặc là gói không mã hóa cho chip đã bật mã hóa.

Các bước nạp giống trang web: chạm vân tay → `BOOTLOADER` → `esptool read_mac` → kiểm tra mã hóa flash → `esptool write_flash 0x10000`. Cần cài `esptool` trước:

```bash
brew install esptool
```

Thư mục `firmware-backup/` chứa manifest đã rút gọn và gói đã mã hóa của thiết bị `TT-90DA72470794`. Manifest đầy đủ (có thông tin thiết bị của khách khác) và gói chung không mã hóa chỉ giữ trên máy, không đưa vào git.

Nạp tay khi không có app:

```bash
esptool --chip esp32s3 --port /dev/cu.usbmodemXXXX write_flash 0x10000 firmware-backup/1.1.7/updates/90DA72470794.bin
```

## Giao thức

Firmware MrOld (`mroldtouch`, protocol 2) là bản fork của [zimengxiong/tinytouch](https://github.com/zimengxiong/tinytouch) từ trước commit `84afa9e` ("replace restart console with protocol six").

- **Lệnh dùng chung với repo gốc:** `STATUS`, `PING`, `CONFIG_UNLOCK`, `MODE`, `ENROLL`, `HID_KEY_ADD/REMOVE/IDS`, `FACTORY_RESET`, `BOOTLOADER`.
- **Lệnh MrOld thêm:** `GET_SLOT_STATUS`, `SET_SLOT_PASSWORD`, `CLEAR_SLOT_PASSWORD`, `POST_KEY`, `POST_KEY_DELAY`, `WAKE_DELAY`, `PASSKEY_LIST/DELETE/CLEAR`, `LED_PROMPT 0|1`, `CONFIG_LOCK`.
- **Mở khóa qua ghép đôi:**
  - Khi vân tay khớp, thiết bị gửi `EV2 <nonce> <counter> <slot> <score> <keyId>:<mac>…`, với `mac = HMAC-SHA256(key, "EV2|keyId|nonce|counter|slot|score")`.
  - App kiểm tra chữ ký, chặn sự kiện bị phát lại (replay), xét ngữ cảnh (màn hình khóa, ô mật khẩu, sudo), rồi trả `PW2 <keyId> <nonce> <iv> <ct> <mac>`.
  - Mật khẩu được mã hóa AES-256-CTR với khóa `HMAC(key, "SESSION|nonce")`. Thiết bị giải mã rồi tự gõ.

Repo gốc bản hiện tại (0.1.35, protocol 6) đã đổi giao thức, nên app/CLI của repo gốc **không** dùng được với firmware MrOld.

## Phát triển

```bash
swift build
swift test
```

- `Sources/TinyTouchCore`: serial, tìm thiết bị (IOKit), giao thức, mã hóa ghép đôi, Keychain, socket cho CLI.
- `Sources/TinyTouchManager`: app SwiftUI (cửa sổ quản lý và menu bar).
- `Sources/tinytouch`: CLI.
