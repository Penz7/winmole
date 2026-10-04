# WinMole

Dọn dẹp và tối ưu Windows ngay trong terminal, dạng portable. Lấy cảm hứng từ [tw93/mole](https://github.com/tw93/mole) (macOS).

- **Portable:** chỉ gồm `mo.cmd` và `winmole.ps1` (~85 KB). Không cần cài đặt, không phụ thuộc gì ngoài PowerShell 5.1 có sẵn trên Windows 10/11.
- **Nhanh:** phần quét và xóa viết bằng C#, được biên dịch một lần vào `lib\` ở lần chạy đầu (~1 giây), các lần sau nạp sẵn.
- **An toàn:**
  - Mọi lệnh phá hủy đều có `--dry-run` để xem trước.
  - Junction và symlink chỉ bị gỡ liên kết, không bao giờ xóa dữ liệu đích.
  - Có danh sách thư mục hệ thống được bảo vệ.
  - Cache của ứng dụng đang chạy sẽ bị khóa, không dọn.
  - File cài đặt và file xóa từ `analyze` được chuyển vào Thùng rác.

## Cài đặt

Mở PowerShell và chạy:

```powershell
irm https://raw.githubusercontent.com/Penz7/winmole/main/install.ps1 | iex
```

Lệnh này tải WinMole vào `%LOCALAPPDATA%\Programs\WinMole` và thêm thư mục đó vào PATH của user (không cần quyền Admin). Sau đó **mở terminal mới** và gõ `mo`.

- **Cập nhật:** chạy lại lệnh trên.
- **Gỡ:** `mo remove`.
- **Dạng portable (không cài):** tải repo về, chép đi đâu cũng được, chạy `mo.cmd`. Muốn cài từ bản đã tải thì chạy `mo.cmd install`.

## Dùng


```
mo.cmd                 menu tương tác (hoặc double-click mo.cmd)
mo.cmd clean           dọn cache, temp, log, crash dump, thùng rác, cache trình duyệt/dev/GPU, bản app cũ
mo.cmd uninstall       gỡ app + dọn thư mục, registry, mục khởi động còn sót
mo.cmd optimize        xóa cache DNS, làm mới icon, TRIM SSD, dọn WinSxS, nén ổ WSL/Docker
mo.cmd startup         bật/tắt app khởi động cùng Windows (giống Task Manager, bật lại được)
mo.cmd analyze [path]  duyệt dung lượng ổ đĩa
mo.cmd status          bảng theo dõi CPU/RAM/GPU/ổ đĩa/mạng/pin/tiến trình
mo.cmd purge [path]    dọn node_modules, build, dist, target, .dart_tool, .venv... trong dự án
mo.cmd installer       tìm file cài đặt .msi/.exe/.iso đã tải để chuyển vào Thùng rác
mo.cmd history         lịch sử dọn dẹp
mo.cmd install         cài để gọi `mo` ở mọi nơi
mo.cmd remove          gỡ khỏi máy
```

Sau khi `install`, chỉ cần gõ `mo`, `mo clean`, `mo status`...

### Tùy chọn hay dùng

| Tùy chọn | Ý nghĩa |
|---|---|
| `--dry-run` | Chỉ xem trước, không thay đổi gì |
| `--admin` | Mở lại với quyền Admin, để mở khóa các mục hệ thống (Windows Temp, Windows Update, TRIM, DISM...) |
| `--yes` | Không hỏi lại, dùng lựa chọn mặc định (hợp cho Task Scheduler) |
| `clean --whitelist` | Chọn nhóm cache cần bảo vệ |
| `clean --debug` | Kèm đường dẫn cụ thể khi `--dry-run` |
| `purge --paths` | Sửa danh sách thư mục dự án cần quét |
| `purge --days 7` | Mặc định bỏ chọn dự án sửa trong N ngày gần đây |
| `status --json` | Xuất số liệu dạng JSON |
| `status --watch --interval 2` | Xuất JSON liên tục theo chu kỳ |
| `analyze --json <path>` | Báo cáo dung lượng dạng JSON |

### Phím tắt trong giao diện

- **Danh sách chọn:** `↑↓` di chuyển · `Space` chọn hoặc bỏ · `A` chọn hoặc bỏ tất cả · `Enter` xác nhận · `Q` hủy
- **analyze:** `Enter`/`→` mở · `←`/`Backspace` lùi · `O` mở trong Explorer · `Del` chuyển vào Thùng rác · `R` quét lại · `Q` thoát

## Thư mục

```
WinMole\
  mo.cmd              lệnh `mo` (gọi winmole.ps1 với -ExecutionPolicy Bypass)
  winmole.ps1         chương trình
  lib\                lõi C# đã biên dịch (tự tạo, xóa đi sẽ tự tạo lại)
  config\             whitelist.txt, purge-paths.txt (tạo khi cần)
  logs\               operations.log, lịch sử thao tác dạng JSON lines
```

**Whitelist** (`config\whitelist.txt`), mỗi dòng một mục:
- `id:<mã>` bảo vệ cả nhóm, ví dụ `id:gradle`
- `opt:<mã>` khóa một tác vụ tối ưu
- Đường dẫn (cho phép `*` và `?`) bảo vệ một thư mục cụ thể

## Ghi công

Ý tưởng và cách tổ chức lệnh lấy cảm hứng từ [Mole](https://github.com/tw93/mole) của [tw93](https://github.com/tw93) (MIT). WinMole là dự án độc lập viết lại cho Windows, không liên kết với dự án gốc.

## License

[MIT](LICENSE)
