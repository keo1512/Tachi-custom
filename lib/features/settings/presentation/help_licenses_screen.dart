import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/widgets/feedback.dart';
import 'settings_widgets.dart';

class HelpTopic {
  const HelpTopic(this.title, this.text);
  final String title, text;
}

const helpTopics = <HelpTopic>[
  HelpTopic(
    'Thư viện và tìm kiếm',
    'Thư viện chứa truyện từ nguồn và sách nhập trên thiết bị. Bấm bìa để mở thông tin, mục lục và tiếp tục đọc. Tìm kiếm hỗ trợ tên, tác giả, họa sĩ, thể loại, ghi chú và nguồn; mở hướng dẫn truy vấn trong menu tìm kiếm để kết hợp điều kiện. Bộ lọc có thể lưu theo tên để dùng lại.',
  ),
  HelpTopic(
    'Danh mục, nhóm và chọn nhiều',
    'Nhấn giữ truyện để chọn nhiều, hoặc chọn tất cả truyện đang hiển thị trong menu. Bạn có thể thêm danh mục, nhóm theo bộ truyện/tác giả và tải hàng loạt. Tự nhóm dùng metadata đã lưu. Đổi thứ tự danh mục trong menu thư viện; kéo xuống để kiểm tra chương mới cho truyện đang hiển thị.',
  ),
  HelpTopic(
    'Thêm kho và cài nguồn',
    'Trong Duyệt, mở Công cụ nguồn → Kho tiện ích mở rộng để thêm link index.pb/JSON của kho Tachiyomi hoặc link kho vBook phù hợp. Đợi danh sách tải xong, chọn tiện ích và bấm Cài. Sau khi engine xác nhận cài thành công, mở nguồn trong Nguồn truyện. Không cần kết nối máy chủ ngoài khi dùng engine trên thiết bị. Một extension có thể cần cấu hình tài khoản, địa chỉ thư viện hoặc trình duyệt theo yêu cầu của chính nguồn đó.',
  ),
  HelpTopic(
    'Tìm truyện và tùy chọn nguồn',
    'Duyệt có nguồn gần đây, nguồn đã ghim và bộ lọc nhiều ngôn ngữ. Tìm trong một nguồn hoặc dùng tìm kiếm toàn cục. Tùy chọn nguồn nằm ở nút thiết lập của nguồn. Nếu trang yêu cầu đăng nhập hoặc xác minh qua trình duyệt, mở trình duyệt của nguồn rồi thử lại; app không bảo đảm vượt mọi cơ chế xác minh của website.',
  ),
  HelpTopic(
    'Chi tiết truyện và chương',
    'Màn truyện hiển thị bìa, mô tả, nguồn, thể loại và mục lục. Có thể thêm/bỏ khỏi thư viện, tiếp tục đọc, tìm/lọc/sắp xếp chương, đánh dấu đọc và tải chương. Chương đọc và nội dung tải được giữ khi nguồn thay đổi thứ tự bằng mã chương đã xác minh.',
  ),
  HelpTopic(
    'Đọc manga',
    'Các trang xếp dọc liền nhau. Cuộn để đọc; thanh tiến độ cho biết trang hiện tại, kéo thanh để cuộn ngay tới trang đã chọn. Chạm để hiện/ẩn công cụ, dùng hai ngón phóng to hoặc chạm hai lần vào ảnh. Thiết lập nâng cao có cách vừa ảnh, lề, khoảng cách, độ sáng, hiệu ứng màu, vùng chạm, giữ để cuộn và tự cuộn. Có thể lưu thiết lập riêng cho từng truyện.',
  ),
  HelpTopic(
    'Đọc EPUB và truyện chữ',
    'Reader chữ có font, cỡ chữ, giãn dòng, nền sáng/tối/sepia, dấu trang và đọc thành tiếng. Nội dung EPUB được nhập theo mục lục; app không giải mã sách có DRM. Dấu trang và vị trí đọc được lưu cùng thư viện.',
  ),
  HelpTopic(
    'OCR và dịch',
    'Mở thao tác của trang ảnh để nhận dạng chữ. Kết quả OCR có thể chọn và sao chép; mở thao tác dịch khi thiết bị hỗ trợ. Độ chính xác phụ thuộc ảnh và ngôn ngữ. OCR/dịch là chức năng native và có thể cần quyền hoặc tài nguyên ngôn ngữ trên thiết bị.',
  ),
  HelpTopic(
    'Tải offline và tải hàng loạt',
    'Tải từ mục lục, Cập nhật hoặc chọn nhiều truyện trong Thư viện. Chọn tất cả chương chưa tải hoặc chỉ chương chưa đọc. Các lượt dùng chung hàng chờ, tránh thêm trùng; thiết lập cho phép 1–4 chương đồng thời. Lỗi giữ lại để thử lại. Chỉ đọc offline đầy đủ khi nội dung và các ảnh của chương đã được lưu xong. iOS có thể giới hạn thời gian chạy nền; mở lại app để tiếp tục hàng chờ.',
  ),
  HelpTopic(
    'Cập nhật và lịch chương',
    'Kéo xuống trong thư viện hoặc chạy cập nhật để tìm chương mới. Thiết lập phạm vi danh mục và điều kiện bỏ qua. Chương mới có thể được tự thêm vào hàng chờ theo chính sách tải. Lịch chương là dự đoán từ các ngày phát hành thực đã nhận, chỉ xuất hiện khi có đủ dữ liệu; không phải lịch xác nhận từ tác giả.',
  ),
  HelpTopic(
    'Lịch sử, thời gian đọc và ẩn danh',
    'Lịch sử cho phép tìm và chọn nhiều mục để xóa. Xóa lịch sử không xóa sách hoặc nội dung tải. Thông tin Đọc tổng hợp hoạt động và mục tiêu đọc. Chế độ ẩn danh không ghi hoạt động đọc mới; bảo mật còn có khóa ứng dụng và che màn hình khi app vào nền.',
  ),
  HelpTopic(
    'Chuyển nguồn truyện',
    'Vào Thêm → Chuyển nguồn, chọn truyện và nguồn đích, tìm rồi chọn kết quả đúng. Xem trước các chương đối chiếu được trước khi xác nhận. Cờ đã đọc và dấu trang được chuyển theo số chương hoặc tên chương duy nhất; vị trí bắt đầu ở đầu chương mới vì nội dung có thể khác. Bản nguồn mới cần tải lại nội dung. Mặc định giữ nguyên truyện và nội dung offline của nguồn cũ; app không tự ghép các chương mơ hồ.',
  ),
  HelpTopic(
    'Nhập truyện cục bộ',
    'Nhập TXT, EPUB không DRM, CBZ/ZIP hoặc ảnh được thiết bị hỗ trợ. CBZ/ZIP có thể chứa thư mục chương, cover.jpg và details.json. Vào Thêm → Cài đặt → Chung → Truyện từ thư mục trên máy, chọn một thư mục qua Tệp để quét truyện, gồm RAR/CBR không mã hóa và không chia nhiều tập. Quét lại để nhận chương mới; chương đã sao chép vẫn được giữ khi file nguồn không còn. Quyền thư mục chỉ lưu trên thiết bị này và cần chọn lại khi chuyển máy. File đầu vào được giữ nguyên.',
  ),
  HelpTopic(
    'Sao lưu đầy đủ và khôi phục',
    'Vào Thêm → Đồng bộ → Sao lưu & Khôi phục. Bản TachiBooks mang thư viện, tiến độ, dấu trang, nội dung offline, cấu hình công khai và gói extension đã xác minh khi engine hỗ trợ, tối đa 128 MB. Khi nhập, kiểm tra định dạng, số sách và nguồn ở màn xem trước; chọn có khôi phục cấu hình và gói nguồn hay không. Nếu một gói chưa cài xong, kế hoạch được giữ trên máy để thử lại; thư viện offline vẫn dùng được. Sách đã có được giữ nguyên, sách mới được thêm. Có thể hủy trong lúc chuẩn bị; app lưu bản phục hồi trước lần ghi nguyên tử.',
  ),
  HelpTopic(
    'Sao lưu tự động và bản phục hồi',
    'Chọn chu kỳ và số bản giữ lại trong Sao lưu tự động. Chọn dữ liệu ứng dụng hoặc một thư mục qua Tệp/iCloud Drive. App chỉ quản lý thư mục con TachiBooks-Backups ở vị trí ngoài app khi đang hoạt động hoặc trở lại màn hình; bản cũ chỉ bị xóa sau khi bản mới được ghi và xác minh. Quyền thư mục chỉ lưu trên thiết bị này. Màn hình hiển thị lần chạy gần nhất và lỗi nếu có. Xuất bản cần giữ sang Tệp/iCloud Drive. Bản phục hồi chứa thư viện trước lần khôi phục hoặc đồng bộ thay thế gần nhất.',
  ),
  HelpTopic(
    'Trao đổi Tachimanga và Mihon',
    'Nhập .tmb build511/type0 và protobuf gzip của Mihon/Tachiyomi đã hỗ trợ. File chỉ mang dữ liệu thực sự có trong bản sao lưu. Xuất Mihon dùng .tachibk cho metadata, chương và tiến độ, không thay thế bản TachiBooks đầy đủ media. Backup ngoài không chứa gói extension; cần cài nguồn tương ứng. Backup đầy đủ TachiBooks có thể mang gói nguồn đã cài khi engine hỗ trợ. Tracker và memo nhập được giữ như dữ liệu tương thích, không tự liên kết dịch vụ; memo không được áp dụng sang nguồn khác. Các phiên bản TMB khác và bản sao lưu vBook chưa có định dạng được xác minh.',
  ),
  HelpTopic(
    'Tài khoản và đồng bộ nhiều máy',
    'Đăng nhập Google trong Đồng bộ, bật đồng bộ tự động hoặc chọn Đồng bộ ngay. Dữ liệu cloud thuộc tài khoản đang đăng nhập. Nội dung offline được mang cùng snapshot; lỗi dung lượng hoặc hạn mức được báo, không tự mua thêm. Kiểm tra lựa chọn khi có xung đột và giữ một bản sao lưu đầy đủ trước khi thay thư viện.',
  ),
  HelpTopic(
    'Chẩn đoán khi nội dung không mở được',
    'Vào Thêm → Cài đặt → Nâng cao và chẩn đoán → Kiểm tra thư viện để kiểm tra cấu trúc, tệp đính kèm và giải mã ảnh offline. Nếu cờ đã tải không có nội dung, xem trước rồi sửa riêng trạng thái đó. Ảnh không đọc được có thể hỏng hoặc không được decoder thiết bị hỗ trợ; app không tự xóa. Có thể xuất báo cáo chỉ gồm số lượng, không chứa tên truyện hay tài khoản.',
  ),
  HelpTopic(
    'Giao diện, bảo mật và phím điều khiển',
    'Thiết lập giao diện cho phép theo hệ thống, sáng hoặc tối. Reader có nền đồng bộ và tùy chọn đọc riêng. Khóa app dùng Face ID/Touch ID hoặc mật mã thiết bị với thời gian tự khóa. Reader hỗ trợ phím điều hướng; hai ngón zoom tạm chặn cuộn cha để không làm lệch vị trí đọc.',
  ),
  HelpTopic(
    'Phạm vi hỗ trợ nguồn truyện',
    'Việc thấy nguồn hoặc cài được gói không bảo đảm mọi truyện từ nguồn đều đọc được; báo lỗi nguồn cần phân biệt với lỗi thư viện hoặc nội dung offline. Khi báo lỗi, ghi rõ nguồn, thao tác và phiên bản app để kiểm tra đúng trường hợp.',
  ),
];

class HelpLicensesScreen extends StatefulWidget {
  const HelpLicensesScreen({super.key});
  @override
  State<HelpLicensesScreen> createState() => _HelpLicensesState();
}

class _HelpLicensesState extends State<HelpLicensesScreen> {
  String query = '';
  @override
  Widget build(BuildContext context) => SettingsPage(
    title: 'Trợ giúp & Giấy phép',
    children: [
      const SettingsHeading('TachiBooks · Dự án cá nhân'),
      const SettingsNote(
        'Ứng dụng iOS đọc manga, truyện chữ và ebook. Mã nguồn dự án: github.com/smilenek/Tachi-custom. Không có chức năng mua Premium trong app.',
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: CupertinoSearchTextField(
          placeholder: 'Tìm hướng dẫn',
          onChanged: (value) =>
              setState(() => query = value.trim().toLowerCase()),
        ),
      ),
      for (final topic in helpTopics.where(
        (topic) => '${topic.title} ${topic.text}'.toLowerCase().contains(query),
      ))
        SettingsRow(
          title: topic.title,
          onTap: () => openSettingsPage(
            context,
            SettingsPage(
              title: topic.title,
              children: [SettingsNote(topic.text)],
            ),
          ),
        ),
      const SettingsHeading('Thành phần được sử dụng'),
      SettingsRow(
        title: 'Giấy phép Flutter và các gói Dart',
        icon: CupertinoIcons.doc_text,
        onTap: () => openSettingsPage(
          context,
          const LicensePage(applicationName: 'TachiBooks'),
        ),
      ),
      SettingsRow(
        title: 'Giấy phép runtime native',
        subtitle: 'OpenJDK, thư viện engine, vBook runtime và SwiftSoup',
        icon: CupertinoIcons.doc_text,
        onTap: () =>
            openSettingsPage(context, const NativeLicenseNoticesScreen()),
      ),
    ],
  );
}

class NativeLicenseNoticesScreen extends StatefulWidget {
  const NativeLicenseNoticesScreen({super.key});
  @override
  State<NativeLicenseNoticesScreen> createState() =>
      _NativeLicenseNoticesState();
}

class _NativeLicenseNoticesState extends State<NativeLicenseNoticesScreen> {
  late final notices = loadNativeNotices();
  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<Map<String, dynamic>>>(
    future: notices,
    builder: (context, snapshot) => SettingsPage(
      title: 'Giấy phép runtime native',
      children: [
        if (snapshot.connectionState != ConnectionState.done)
          const SettingsRow(
            title: 'Đang đọc giấy phép…',
            trailing: CupertinoActivityIndicator(),
          ),
        if (snapshot.hasError)
          const SettingsNote(
            'Không đọc được giấy phép trong gói ứng dụng. Hãy kiểm tra lại bản cài đặt.',
          ),
        for (final notice in snapshot.data ?? <Map<String, dynamic>>[])
          SettingsRow(
            title: (notice['resources'] as List)
                .map((resource) => resource['package'])
                .toSet()
                .join(' · '),
            subtitle:
                '${(notice['resources'] as List).length} tài nguyên có cùng thông báo',
            onTap: () => openSettingsPage(
              context,
              SettingsPage(
                title: 'Nội dung giấy phép',
                children: [
                  SettingsNote(
                    (notice['resources'] as List)
                        .map(
                          (resource) =>
                              '${resource['package']}\n${resource['path']}',
                        )
                        .join('\n\n'),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(notice['text'] as String),
                  ),
                  if (notice['sourceBytes'] != null)
                    SettingsRow(
                      title: 'Xuất tài nguyên gốc',
                      icon: CupertinoIcons.arrow_up_doc,
                      onTap: () => perform(
                        context,
                        () => FilePicker.saveFile(
                          fileName:
                              'tachibooks-license-${(notice['sha256'] as String).substring(0, 12)}.blob',
                          bytes: base64Decode(notice['sourceBytes'] as String),
                          mimeType: 'application/octet-stream',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

Future<List<Map<String, dynamic>>> loadNativeNotices() async {
  final value = jsonDecode(
    await rootBundle.loadString('assets/licenses/native_notices.json'),
  ) as Map;
  return (value['entries'] as List)
      .map((item) => Map<String, dynamic>.from(item as Map))
      .toList();
}
