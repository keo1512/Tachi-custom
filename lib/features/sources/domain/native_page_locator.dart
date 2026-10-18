import 'catalogue.dart';

/// Reserved metadata for a page that the on-device extension resolves lazily.
/// It must never be sent to DNS or treated as a directly downloadable image.
bool isNativePageLocator(String value) {
  final host = Uri.tryParse(value)?.host.toLowerCase();
  return host == 'page.tachibooks.invalid' ||
      host == 'page.tachibooks.invalid.';
}

const nativePageRuntimeRequiredError = ApiException(
  'Trang này cần engine nguồn chạy trực tiếp trên thiết bị. '
  'Hãy dùng engine trên thiết bị và mở lại chương.',
  code: 'NATIVE_PAGE_RUNTIME_REQUIRED',
);

void rejectNativePageHttpFallback(String value) {
  if (isNativePageLocator(value)) throw nativePageRuntimeRequiredError;
}
