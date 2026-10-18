# Đối chiếu runtime iOS của ứng dụng TachiBooks hiện có

**Chuẩn triển khai:** tiếp tục source ứng dụng đang có tại `keo1512/Tachi-custom`, commit tiếp nhận `5906375e0039f99fe67f1d7232376c43dfe95cea`; giữ 6 tab UIKit, Isar, vBook, Google/Firebase và các tính năng đã thêm. `engine/` chỉ là source tham khảo. Khảo sát thay VM/ứng dụng probe trước khi tiếp nhận repo không còn là hướng triển khai; không đề xuất greenfield hoặc JDK28 thay runtime hiện tại.

Ngày đối chiếu: 17/10/2026, múi giờ Việt Nam. Đây là tài liệu bằng chứng kỹ thuật và tiêu chí kiểm tra M1; trạng thái dự án vẫn chỉ ghi trong `PROJECT_STATE.md`. Số liệu có thể kiểm tra lại ở `verification/ios_runtime_assessment.json`.

**Kết luận hiện tại:** Java8 host production build được và đã chạy extension gốc cùng luồng lấy dữ liệu/ảnh qua loopback trên JVM Windows. Hash `305c8f.../d2434c...` là baseline sau Registry cache, trước triển khai cookie/Cloudflare mới ngày18/10; dùng các proof `verification/implementation_*` và `cloudflare_review_*` để kiểm tra source mới, không gán hash cũ cho mã mới. Runtime Pojav Zero Java8 đã pin là thành phần khác OpenJ9 JDK17 của IPA Tachimanga. Chưa có bằng chứng mới về native Zero/JNI thực thi trên iPhone; package checks, host Windows và UIKit simulator là ba loại bằng chứng riêng.

Phần mới ngày18/10 có source Objective-C xuất/import cookie Java→WK, cookie observer nhận clearance sau main response hợp lệ, timeout/background/clear cancellation và cờ logout; Swift DeviceTools vô hiệu browser trước clear/reset UA. Reader bổ sung native Vision ROI/EXIF orientation. XCTest WebKit seed/all-path/domain flags/automatic completion/background và phép đổi tọa độ OCR đã được viết trong target RunnerTests hiện có, nhưng **chưa compile/chạy** trên macOS/iOS. Không dùng Dart/Java xanh để đánh dấu những API này hoặc website Cloudflare thật đã hoạt động. Đối chiếu interceptor gốc riêng tại `verification/cloudflare_original_reference.json`; marker và bytecode chỉ chứng minh phát hiện challenge/đổi UA, không chứng minh một bộ tự giải CAPTCHA phổ quát.

## 1. Đầu vào và giới hạn bằng chứng

| Thuộc tính | Giá trị kiểm tra trực tiếp |
|---|---|
| IPA | `C:/Users/Nosgnoh/Downloads/Tachimanga iOS Mod IPA No Jailbreak Cheats 5.0 Hacked IPA by iOSGods.com.ipa` |
| SHA-256 | `2bbb80719fc4054dd45d223e9478dab76816017e3cedd2f22234f70c7b2e94c5` |
| Kích thước | 128.494.339 bytes |
| Phiên bản / build | 5.0 / 511 |
| Minimum iOS | 15.0 |
| Bundle ID | `com.mangacrush.ios` |
| Executable | `Payload/Tachimanga.app/Tachimanga`, 10.485.760 bytes |
| CPU Mach-O | ARM64, `CPU_TYPE_ARM64` |
| Đích kiểm tra tiếp theo | iPhone 15 Pro Max, iOS 27.0.1, theo thông tin được giao cho bước khảo sát |

Đã đọc archive, Info.plist, các load command/symbol trong Mach-O, chuỗi trong executable, file cấu hình `jre/` và nguồn công khai được dẫn dưới đây. Không thực thi mã của IPA, không gọi dịch vụ Tachimanga, không sửa IPA, không dùng lại executable/mod dylib vào sản phẩm mới. Không có kết quả cài, mở, JIT, lifecycle, hiệu năng hoặc ổn định trên thiết bị từ lượt khảo sát này.

## 2. Runtime thực tế của IPA

Các dấu vết độc lập cùng xác định **OpenJ9**:

- Chuỗi `PodsDummy_OpenJ9_iOS_SDK`, `MCNativeChannelPlugin`, `launchJVM:`.
- Chuỗi runtime ghi `Eclipse OpenJ9`, JCL `5f899adef82 based on jdk-17.0.15+6`, phiên bản `17.0.15.0`.
- Đường dẫn source còn trong binary có phần `openj9-ios/openj9-openjdk-jdk17/openj9/runtime/`.
- Symbol được **định nghĩa trong section của executable** gồm sáu `_J9VMDllMain_*`; không chỉ là tên hàm chưa được resolve.
- `jre/lib/options.default` có các tùy chọn OpenJ9, `jre/lib/modules` có 96.649.353 bytes. `jre/` còn chứa CA store, timezone và cấu hình security; thư mục này riêng lẻ không chứa đủ phần native runtime để rebuild.

Trong executable có các chuỗi cấu hình launch: `-Xint`, `-Djava.compiler=NONE`, `-Xms128M`, `-Xmx256M`, `-Xshareclasses:none`, đường dẫn classpath/java.home/user.dir/user.home và `-Dapp.tachimanga.childfirst=%@`. Chúng hỗ trợ kết luận rằng app được thiết kế để dùng interpreter và có cấu hình class loader; chưa phân tích call site để chứng minh mọi giá trị đó được truyền ở mọi lần khởi động. [OpenJ9 mô tả `-Xint` là chế độ chỉ thông dịch, tắt cả JIT lẫn AOT](https://eclipse.dev/openj9/docs/xint/).

Mach-O không có load command riêng cho `libjvm`/OpenJ9. Các symbol runtime và JNI đã được định nghĩa trong executable, hỗ trợ nhận định về static linkage. Không suy từ đó rằng có thể lấy thư mục `jre/` chuyển sang một app mới là đủ.

## 3. Các nhóm native của IPA gốc và ranh giới đối chiếu

| Nhóm | Bằng chứng trong IPA | Phần còn phải xác minh / xây dựng |
|---|---|---|
| SQLite JDBC | 61 symbol được định nghĩa thuộc `_Java_org_sqlite_*`, `_JNI_OnLoad_sqlitejdbc`, `_JNI_OnUnload_sqlitejdbc`; load command tới `/usr/lib/libsqlite3.dylib` | ABI của `NativeDB`, field/method lookup, static library registration, SQLite version/compile flags, transaction/backup/restore |
| zstd JNI | Chín symbol `_Java_com_squareup_zstd_*` được định nghĩa trong executable; có `libzstd.framework` | Java/Kotlin ABI đúng phiên bản, field layout, source/version libzstd, bộ nhớ streaming và xử lý frame lỗi |
| NativeChannel | `_Java_org_tachiyomi_NativeChannel_call_1utf8` được định nghĩa; có plugin native cùng tên | Handler iOS, topic/payload contracts, UTF-8/null, thread attach/detach, dispatch UI, exception và lifetime |

`NativeChannel.java` ở fork đã pin khai báo hàm native nhận hai `byte[]`, JNI descriptor `([B[B)V`. Source này chỉ cung cấp nửa Java của cầu nối. Đây là contract gốc để đối chiếu, không phải yêu cầu dùng lại bridge này: app hiện có giao tiếp bằng `ExtensionHost.invoke(String):String` và thư viện/backup do Flutter/Isar sở hữu. [Source Java đã pin](https://github.com/tachimanga/Tachidesk-Server/blob/2e52214106ffab02d13ff61a620def78414a8a45/AndroidCompat/src/main/java/org/tachiyomi/NativeChannel.java).

Nguồn công khai cho SQLite là [xerial/sqlite-jdbc tag 3.41.0.0, commit `da7794bff413b84c428099c75e7871c2dbca0007`](https://github.com/xerial/sqlite-jdbc/tree/da7794bff413b84c428099c75e7871c2dbca0007), trong đó có [NativeDB.c](https://github.com/xerial/sqlite-jdbc/blob/da7794bff413b84c428099c75e7871c2dbca0007/src/main/java/org/sqlite/core/NativeDB.c). Đây là ứng viên nguồn để đối chiếu với JAR iOS tùy biến trong IPA gốc, chưa chứng minh tương đương. iOS có [yêu cầu hỗ trợ riêng trong upstream](https://github.com/xerial/sqlite-jdbc/issues/745); binary macOS ARM64 không tương đương iPhoneOS ARM64. Các khoảng trống ABI này thuộc khảo sát cơ chế gốc; không yêu cầu đưa SQLite JDBC vào TachiBooks đang dùng Isar.

Nhóm tên zstd JNI khớp với source [square/zstd-kmp, commit `b52ab430d64dc9313844ca07dc950e54c330636c`, ZstdKmp.cpp](https://github.com/square/zstd-kmp/blob/b52ab430d64dc9313844ca07dc950e54c330636c/zstd-kmp/native/ZstdKmp.cpp). Tên hàm khớp chưa xác nhận cùng version hoặc field layout. TachiBooks giữ portable zstd hiện có; không có kế hoạch nối lại JNI của IPA gốc. Notice/license của phần tái sử dụng vẫn cần được giữ.

## 4. Phạm vi nguồn runtime gốc

Trong các repo công khai và tìm kiếm có phạm vi đã thực hiện, chưa tìm được source/build recipe `OpenJ9_iOS_SDK` tương ứng chính xác binary gốc. Điều này không chứng minh source không tồn tại ở bất kỳ đâu. Bản hiện có tiếp tục Pojav Zero Java8 và abstraction đang dùng; chưa có quyết định thay VM.

## 5. Hợp đồng sản phẩm giữ nguyên

Giữ Isar, stable String64 source IDs, chapter identities, dữ liệu offline, backup recovery/CAS, extension API và 6 tab UIKit. SQLite JDBC/zstd JNI/NativeChannel ở IPA gốc chỉ là đối tượng khảo sát; không mang các thành phần này vào production khi kiến trúc hiện tại đã có Isar/portable zstd/JNI JSON tương ứng.

## 6. Ranh giới nghiệm thu

Đích thiết bị đầu tiên là iPhone15ProMax/iOS27.0.1. Chưa có lượt native build/CI/IPA/sign/install/device mới từ khảo sát này. Các kiểm tra cần gắn đúng build/commit/hash và so từng chức năng với Tachimanga gốc; không gọi toàn bộ app tương đương từ số test pass. Gate device cần cold JVM start không manual JIT, nạp extension thật, Unicode/JNI, đọc/ảnh/offline/restart, cookie/WebView, lỗi dung lượng/restore, background expiry và đo hiệu năng/RAM với dữ liệu đại diện.

## 7. Đối chiếu với source ứng dụng hiện có

Đã đọc toàn bộ `PROJECT_STATE.md` hiện tại sau khi tiếp nhận repo. Bản production dùng `packages/tachi_runtime`, `tools/native_extension_engine`, cơ sở dữ liệu Isar và 6 tab UIKit. Thư mục `engine/` chỉ là source tham khảo upstream; không phải runtime production. Không đề xuất tạo app, thay VM, thay schema/storage hoặc thiết kế lại các tab.

| Thành phần | Tachimanga IPA gốc | TachiBooks source hiện tại |
|---|---|---|
| JVM | OpenJ9 JDK17, static trong executable | Pojav Zero Java8 prebuilt, hash/pin trong `tools/native_extension_engine/upstream.json:3` |
| Runtime provenance | Binary/source path, chưa có SDK source recipe tương ứng | `sourceCorrespondenceVerified=false` và `deviceRuntimeVerified=false` ghi rõ ở `upstream.json:10` |
| Native layout | Runtime/JNI nhúng executable | 9 flat frameworks, alias tương đối, layout version2 |
| Engine | Backend Tachidesk/SQLite và NativeChannel | Java8 `ExtensionHost`, API nguồn compile từ source, bridge JNI trả JSON; thư viện/thao tác đọc thuộc app Flutter/Isar |
| Nén | Square zstd JNI | Portable zstd/Airlift source/dependency; không mặc định phải tái tạo zstd JNI gốc |
| Khởi động simulator | Chưa thực thi IPA gốc | `TachiRuntimePlugin.m:78` từ chối nạp JVM device trên simulator |
| Bộ nhớ JVM | Literal `-Xms128M/-Xmx256M` | `TachiRuntimePlugin.m:119` dùng `-Xms16m/-Xmx128m/-Xss512k`; phải đo trên iPhone, không tự tăng theo IPA |

Bootstrap/native layout hiện có đã có nhiều guard phù hợp: Unicode qua JNI UTF-16, kiểm tra cấp phát và global ref, serialize tạo JVM, request/response bounded, host-first classpath, sandbox riêng, provider/CA resources, framework dependency closure và checksum/CRC. Source guard không thay cho việc mở runtime thực tế.

Lượt kiểm tra Windows mới đã chạy **36 Python tests đạt** với `python -B -m unittest test_package_jvm_frameworks test_check_native_runtime_bundle test_native_array_decoder_resource` từ thư mục `tools/`. Các tests này dùng Mach-O fixture, mock `install_name_tool` và mô hình symlink trên Windows. Chúng kiểm tra layout/alias/hash/CRC/bounds/rollback; không nạp JVM. Lệnh theo package từ repo root ban đầu bị import-path error; đã sửa working directory rồi chạy đủ bộ đạt. Chưa chạy lại CI/XCTest/device.

`packages/tachi_runtime/ios/Runtime` chưa được tạo trong checkout Windows tại thời điểm đối soát. Thư mục `artifacts/` hiện có và chứa bằng chứng lịch sử; người dùng có IPA11 ở Downloads. Đối chiếu package đó và host harness do tác vụ gốc thực hiện được ghi trong các bằng chứng riêng, không coi là lượt thực thi native của tài liệu này.

### Lỗi timeout/mutation đã tái hiện và sửa hẹp

Trước sửa, `NativeTachiRepository._requestUnlocked` báo TIMEOUT sau90giây nhưng raw Future JNI tiếp tục. `ExtensionMutationQueue` coi action đã kết thúc và cấp lease backup/mutation tiếp theo. Bằng chứng Dart tái hiện thứ tự `mutation-entered → backup-capture-entered → native-mutation-completed`; không cần và không giả là đã chạy JVM/iPhone. Native Java có lock nhưng không có cancellation protocol, nên không được coi timeout phía Dart là native đã dừng.

Sửa trong hai file hiện có: khi timeout, giữ raw Future cho lease hiện tại; caller vẫn nhận lỗi90giây nhưng mutation/backup tiếp theo phải đợi executor thật sự thành công hoặc lỗi. Reentrant follow-up cũng đợi, delayed descendant không kế thừa lease đã trả, lỗi đến muộn được tiêu thụ để không thành unhandled error. Nếu native không bao giờ settle thì lease tiếp tục chặn thao tác nhạy cảm; sửa này bảo vệ dữ liệu, không tuyên bố có thể cưỡng bức hủy JVM.

Regression mới ở `test/native_runtime_timeout_boundary_audit_test.dart` kiểm tra late success, late error, chặn backup/mutation và reentrant follow-up. Bộ5suite liên quan đạt **67tests**: timeout boundary, extension mutation queue, extension portability/backup replay, native Tachi adapter và native cover. Analyze3file sửa sạch; diff whitespace sạch. Đây là kiểm chứng Dart/host, chưa đóng gói sửa này vào IPA hoặc thử iPhone.

### Phần cần ưu tiên trước lần nghiệm thu tiếp theo

1. Kiểm chứng đúng IPA11 và bản chứa thay đổi mới trên iPhone15ProMax/iOS27.0.1: cold JVM start, source factory, đọc/ảnh thật, offline/restart, cookie/WebView, background expiry và source lỗi. Hosted UIKit tests chỉ xác nhận các bridge chúng thực thi; simulator đang từ chối JVM.
2. Nối các kết quả helper/APK mới với đúng fingerprint sau sửa Registry ở mục 8, rồi ghi canonical member bytes để nối bằng chứng Windows với JAR CI khi được yêu cầu build. Source tham khảo `engine/` không phải production engine.
3. Kiểm chứng hạn mức/chờ native, extension chặn trong coroutine/interceptor và phục hồi sau lỗi. `ExtensionHost.java:61` dùng lock không deadline, `SuspendBridge.java:24` dùng cooperative timeout 45 giây; chưa có hard cancellation cho code extension bất kỳ.
4. Đối chiếu Reader theo luồng, không chỉ đủ nút: ảnh dài, zoom/rotate, source thay đổi và restore trong lúc đang đọc. Hai lỗi browser retry dưới đây đã tái hiện và sửa trong source; còn phải thử trên iPhone.

### Reader: retry sau trình duyệt nguồn

Đã tái hiện hai lỗi widget trên source trước sửa: khi chương B lỗi sau chương A, hoàn tất trình duyệt lại gọi chương A (`/chapter` thay vì `/chapter-two`); khi ảnh trong chương lỗi ở tiến độ0,45, hoàn tất trình duyệt ghi tiến độ về0. Cả hai đến từ callback gọi `load(current)` với mặc định `resume=false`, bỏ chương đang yêu cầu và vị trí đang đọc.

Sửa hẹp `ReaderScreen.openSourceWebsite`: giữ generation, revision, stable chapter ID và offset trước await; sau await từ chối kết quả của chương/nguồn/thư viện cũ rồi retry đúng chương/vị trí đã chụp. Không sửa layout, native browser/cookie hoặc renderer. Bốn regression trong `test/native_image_pipeline_test.dart` kiểm tra đúng chương, đúng offset, chuyển chương trong lúc browser chờ và restore trong lúc browser chờ.

Sau sửa,69tests thuộc6suite reader đạt khi chạy `--concurrency 1`, log `verification/reader_browser_retry_tests.log`; analyze2file sạch. Lượt concurrent trước đó đạt68/69 với một test auto-scroll cũ thất bại vì offset0; test đó chạy riêng và cả6suite tuần tự đều đạt. Vì có khác biệt lịch decode/timer, không ghi lượt concurrent là sạch hoặc coi lần rerun che mất lần lỗi. Chưa có thay đổi auto-scroll. Các kết quả này không xác nhận cảm giác thao tác, ảnh/cookie thật hoặc đọc/tải trên iPhone.

### Giữ page locator nội bộ khỏi HTTP thông thường

Ở checkpoint đã kiểm chứng, engine production phân giải image URL theo trang đang yêu cầu. Host dành riêng `page.tachibooks.invalid` là metadata cho native image RPC, không phải URL ảnh để gửi DNS/HTTP. Cầu nối chuỗi ảnh hiện có được giữ, không thêm field hoặc đổi schema Isar.

Guard trong `native_page_locator.dart` nhận diện host dành riêng, kể cả chữ hoa hoặc dấu chấm cuối hostname. Reader khi không còn native image loader hiển thị lỗi tiếng Việt yêu cầu engine trên thiết bị; downloader chặn trước HTTP thông thường. Khi native có sẵn, locator được giữ nguyên cùng source/chapter/ordinal và kết quả offline là bytes ảnh thật. Cache đã tải một phần, URL ảnh cũ, data URL và đường dẫn attachment tiếp tục dùng hợp đồng cũ.

78tests trong6suite native adapter/image pipeline/downloader/cancellation/restore/completion đạt, một ca Isar native Windows opt-in bị skip vì lượt này không bật DLL. Tests kiểm tra marker tới native RPC đúng ordinal, native bytes thành offline, không tạo Image.network/HTTP khi thiếu native và giữ cache từng phần. Analyze5file liên quan sạch, diff whitespace sạch. Bằng chứng Java về Page/ordinal/lazy retry mới nhất được tổng hợp ở mục 8; tests Dart không xác nhận runtime iPhone.


## 8. Checkpoint host và extension/data mới nhất đã đối soát

Đọc `verification/final_host_compile.json`, `final_apk_loading_results.json`, `extension_data_final_helpers.log`, `extension_focus_full_flutter_tests.log` và `extension_focus_analyze.log`; kiểm độc lập bytes/fingerprint trên Windows. Đây là tổng hợp kết quả đã hoàn tất, không chạy lại toàn bộ suite trong lượt viết báo cáo. Đối soát kết quả cuối ngày18/10/2026, giờ Việt Nam.

| Dấu vân tay checkpoint | Giá trị đã xác minh |
|---|---|
| Host JAR sau sửa Registry cache | `305c8fc442e33fd7cf1af6c785e526b36928eb5d6508fc80c5590262e3aa5081` |
| Source fingerprint | `d2434cae84b32ae9b4ce1b4a6fda277a1858fa0cc359afdbc389ae8ad4d642b8` |
| Source/bytecode |26 Java files, 55 host classes major 52; source snapshot được kiểm khớp ở lúc đối soát |
| Dependencies | `b77d955a79745d300b7522e224327d6bcc5a108399231dce7fe708150c2ee2bb`; classes major ≤52 |
| Entry point | `dev.tachibooks.engine.ExtensionHost.invoke`, JNI `(Ljava/lang/String;)Ljava/lang/String;` |
| Máy chạy proof | Windows 11 / Java 1.8.0_503 HotSpot `-Xint`, khác Zero native iOS |
| Artifact | Host local mới; chưa có IPA chứa thay đổi mới |

`final_` là tên file bằng chứng tại checkpoint, không tự mang nghĩa source mới nhất. Host/source trước sửa cache là `51ba0f.../c961acb...`. Host mới ở bảng đã được kiểm độc lập SHA, fingerprint 26 file source và 55 classes major 52. `extension_cache_repair_after.log` xác nhận 9/9 boundary tests đạt, bao gồm ba chế độ cache malformed/valid ZIP/đổi APK với 26/26/23 assertions, giữ preference và rollback khi conversion hoặc ghi registry lỗi. Helper tổng hợp77tests và matrix3/3APK đã chạy lại hoàn tất sau sửa với đúng host/source mới; các kết quả76helper trước sửa không được dùng thay kết quả cuối.

Dependency harness lấy từ IPA11 đã xác minh SHA `d32645766ee4c352edc6215e793ace4794a6716c39944ae071ca8e73e6b8afd0`; `build11_host_harness_input.json` ghi provenance. Host production được build lại từ source; không lấy host IPA11 cũ làm bằng chứng cho các sửa local.

`final_apk_loading_results.json` đạt 3/3 gói APK giữ nguyên bytes trong phạm vi install/factory/preferences/cold-JVM-restart:

| Gói | API | Phạm vi |
|---|---|---|
|Komga1.4.47 từ IPA gốc|1.4|3 source, 4 preferences/source, restart giữ String64 IDs/preferences|
|Komga1.6.73 quan sát17/10/2026|1.6|3 source, 8 preferences/source, restart giữ IDs/preferences|
|MANGA Plus1.6.67 quan sát17/10/2026|1.6|9source, đọc3preferences ở3source được chọn, restart giữ IDs/preferences|

Matrix quan sát background2giây/pha và tự ghi `websiteSearchReadDownloadVerified=false`, `allExtensionsVerified=false`, `iosRuntimeVerified=false`. Không biến3/3 thành đã đọc/tải website của3gói hoặc tương thích toàn kho.

`extension_data_final_helpers.log`:77tests,62pass/15Firestore-emulator-opt-in-skip/0fail. Helper rebuild source production; ngoài structural fixture có các proof Java thật:

- **APK Komga gốc API 1.4 và Komga quan sát API 1.6:** cùng parser extension thật đi catalogue/search/detail/chapter/Page/getImage qua loopback do dự án kiểm soát, mỗi ca 1 truyện / 1 chương / 1 trang / PNG 68 bytes. Digest ảnh `3fd24bcfdb17a6027c5f3ed896d17a020d6ff9d9e4d06362461a9b44b6ac1b52`. Không truy cập website ngoài, không dùng tài khoản hoặc thư viện người dùng.
- **Page/covers:**23 assertions cô lập trang lỗi,30 assertions Page/ordinal khi CDN URL đổi,9 assertions page-request hook không phá mở chương;44 assertions cover/header/client/cookie/URL tương đối/bounds/parallelism và không áp page transform vào bìa.
- **Cookie/UA:**92 assertions file thật/cold JVM/expiry/flags/deletion/legacy import/corruption/clear/write failure;6 assertions browser snapshot cũ không ghi đè HTTP cookie refresh khi restart;27 assertions UA theo host qua redirect thật.
- **Phục hồi:** browser-session malformed/oversize/array/null/empty/unknown/entry giữ bytes rồi restart;8 assertions rollback preference khi source constructor lỗi;12 assertions gate extensionLib 1.3–1.6 theo bytecode IPA; cache APK/JAR hỏng được phục hồi qua reinstall và giữ metadata/source/preferences khi conversion hoặc registry write thất bại. Gzip/Brotli/Zstd fixture decode exact bytes/digest có trong APK matrix.

`extension_focus_full_flutter_tests.log`:**1063 pass / 6 skip / 0 fail**, analyzer sạch. Có DLL Isar Windows thật ở checkpoint; skip có điều kiện không là native/device acceptance. Các lượt focused 69 Reader / 67 timeout-related / 78 image-related trước đó giữ để giải thích phạm vi nhưng không cộng dồn vì có test trùng.

## 9. Rà lại native bridge và cookie

Plugin nguồn hiện có giữ UTF-16/alloc/globalref/thread-attach/detach guard, callback main queue và khóa khởi tạo JVM. Tại `TachiRuntimePlugin.m:78–80`, simulator chủ động từ chối JVM device. 37 hosted XCTest lịch sử vì vậy không chứng minh Zero/JNI/extension chạy trên simulator; chưa rerun native tests ở lượt local hiện tại.

`SourceCookieJar/SourceCookieStore` production đã có kho HTTP cookie bền, flags/expiry/identities/tombstone authority, atomic write/bounds và `cookiePersistenceHealthy`; không đưa cookie vào backup/sync. `TachiSourceBrowser` dùng WK default store, lấy UA/cookie thuộc scope khi bấm Xong rồi chuyển sang Java. Cài đặt `SourceMaintenance.clearCookies` **đã nối Java → DeviceToolsBridge → HTTPCookieStorage/WK cookie store**, `clearWebData` tiếp tục xóa website data. Đây là đường source đã triển khai, cần compile/thử bản mới trên thiết bị; không gọi là chưa có chức năng xóa WK.

Khoảng trống **Java↔WK hai chiều** vẫn còn: browser không seed HTTP-cookie mới từ Java trước loadRequest; Java refresh có thể không xuất hiện trong WK hoặc WK còn bản cũ. Snapshot explicit-apply khi bấm Xong có thể thay phiên Java. Proof giữ cookie refresh khi restart không chứng minh hai store đồng nhất trong các thao tác mở browser thực tế. Main-frame WK hiện giới hạn cùng hostname, nguồn đăng nhập redirect sang hostname khác cần quyết định/kiểm chứng riêng. Không có proof iPhone cho Cloudflare/login/session/clear/expiry.

Lock Java không có deadline và coroutine timeout 45 giây có tính hợp tác; một extension chặn có thể giữ engine bận. Timeout Dart giữ lease backup/mutation cho tới raw settle, không hard-cancel JVM. Background phụ thuộc iOS cấp lease/task và vòng đời engine; chưa đo iPhone và không bảo đảm sau force-kill. Đây là các giới hạn hiện có cần đưa vào gate nghiệm thu, không suy thành lỗi thiết bị đã tái hiện.

## 10. Phần còn cần bằng chứng trên đúng artifact

|Phần|Tình huống|Điều kiện đạt|
|---|---|---|
|JVM/dyld|Release cold start sau reboot; 9 frameworks/aliases/signing/bootstrap/security|Không cần manual JIT/debugger; runtime ID/build ID rõ, HTTPS/provider hoạt động|
|Extension|APK1.4/1.6, factory/prefs/search/detail/TOC/Page/image/restart|ID/ordinal/headers/cookie đúng; trang lỗi không chặn độc lập|
|Reader/offline|Locator/URL hết hạn/chương dài/tải dở/máy bay/restart|Resume đúng trang/fraction; giữ partial bytes; không gửi locator tới DNS|
|Cookie/WK|Login/challenge/HTTP refresh/mở WK/clear/restart|Không hồi sinh cookie đã xóa; session theo phạm vi hỗ trợ được xác nhận|
|Data/recovery|Source pending/timeout/restore lỗi/stale preview/disk full|Recovery/input nguyên vẹn, kết quả cũ không ghi đè source/ID/tiến độ|
|Nền/tài nguyên|Khóa máy/background expiry/mất network/OOM|Queue bền, dừng cấp tác vụ đúng, không gọi timeout là hủy native|
|Hiệu năng|Cold launch/first page/scroll/zoom/chương dài|Đo RAM/CPU/frame time cùng máy và IPA gốc, chốt ngưỡng từ baseline|
|Tái lập|CI sạch với source fingerprint/dependency đã pin|Artifact/hash/commit nối được với proof, không executable/mod dylib gốc|

Không thể kiểm thử mọi trạng thái vô hạn; ưu tiên lỗi crash, mất dữ liệu, ranh giới extension/API và phục hồi. Chưa có source-correspondence của prebuilt runtime và bằng chứng device thì không gọi runtime được rebuild đầy đủ từ source hoặc toàn ứng dụng đã giống Tachimanga trên iPhone.
