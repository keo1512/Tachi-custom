# TachiBooks

Ứng dụng **iOS cho iPhone/iPad**, kết hợp thư viện manga và sách chữ. Đầu ra sản phẩm là IPA. Flutter/Dart được dùng để xây UI và logic của app iOS. Toàn bộ giao diện lấy Tachimanga 5.0 trong IPA đã gửi làm chuẩn; tính năng sách chữ/vBook/EPUB phải dùng cùng phong cách này.

`PROJECT_STATE.md` là nguồn trạng thái duy nhất. IPA Tachimanga/vBook người dùng cung cấp được giữ nguyên và dùng để khảo sát định dạng, không được ghép thành binary mới.

## Build IPA

Trên macOS có Xcode và CocoaPods, dùng Flutter 3.47.4 đúng commit đã pin trong script:

```bash
python3 tools/configure_firebase_ios.py --config /path/to/GoogleService-Info.plist
bash tools/build_ios.sh 7
```

Script chạy analyze, tests, compile bản release iOS arm64 rồi đóng gói `build/ios/ipa/TachiBooks-unsigned.ipa`. Đây là IPA **chưa ký**; cần ký và provisioning phù hợp trước khi cài lên iPhone/iPad. Script từ chối chạy trên Windows/Linux, không tạo file IPA giả.

Workflow `.github/workflows/ios-build.yml` chỉ chạy thủ công qua Actions → iOS unsigned IPA → Run workflow; push source không tự mở lượt build. Pipeline dùng runner `xcode-27`, luôn chạy analyze/tests và compile release. Bật input `native_smoke` khi sửa UIKit/navigation để chạy hosted XCTest trên iPhone simulator iOS27; mặc định tắt để tiết kiệm hạn mức. Script kiểm tra SDK và runtime thực tế đúng iOS27. Artifact IPA đi kèm SHA-256 và build information; khi bật simulator, kết quả và ảnh chụp thật được lưu riêng để kiểm tra. IPA vẫn cần ký và kiểm tra trên thiết bị.

CI cần secret `TACHI_GOOGLE_SERVICE_INFO_PLIST_BASE64` chứa base64 file Firebase iOS đúng bundle `dev.tachibooks.tachiBooks`, project `tachibooks` và đã bật Google Authentication. Helper kiểm tra client/callback và Runner resources trước compile; thiếu hoặc sai cấu hình thì dừng sớm. Không commit `ios/Runner/GoogleService-Info.plist`. Build kiểm tra cấu hình Google/Firebase thực sự có trong Runner.app trước đóng gói.

Chính sách của dự án là chỉ dùng hạn mức miễn phí GitHub Actions. Trước khi chạy workflow, kiểm tra quota còn lại và ngân sách Actions `$0` có bật `Stop usage`. Không tăng ngân sách hoặc tự chạy lại khi hết quota. Timeout giới hạn lượt chạy, không thay thế cơ chế chặn phí của GitHub.

Để build có chữ ký trên Mac, mở `ios/Runner.xcworkspace`, cấu hình Team/Bundle ID phù hợp trong Xcode rồi dùng `flutter build ipa --release` và chọn export method/provisioning tương ứng. Không có certificate hoặc tài khoản ký được lưu trong source.

## Sử dụng thư viện và reader

- Thư viện có tìm kiếm, lọc loại sách, yêu thích, bộ sưu tập và trạng thái hoàn thành.
- Tìm nâng cao theo tên/tác giả/họa sĩ/thể loại/ghi chú, cụm từ trong dấu nháy, `&&`, `||`, dấu `-` và ngoặc. Ví dụ `author:"Nguyễn Nhật Ánh" && unread:>0`. Hướng dẫn field hiện hỗ trợ nằm trong menu Thư viện; chưa có trường lịch phát hành khi chưa có dữ liệu.
- Nhấn giữ bìa hoặc dùng menu Chọn nhiều sách để gán chung kệ, tác giả hoặc bộ truyện. Menu Nhóm theo kệ/Tự nhóm theo tác giả/Tự nhóm theo bộ truyện lưu cách xem, không thay kệ thủ công hoặc đoán metadata từ tiêu đề. EPUB có metadata bộ truyện rõ ràng được nhận khi nhập.
- Thư viện → menu ba chấm → Nhập EPUB, TXT, CBZ nhập EPUB không DRM, TXT UTF-8 và CBZ/ZIP ảnh. Nội dung lưu vào thư viện riêng trong app.
- Sáu tab Thư viện / Cập nhật / Duyệt / Tải xuống / Lịch sử / Thêm dùng `UITabBar` của UIKit, cùng Flutter engine hiện tại. UIKit vẽ material theo phiên bản iOS; app không vẽ capsule đen để mô phỏng thanh tab. Thanh tab ẩn khi mở trang con và cấp vùng an toàn thực tế cho Flutter. Sáu ảnh người dùng gửi là chuẩn bố cục màn chính: nền nội dung tối, màu nhấn xanh tím nhạt, thư viện mặc định5cột và các dòng cài đặt phẳng. Chưa có reference đầy đủ chi tiết/reader/mọi màn con để xác nhận khớp từng pixel.
- Reader manga cuộn dọc hoặc lật trang; reader chữ có font serif/sans được đóng gói, cỡ chữ, khoảng cách dòng, nền sáng/giấy/tối, dấu trang, danh sách chương và đọc bằng giọng nói của hệ thống.
- Tab Cập nhật lấy chương từ nguồn đã kết nối; Lịch sử mở vị trí đọc gần nhất. Xóa lịch sử giữ tiến độ và nội dung đã tải.
- Cập nhật lọc theo kệ và cờ đọc từng chương. Trong chi tiết, nhấn giữ chương để đánh dấu đọc/chưa đọc; lọc/sắp xếp không đổi ID được chọn. Ghi chú cá nhân sửa/xóa được; artist/genres được giữ khi nguồn hoặc backup Mihon cung cấp.
- Biểu tượng kính trong Lịch sử bật/tắt chế độ ẩn danh. Phiên reader mở mới khi bật không ghi tiến độ, lịch sử hoặc thời gian đọc; chế độ cố định suốt phiên. Lịch sử cũ vẫn hiển thị, nội dung đã tải giữ nguyên và dấu trang chủ động vẫn được lưu.
- Tab Tải xuống có hàng đợi lưu bền, tạm dừng/tiếp tục, thử lại khi lỗi và thiết lập1–4chương tải đồng thời (mặc định2). Tạm dừng ngăn bắt đầu chương mới; chương đang tải được hoàn tất. Nút tải trong Cập nhật và chi tiết dùng chung hàng đợi.
- Tải hàng loạt: nhấn giữ bìa/Chọn nhiều sách → chọn truyện hoặc Chọn tất cả sách hiển thị → Tải truyện đã chọn. Chọn Tất cả chương chưa tải hoặc Chương chưa đọc chưa tải. Sách nhập local/chương đã tải được bỏ qua, chương đã nằm trong queue không thêm trùng. Batch lưu bền một lượt rồi chạy bằng concurrency/pause/retry chung; số thông báo là số chương mới thêm vào queue, không phải số chương đã tải xong.
- Tải tự thử tối đa3lần lỗi rồi giữ tác vụ để thử lại thủ công. Trang ảnh đã tải đầy đủ được giữ khi trang sau lỗi; lượt sau chỉ tải phần còn lại, chưa có HTTP Range cho byte stream ảnh đang dở. Manga chỉ được đánh dấu đọc khi đến trang cuối đã giải mã thành công và không có lỗi ảnh đã biết.
- Tab Thêm mở các thiết lập giao diện/thư viện/reader/tải xuống, mục tiêu đọc và tài khoản Google. Sao lưu & Khôi phục nằm trong Đồng bộ và dùng được khi chưa đăng nhập. Premium/tracker hiển thị đúng khả năng hiện có; không dùng thông tin tài khoản trong ảnh hoặc giả trạng thái đã đăng ký.

Native metadata dùng Isar Community; ảnh/nội dung lớn nằm trong attachment store riêng. Import có giới hạn kích thước và kiểm tra archive paths. Backup đóng gói nội dung đã tải để dùng offline. Không hỗ trợ EPUB có DRM hoặc sách được bảo vệ từ Apple Books Store.

Thêm nguồn/nhập tài liệu ghi metadata và nội dung nguyên tử, giữ sách đã có. Request/reader/popup từ trước restore bị từ chối khi revision đổi. Ảnh offline được ghi tạm/flush/rename và kiểm tra SHA-256 trước đọc/reuse; file hỏng báo lỗi thay vì đưa vào backup.

## Sao lưu và đồng bộ Google

Thêm → Đồng bộ → Sao lưu & Khôi phục xuất TachiBooks JSON v1 với toàn bộ nội dung đã nhập/tải, gồm EPUB/TXT/CBZ và ảnh. Khôi phục có xem trước, kiểm tra file và từ chối preview cũ nếu thư viện đã đổi. Merge thêm sách mới, giữ metadata/cache của sách đã có và lưu bản phục hồi đầy đủ trước khi thay dữ liệu. Có thể xuất bản phục hồi trước đó để khôi phục lại thư viện cũ.

Nhập Tachimanga `.tmb` hiện xác minh build511/type0; Mihon/Tachiyomi dùng protobuf gzip. Các file này chỉ nhập dữ liệu thực sự có trong backup: metadata thư viện, cờ đọc chương, dấu trang và vị trí đọc. Không tạo nội dung offline hoặc cài extension từ metadata. Nhiều category hiện chọn category đầu theo thứ tự và báo trong preview. Chưa có mẫu vBook backup để xác minh định dạng; format chưa biết được từ chối trước khi ghi. Giới hạn file128MiB, tương thích envelope TachiBooks v1 hiện có.

Firebase dùng project riêng `tachibooks`, Google Authentication và Firestore Standard `(default)` trên gói Spark. Sau khi tạo database, đưa `firestore.tachibooks.rules` vào Rules và Publish. Quy tắc chỉ cho tài khoản chủ sở hữu truy cập đường dẫn `tachiBooksUsers/{uid}`; helper/configuration và test emulator không thay cho kiểm tra đăng nhập/sync thật trên iPhone.

Đăng nhập ở Thêm → Tài khoản; đăng nhập không tự bật đồng bộ. Khi bật ở Đồng bộ, app đồng bộ snapshot đầy đủ (tối đa128MiB), kiểm tra hash/CAS và yêu cầu lựa chọn nếu hai phía thay đổi. Lựa chọn dùng cloud lưu recovery trước thay thư viện; giữ bản trên máy cũng kiểm tra quyết định chưa cũ. Giữ3bản cloud gần nhất. Không cắt nội dung để tải lên một snapshot thiếu.

Tự đồng bộ hoạt động khi app ở phía trước, chờ6giây sau thay đổi và cách nhau tối thiểu1phút, không polling khi thư viện đứng yên. Quota Firebase miễn phí áp dụng toàn project; vượt quota báo lỗi và giữ thư viện local. Upload dở có thể để lại dữ liệu cloud chưa thuộc3bản giữ lại. Thiết lập app, hàng đợi tải và link kho extension vẫn thuộc từng thiết bị, chưa nằm trong snapshot sách.

## Hai hệ extension

SourceRepository dùng hai adapter độc lập: Suwayomi cho APK Tachimanga/Tachiyomi, Node runtime cho ZIP JavaScript vBook. Hướng dẫn chạy ở `runtime/README-Suwayomi.md` và `runtime/README.md`.

Trong app mở Duyệt → Phần mở rộng → Thêm kho extension bằng link. Nhập link Keiyoushi hoặc JSON/plugin.json của tác giả vBook để hiển thị danh sách trực tiếp; chưa cần runtime để đọc catalogue. Link Keiyoushi được chuẩn hóa sang gzip protobuf `index.pb`; trang vbookext.me là danh bạ để lấy link kho tác giả. Chọn Cài/Cập nhật sẽ gửi gói đến engine và chỉ hiện Đã cài khi engine xác nhận.

Để cài/chạy nguồn của bản hiện tại, mở Thêm → Chung → Kết nối nguồn và nhập URL runtime. Trên iPhone phải dùng địa chỉ PC/server mà điện thoại truy cập được; `127.0.0.1` của iPhone là chính điện thoại. Có thể cấu hình từng hệ riêng. Sau khi engine xác nhận cài gói, mở nguồn, tìm truyện, thêm vào thư viện và tải chương.

Duyệt hiển thị icon thật khi runtime trả `iconUrl` HTTP/HTTPS hợp lệ, gồm URL tương đối của Suwayomi; khi không có icon hoặc tải lỗi, dùng placeholder. Companion vBook hiện chưa trả icon URL.

Các extension **hiện chưa được thực thi trực tiếp trên iOS**. Đây là giới hạn kiến trúc của bản source hiện tại, dù search/detail/chapter đã được kiểm tra với một số gói gốc trên companion. Không công bố tương thích toàn bộ extension. Runtime vBook plaintext có thể báo capability không hỗ trợ đối với browser, mã hóa hoặc API native chưa được triển khai; không bỏ qua lỗi để hiện danh sách giả. UI hiện chưa cung cấp bearer-token authentication cho companion.

Truyện khôi phục giữ URL nguồn/chương và source ID chính xác; Suwayomi phân giải ID/index runtime bằng URL. Truyện mới dùng URL chương ổn định và sắp theo thứ tự đọc cũ đến mới; vBook giữ thứ tự extension trả. Dữ liệu cũ dùng ordinal chapterID được giữ; cập nhật từ chối remap sang URL chưa xác minh, đọc online chỉ nhận mục lục còn khớp ordinal và tên gốc duy nhất.

## Kiểm tra source trên Windows

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

Bundle có target iOS cũng cần xcrun cho native asset hooks của các dependency; lệnh này đã dừng trên Windows vì không có xcrun. Các test chạy host/widget không thay thế kiểm tra import qua Files, native Isar, TTS, local network permissions hoặc reader trên iPhone/iPad.

## Tư liệu và giấy phép

`tools/inspect_ipa.py` khảo sát ZIP/Mach-O và nested resources theo cách có thể tái chạy. `tools/inspect_vbook.py` kiểm tra cấu trúc extension/registry, không thực thi scripts. Báo cáo khảo sát hai IPA nằm trong `artifacts/`.

Fonts Noto Sans và Noto Serif được lấy từ Google Fonts, kèm giấy phép OFL tại `assets/fonts/`. Icon iOS là đồ họa sách do dự án tự tạo. Source không chứa các thư viện mod của IPA đầu vào hoặc core.js/crypto.js độc quyền từ vBook.

[Mihon v0.20.4](https://github.com/mihonapp/mihon/tree/v0.20.4) và [changelog chính thức](https://mihon.app/changelogs/) là tư liệu đối chiếu hành vi/schema, dưới giấy phép Apache-2.0. Không ghép APK thành IPA hoặc dùng giao diện Android làm target. Những phần đã kiểm chứng và nhóm chức năng còn thiếu được ghi trong `PROJECT_STATE.md`; chưa công bố tương đương toàn bộ Mihon.

Tài liệu build chính thức: https://docs.flutter.dev/deployment/ios
