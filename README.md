# TachiBooks

Ứng dụng **iOS cho iPhone/iPad**, kết hợp thư viện manga và sách chữ. Đầu ra sản phẩm là IPA. Flutter/Dart được dùng để xây UI và logic; web chỉ phục vụ kiểm tra giao diện trên Windows.

`PROJECT_STATE.md` là nguồn trạng thái duy nhất. IPA Tachimanga/vBook người dùng cung cấp được giữ nguyên và dùng để khảo sát định dạng, không được ghép thành binary mới.

## Build IPA

Trên macOS có Xcode và CocoaPods, dùng Flutter 3.47.4 đúng commit đã pin trong script:

```bash
bash tools/build_ios.sh 1
```

Script chạy analyze, tests, compile bản release iOS arm64 rồi đóng gói `build/ios/ipa/TachiBooks-unsigned.ipa`. Đây là IPA **chưa ký**; cần ký và provisioning phù hợp trước khi cài lên iPhone/iPad. Script từ chối chạy trên Windows/Linux, không tạo file IPA giả.

Workflow `.github/workflows/ios-build.yml` cho GitHub Actions macOS tự chạy khi push lên main và có thể chạy thủ công qua Actions → iOS unsigned IPA → Run workflow. Artifact đi kèm SHA-256 và build information. Workflow chưa chạy trong môi trường Windows này.

Để build có chữ ký trên Mac, mở `ios/Runner.xcworkspace`, cấu hình Team/Bundle ID phù hợp trong Xcode rồi dùng `flutter build ipa --release` và chọn export method/provisioning tương ứng. Không có certificate hoặc tài khoản ký được lưu trong source.

## Sử dụng thư viện và reader

- Thư viện có tìm kiếm, lọc loại sách, yêu thích, bộ sưu tập và trạng thái hoàn thành.
- Nút thêm nhập EPUB không DRM, TXT UTF-8 và CBZ/ZIP ảnh. Nội dung lưu vào thư viện riêng trong app.
- Reader manga cuộn dọc hoặc lật trang; reader chữ có font serif/sans được đóng gói, cỡ chữ, khoảng cách dòng, nền sáng/giấy/tối, dấu trang, danh sách chương và đọc bằng giọng nói của hệ thống.
- Tab Cập nhật lấy chương từ nguồn đã kết nối; Lịch sử mở vị trí đọc gần nhất. Xóa lịch sử giữ tiến độ và nội dung đã tải.
- Tab Thêm có thiết lập reader, sách/chương đã tải, mục tiêu đọc, nhập file và xuất/khôi phục backup. Khôi phục kiểm tra toàn bộ file trước khi ghi và giữ sách đã có.

Native metadata dùng Isar Community; ảnh/nội dung lớn nằm trong attachment store riêng. Import có giới hạn kích thước và kiểm tra archive paths. Backup đóng gói nội dung đã tải để dùng offline. Không hỗ trợ EPUB có DRM hoặc sách được bảo vệ từ Apple Books Store.

## Hai hệ extension

SourceRepository dùng hai adapter độc lập: Suwayomi cho APK Tachimanga/Tachiyomi, Node runtime cho ZIP JavaScript vBook. Hướng dẫn chạy ở `runtime/README-Suwayomi.md` và `runtime/README.md`.

Trong app mở Duyệt → Kết nối nguồn, nhập URL của runtime. Trên iPhone phải dùng địa chỉ PC/server mà điện thoại truy cập được; `127.0.0.1` của iPhone là chính điện thoại. Có thể cấu hình từng hệ riêng. Sau đó cài repository hoặc gói extension gốc, mở nguồn, tìm truyện, thêm vào thư viện và tải chương.

Các extension **hiện chưa được thực thi trực tiếp trên iOS**. Đây là giới hạn kiến trúc của bản source hiện tại, dù search/detail/chapter đã được kiểm tra với một số gói gốc trên companion. Không công bố tương thích toàn bộ extension. Runtime vBook plaintext có thể báo capability không hỗ trợ đối với browser, mã hóa hoặc API native chưa được triển khai; không bỏ qua lỗi để hiện danh sách giả. UI hiện chưa cung cấp bearer-token authentication cho companion.

## Kiểm tra source trên Windows

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

Bundle có target iOS cũng cần xcrun cho native asset hooks của các dependency; lệnh này đã dừng trên Windows vì không có xcrun. Các test chạy host/widget không thay thế kiểm tra import qua Files, native Isar, TTS, local network permissions hoặc reader trên iPhone/iPad.

Có thể chạy `flutter run -d web-server` để xem UI. Web preview dùng storage riêng giới hạn 4 MB; dữ liệu preview không là thư viện iOS.

## Tư liệu và giấy phép

`tools/inspect_ipa.py` khảo sát ZIP/Mach-O và nested resources theo cách có thể tái chạy. `tools/inspect_vbook.py` kiểm tra cấu trúc extension/registry, không thực thi scripts. Báo cáo khảo sát hai IPA nằm trong `artifacts/`.

Fonts Noto Sans và Noto Serif được lấy từ Google Fonts, kèm giấy phép OFL tại `assets/fonts/`. Icon iOS là đồ họa sách do dự án tự tạo. Source không chứa các thư viện mod của IPA đầu vào hoặc core.js/crypto.js độc quyền từ vBook.

Tài liệu build chính thức: https://docs.flutter.dev/deployment/ios
