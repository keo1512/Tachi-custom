# PROJECT_STATE

## Phạm vi được yêu cầu

- Xây dựng app mới có source trong workspace này, toàn bộ giao diện giống Tachimanga 5.0 build511 trong IPA được gửi, tích hợp tính năng, kết hợp truyện chữ và extension vBook cùng thư viện/reader lấy cảm hứng từ Apple Books.
- Sản phẩm chỉ dành cho iOS/iPhone/iPad; đầu ra cần là IPA. Người dùng đã sửa rõ: không build APK Android. Người dùng đã yêu cầu bỏ phần web; không có target web trong sản phẩm hoặc pipeline.
- App phải dùng được cả extension Tachimanga và extension vBook. Đọc manifest hoặc hiển thị danh sách nguồn không được coi là bằng chứng chạy extension.
- Người dùng đã yêu cầu rõ: "ko. Build luôn 1 app mới". Yêu cầu giữ toàn bộ binary IPA đã được thay bằng xây app mới; hai IPA đầu vào là tư liệu khảo sát kỹ thuật.
- Sáu ảnh `D:/LocalSend/IMG_6007.PNG` đến `IMG_6012.PNG` do người dùng gửi là chuẩn UI ưu tiên mới: 6 tab gồm Tải xuống, nền nội dung tối, màu nhấn xanh tím nhạt, thư viện5cột và bố cục sáu màn chính. Người dùng xác nhận thanh tab dùng UIKit của iOS; không mô phỏng bằng capsule/nền đen Flutter. Không sao chép thông tin tài khoản hoặc nội dung truyện trong ảnh vào source/dữ liệu mẫu.

## Trạng thái hiện tại

- Flutter project `tachi_books`, version `1.0.0+4`, target iOS15.0, iPhone/iPad (device family1,2), bundle ID `dev.tachibooks.tachiBooks`. Source mới theo sáu ảnh và tab UIKit đang hoàn thiện; chưa compile native phiên bản này. Native build đã thành công gần nhất là build3 run37734950578 commitd69a6bc trên Xcode16.4 (58 tests pass +1 nativehostoptin skip), artifact11531566743 chưa tải về. Chưa ký hoặc test trên iPhone/iPad thật. Không có target web hoặc APK output.
- Source có 6 tab Thư viện / Cập nhật / Duyệt / Tải xuống / Lịch sử / Thêm; library/filter/collection/favorite/completed; import EPUB không DRM/TXT/CBZ/ZIP; reader manga và chữ; tiến độ/dấu trang/mục tiêu đọc; tải offline; backup export/merge restore; cấu hình/cài extension và tìm truyện qua hai companion. Chưa chứng minh giống hệt mọi màn hình/tính năng app gốc.
- Native library dùng Isar Community và attachment store. Backup kiểm tra toàn bộ envelope trước ghi, giữ sách đã có, rollback sách mới khi lỗi ghi. Cập nhật chương remap cache/progress/bookmarks theo chapter identity. Metadata và xóa lịch sử được serialize theo sách, đọc lại dữ liệu mới nhất trước ghi.
- Màn chính dùng toolbar56px, tiêu đề giữa20px, accent `#AFC4FF`, nội dung tối mặc định, lưới bìa5cột (thiết lập2–8), khoảng cách6px và badge số chương. iOS dùng `UITabBar` UIKit qua MethodChannel với cùng Flutter engine, không vẽ nền capsule bằng Flutter; appearance do iOS quyết định. Footer Cupertino chỉ dùng trên host test không có UIKit. Cập nhật/Lịch sử/Tải xuống/Thêm đã sửa bố cục theo ảnh. Duyệt có3tab Nguồn/Phần mở rộng/Di chuyển, kết hợp nguồn2hệ, pin/recent/ngôn ngữ thật, giữ nguồn hệ còn hoạt động khi hệ kia lỗi. Icon nguồn là placeholder do contract chưa có iconURL. Di chuyển chỉ hỗ trợ tìm lại nguồn khác, chưa chuyển cache/tiến độ/dấu trang tự động. Bộ lọc chương giữ chỉ số chương gốc. Chưa xác nhận khớp từng pixel hoặc appearance native trên thiết bị.
- Hàng đợi tải lưu bền SharedPreferences `downloadQueueV1`, mặc định2 tác vụ đồng thời (thiết lập1–4). Cập nhật và chi tiết dùng chung hàng đợi; chống trùng theo bookID/chapterID, phục hồi tác vụ active thành pending sau restart, giữ lỗi để thử lại. Tạm dừng ngăn bắt đầu tác vụ mới, cho tác vụ đang chạy hoàn tất. Không đổi schema LibraryBook/Isar; dữ liệu hàng đợi sai định dạng được bảo toàn và báo lỗi.
- Kiểm tra source mới toàn bộ: `flutter analyze --no-pub` sạch,79 Flutter tests passed, gồm Isar DLL Windows,6tab/routeobserver/nativebridge mock, tải bền/đồng thời, activity/downloads, partialenginefailure/pin/recent, chapteridentity và bảo toàn metadata/cache/bookmark. More/settings smoke320x568 và430x932 cùng điều hướng trang con đã pass, không overflow. Compile Swift/XCTest còn chờ MacCI. Isar DLL Windows và mock MethodChannel không xác minh storage/UIKit iOS.
- Runtime Node default tests: 10 passed, 5 opt-in skipped. Bộ khảo sát vBook: 18 Python tests passed. Hai báo cáo IPA đã tạo lại tại `artifacts/ipa-inspection.json` và `artifacts/vbook-ipa-inspection.json`.
- Gói vBook gốc Truyện Full v13 (SHA-256 `3005f60b3a320fb698a7247943b3b30977fbade5e7e2ae9cc174e8c8707b5a86`) đã chạy search/detail/TOC/chapter qua companion, live test passed. Các gói MangaDex/Syosetu/Tàng Thư Viện/iSach vẫn có kiểm tra upstream thất bại; không công bố tương thích toàn bộ extension.
- APK Komga gốc 1.4.47 từ Tachimanga IPA đã chạy search/detail/TOC/page metadata và tải 2 ảnh PNG qua Suwayomi 2.4.2366 + Komga 1.28.1 với CBZ tự tạo. Live test passed. Đây là bằng chứng companion trên Windows.
- `tools/build_ios.sh` compile release iOS arm64 và đóng gói IPA unsigned sau analyze/tests. Workflow macOS15 đang dùng Xcode26.2, chạy `tools/test_ios_native_tabs.sh` trước release để kiểm tra UITabBar6mục, callback Dart, cùng engine và vùng an toàn trên iPhone simulator iOS26; lưu xcresult/log/ảnh thật. Cú pháp script và chọn simulator đã kiểm tra trên host; runtime XCTest còn chờ CI. iOS icons riêng và fonts Noto OFL đã được thêm.
- IPA Tachimanga đầu vào: `C:/Users/Nosgnoh/Downloads/Tachimanga iOS Mod IPA No Jailbreak Cheats 5.0 Hacked IPA by iOSGods.com.ipa`, SHA-256 `2bbb80719fc4054dd45d223e9478dab76816017e3cedd2f22234f70c7b2e94c5`.
- Tachimanga `5.0`, build `511`, bundle `com.mangacrush.ios`, minimum iOS 15.0, arm64, 566 ZIP entries. `App.framework/App` là Flutter AOT. Không tìm thấy app source hoặc Xcode project trong archive đã khảo sát.
- `MCHome.bundle/res.zip` có 33,211 entries, gồm 27,686 Java/Kotlin class, JVM resources và Suwayomi/Tachidesk; Main-Class `suwayomi.tachidesk.MainKt`, endpoint `http://127.0.0.1:4567`. 53 Mach-O arm64 có cryptid=0; không là bằng chứng có thể reuse/build/sign.
- IPA vBook: `C:/Users/Nosgnoh/Downloads/vBook.ipa`, SHA-256 `1ca59f4c56e2f8e0a99dff6a23fab7a1b665bc387faa6310352b7f670eeb183c`, version 1.0 build 1, `com.vbook.ios`, minimum iOS 15.1; 442 entries, 4 arm64 Mach-O cryptid=0. Compose/Kotlin native, có core.js/crypto.js đọc được để khảo sát host API; không copy vào app mới.

## Quyết định và invariant còn hiệu lực

- Giữ nguyên hai IPA đầu vào. Khảo sát static không thực thi app iOS hoặc các thư viện mod `Tachimanga.dylib`/`blatantsPatch.dylib`.
- Kiểm chứng app mới được phép nạp extension gốc trong companion riêng, với dữ liệu dự án riêng; bằng chứng này không xác nhận extension chạy trực tiếp trên iPhone.
- App mới dùng Flutter, Clean Architecture theo feature, repository, MVVM/Riverpod và go_router. Native library offline; runtime nguồn nằm sau abstraction. UI mặc định theo platform iOS, lấy Tachimanga làm chuẩn cả màn hình chính và các phần tích hợp.
- Bố cục chính bám Tachimanga; truyện chữ/EPUB dùng chung thư viện, reader riêng có font/cỡ chữ/khoảng cách dòng/nền trang/dấu trang/TTS. Không tích hợp kho sách Apple Books có DRM.
- Bộ lọc chương Đã đọc suy ra từ vị trí đọc tuần tự và cờ hoàn thành; model chưa có cờ đọc độc lập của từng chương. Lọc/sắp xếp/tìm kiếm chỉ đổi danh sách hiển thị, điều hướng giữ index gốc.
- Adapter hiện dùng Suwayomi companion cho APK và Node companion cho vBook JavaScript. Chưa có extension engine trong IPA. App hiện cần runtime ngoài thiết bị để tìm/cập nhật/tải nội dung nguồn; nội dung đã tải/import đọc offline.
- Source identity giữ String để không mất precision 64-bit trên web, phân biệt hai engine. Chapter cache/progress/bookmarks theo identity khi thứ tự nguồn thay đổi. Không đánh dấu novel offline khi ảnh embedded vẫn remote; tải ảnh giữ request headers và kiểm tra dung lượng khi streaming.
- Tachimanga APK cần JVM/DEX/Android compatibility riêng. vBook ZIP/plugin.json cần synchronous host API fetch/Response/Html/load/storage; browser/encrypted/native APIs chưa hỗ trợ đầy đủ. Engine hiện diện không tự chứng minh tương thích package.
- Runtime chỉ dùng extension đáng tin cậy; Node VM/child process không phải security sandbox. SourceRepository chưa hỗ trợ bearer-token authentication trong UI.
- IPA unsigned phải được ký/provisioning trước khi cài. Chỉ một file ZIP có đuôi IPA không được coi là build native thành công.

## Môi trường và giới hạn đã xác minh

- Máy làm việc local là Windows, không có Xcode. Build native iOS đã được xác nhận trên GitHub Actions macOS/Xcode16.4. Người dùng chỉ có IPA và Windows, không có app source hoặc Mac/Xcode; chưa có tài liệu ký/provisioning được cung cấp.
- Flutter SDK `D:/Codex/2026-09-14/ba/work/flutter-sdk`: Flutter 3.47.4, Dart 3.13.3, revision `9584c6713b324636289d067944a46fd6b49df14b`. CI pin cùng SDK.
- iOS project target 15.0 đáp ứng minimum khai báo của các plugins trong lockfile. Có Podfile/CocoaPods configuration; Swift Package Manager được tắt trong tiến trình build script, không đổi global Flutter config.
- Companion hiện nghe loopback Windows: Suwayomi 4567, vBook 4570; Komga fixture 25600. Điện thoại không truy cập các listener hiện tại; dùng LAN/server URL phù hợp khi triển khai kết nối thiết bị.
- Thử build bundle target iOS bị chặn bởi native asset hooks cần xcrun; chưa có iOS bundle được build trên Windows.
- Kết quả archive/analyze/widget test/companion không là bằng chứng cho import Files, native storage, TTS, permissions hoặc reader/runtime trên iPhone.
- Người dùng đã chỉ định repository `https://github.com/smilenek/Tachi-custom` để đưa source lên và chạy build IPA. Repo private, source đã được push lên main; Git credential hiện có quyền push/admin. Connector GitHub chưa truy cập được repo này, nên dùng Git CLI hiện đã được xác thực.

## Việc chưa hoàn thành

- Build lại IPA sau khi chỉnh giao diện theo yêu cầu mới; ký/provisioning và kiểm tra trên iPhone/iPad.
- Triển khai/kiểm chứng hai extension engines trực tiếp trong IPA nếu muốn app hoạt động độc lập với companion; đây là yêu cầu sản phẩm còn thiếu quan trọng.
- Compile và kiểm tra native UIKit trên simulator. Sáu ảnh người dùng là chuẩn sáu màn chính; chưa có reference đầy đủ chi tiết/reader/các trang con hoặc bằng chứng pixelmatch. Icon nguồn thật và chuyển nguồn tự động chưa triển khai.
- Kiểm chứng các flows Files/import/native Isar/backup/offline/TTS/local network/manga progress trên iPhone/iPad và các API/version extension được công bố hỗ trợ.
- Tracker, đồng bộ đa thiết bị/iCloud và annotation/highlight kiểu Apple Books chưa triển khai.

## Nguồn kỹ thuật

- https://tachimanga.app/help/guides/repositories.html
- https://github.com/tachimanga/tachimanga
- https://github.com/tachimanga/Tachidesk-Server
- https://github.com/duongden/vbook
- https://github.com/Darkrai9x/vbook-extensions/blob/master/extension-api.md
- https://github.com/Darkrai9x/vbook-extensions/blob/master/extension_docs.md
- https://docs.flutter.dev/deployment/ios
- https://tachimanga.app/assets/screenshot01.jpg
- https://github.com/xxian0913/tachimanga.github.io/commit/2e842080c6edce25d9c800ec1cbba92f2dd9f037
