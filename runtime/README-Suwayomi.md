# Suwayomi companion cho extension APK

Tài liệu này dành cho chế độ máy chủ Suwayomi tùy chọn, chạy trên máy tính để nạp extension APK của hệ Tachiyomi/Tachimanga. Source iOS hiện tích hợp JVM/AndroidCompat qua `packages/tachi_runtime` và chọn engine trên thiết bị khi URL máy chủ để trống. Chỉ cấu hình Suwayomi khi muốn dùng companion; việc có engine trong source hoặc IPA chưa xác nhận mọi extension chạy được trên iPhone. Nội dung đã tải/import vào thư viện app được đọc offline độc lập với companion.

## Công cụ

Sử dụng [Suwayomi Server v2.4.2366](https://github.com/Suwayomi/Suwayomi-Server/releases/tag/v2.4.2366) và JDK 21 trở lên. Các API trong adapter được đối chiếu với release này. Đối với Suwayomi cũ, thao tác thêm kho có thể không có mutation `addExtensionStore` và sẽ trả lỗi cụ thể.

Trên máy Windows hiện tại, công cụ được đặt ở:

```text
D:\Codex\tools\jdk21\jdk-21.0.12.1+1\bin\java.exe
D:\Codex\tools\suwayomi\Suwayomi-Server-v2.4.2366.jar
```

JDK ZIP chính thức của [Eclipse Temurin](https://adoptium.net/temurin/releases/) có SHA-256 `f9d6e191ab098c0d416e7d588a24420a8621cd2f4720dab2459b8b7b2d2d8b4e`. JAR chính thức của Suwayomi có SHA-256 `af9feb20af9d7ebe9e30769e6c6ebc7fc7ab1c447388d42e0280b1da5fe07bfd`. Đối chiếu checksum release khi tải lại hoặc dùng phiên bản khác.

## Chạy trên Windows

Chạy từ thư mục dự án bằng PowerShell. Dữ liệu riêng nằm trong `runtime-data/suwayomi/data`; không dùng data mặc định của một cài đặt Suwayomi khác. Lệnh dưới chỉ mở listener `127.0.0.1:4567`, không mở browser hoặc system tray.

```powershell
$suwayomiJava = 'D:\Codex\tools\jdk21\jdk-21.0.12.1+1\bin\java.exe'
$suwayomiJar = 'D:\Codex\tools\suwayomi\Suwayomi-Server-v2.4.2366.jar'
$suwayomiWorkingRoot = 'D:\Codex\Tachimanga'
$suwayomiLogs = Join-Path $suwayomiWorkingRoot 'runtime-data\suwayomi'
$suwayomiData = Join-Path $suwayomiLogs 'data'
New-Item -ItemType Directory -Path $suwayomiLogs -Force | Out-Null
$suwayomiArguments = @(
  '-Djava.awt.headless=true',
  "-Dsuwayomi.tachidesk.config.server.rootDir=$suwayomiData",
  '-Dsuwayomi.tachidesk.config.server.ip=127.0.0.1',
  '-Dsuwayomi.tachidesk.config.server.port=4567',
  '-Dsuwayomi.tachidesk.config.server.initialOpenInBrowserEnabled=false',
  '-Dsuwayomi.tachidesk.config.server.systemTrayEnabled=false',
  '-Dsuwayomi.tachidesk.config.server.webUIEnabled=false',
  '-jar',
  $suwayomiJar
)
$suwayomiProcess = Start-Process -FilePath $suwayomiJava `
  -ArgumentList $suwayomiArguments -WindowStyle Hidden `
  -WorkingDirectory (Split-Path $suwayomiJar) `
  -RedirectStandardOutput (Join-Path $suwayomiLogs 'stdout.log') `
  -RedirectStandardError (Join-Path $suwayomiLogs 'stderr.log') `
  -PassThru
$suwayomiProcess.Id
```

Ở lần đầu, server có thể tải thành phần CEF riêng. Theo dõi `stdout.log` và kiểm tra API thay vì giả định rằng process vừa chạy nghĩa là server đã sẵn sàng:

```powershell
Invoke-RestMethod 'http://127.0.0.1:4567/api/v1/settings/about'
Invoke-RestMethod 'http://127.0.0.1:4567/api/v1/source/list'
```

Trong cấu hình nguồn của app, đặt Suwayomi URL là `http://127.0.0.1:4567` khi app/preview chạy trên cùng máy. Trên điện thoại thật, `127.0.0.1` là điện thoại; cần một companion nghe trên địa chỉ LAN và đặt URL bằng IP máy tính. Listener chỉ loopback trong lệnh kiểm chứng trên chưa cung cấp kết nối từ điện thoại.

Dừng đúng process vừa tạo bằng:

```powershell
Stop-Process -Id $suwayomiProcess.Id
```

## Kho và gói extension

App có hai cách cài APK: truyền tên package đã có trong extension list, hoặc truyền URL APK trực tiếp để tải gói và upload multipart `file` vào server. Kho được thêm bằng mutation `addExtensionStore` tại `/api/graphql`; server chịu trách nhiệm tải registry và quản lý extension.

Để upload một APK có sẵn nhằm kiểm chứng engine, dùng:

```powershell
curl.exe --silent --show-error --form 'file=@C:\path\extension.apk' `
  --write-out '\nHTTP_STATUS:%{http_code}\n' `
  'http://127.0.0.1:4567/api/v1/extension/install'
```

Extension Komga cần địa chỉ Komga server và tài khoản để duyệt thư viện. Nguồn có thể được cấu hình trong app bằng API preferences; với Komga, các vị trí là tên hiển thị, Address, Username và Password. `POST /api/v1/source/{sourceId}/preferences` nhận `{ "position": 1, "value": "http://127.0.0.1:25600" }`. Giá trị gửi đến Suwayomi là chuỗi; boolean và tập các chuỗi được runtime chuyển đổi theo loại preference. Sau mỗi lần thay đổi cần lấy lại preferences trước lần lưu tiếp theo vì Suwayomi nạp lại nguồn.

Luồng extension Komga APK gốc `1.4.47` đã được kiểm chứng trên Suwayomi `v2.4.2366` với Komga server thật `1.28.1`, sử dụng CBZ tự tạo gồm hai trang PNG kiểm thử. Search trả một truyện, detail trả tên/tác giả, TOC trả một chương, metadata trả hai trang và API proxy đã trả đủ hai ảnh PNG (4,620 bytes). Đây là bằng chứng chạy extension APK gốc trên companion Windows và server thư viện thật; chưa xác nhận runtime native trên điện thoại.

Fixture được tạo bởi `runtime/tools/setup-komga-fixture.mjs`, không dùng ảnh hoặc chương của nhà xuất bản. Script tạo tài khoản thử với mật khẩu ngẫu nhiên trong `runtime-data/komga/test-account.json`, thư viện và preferences trong data dự án được Git bỏ qua. Chỉ chạy trên Komga riêng phục vụ kiểm thử; server Komga phải chạy trước, nghe ở `127.0.0.1:25600` và dùng `runtime-data/komga` làm config directory. JAR chính thức `komga-1.28.1.jar` có SHA-256 `00d5be6953698de0ad966baab7d62db40971c51c810eb4cd9f11315c36cca2e6`, đã đối chiếu [checksum release](https://github.com/gotson/komga/releases/tag/1.28.1).

Từ thư mục `runtime`, khi các server và APK gốc đã sẵn sàng:

```powershell
node tools/setup-komga-fixture.mjs
$env:TACHI_REAL_TEST = '1'
node --test test/suwayomi-live.test.mjs
Remove-Item Env:TACHI_REAL_TEST
```

`SUWAYOMI_TEST_URL`, `KOMGA_TEST_URL` và `KOMGA_TEST_SOURCE` cho phép thay địa chỉ/source ID. Test live đọc dữ liệu qua APK gốc thực thi trên Suwayomi, không thay extension bằng fixture script. Lần kiểm chứng này chỉ xác nhận Komga và luồng đã kiểm tra.

## Hợp đồng adapter

| Thao tác | API |
| --- | --- |
| Runtime metadata | `GET /api/v1/settings/about` |
| Nguồn đã nạp | `GET /api/v1/source/list` |
| Lấy cấu hình nguồn | `GET /api/v1/source/{sourceId}/preferences` |
| Lưu một cấu hình nguồn | `POST /api/v1/source/{sourceId}/preferences`, JSON `{ "position": 0, "value": "..." }` |
| Tìm kiếm | `POST /api/v1/source/{sourceId}/quick-search?pageNum=1`, JSON `{ "searchTerm": "...", "filter": null }` |
| Chi tiết truyện | `GET /api/v1/manga/{mangaId}?onlineFetch=true` |
| Mục lục | `GET /api/v1/manga/{mangaId}/chapters?onlineFetch=true` |
| Metadata trang của chương | `GET /api/v1/manga/{mangaId}/chapter/{chapterIndex}` |
| Ảnh trang | `GET /api/v1/manga/{mangaId}/chapter/{chapterIndex}/page/{zeroBasedPage}?updateProgress=false` |
| Extension list | `GET /api/v1/extension/list` |
| Cài package đã đăng ký | `GET /api/v1/extension/install/{pkgName}` |
| Upload APK | `POST /api/v1/extension/install`, multipart field `file` |
| Thêm kho | `POST /api/graphql`, mutation `addExtensionStore` |

Source ID 64-bit được giữ bằng chuỗi trong app. Chapter index của Suwayomi và database chapter ID là hai giá trị khác nhau; adapter dùng index để gọi API trang.

## Đích iOS

Sản phẩm người dùng yêu cầu là app iOS/IPA. APK trong tài liệu này là gói extension được Suwayomi thực thi, không phải bản build app Android. Companion Windows không thay thế runtime nhúng trong IPA. Build, ký và kiểm chứng app iOS cần macOS/Xcode và thiết bị theo [hướng dẫn Flutter iOS](https://docs.flutter.dev/platform-integration/ios/setup).
