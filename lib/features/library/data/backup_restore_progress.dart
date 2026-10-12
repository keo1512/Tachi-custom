/// Preparation is cancellable. The final library/configuration commit remains
/// atomic and cannot be interrupted halfway through.
enum BackupRestoreStage {
  validating,
  readingCurrent,
  preparing,
  committing,
  completed,
}

class BackupRestoreProgress {
  const BackupRestoreProgress(
    this.stage, {
    this.completedBooks = 0,
    this.totalBooks = 0,
  });
  final BackupRestoreStage stage;
  final int completedBooks, totalBooks;
  bool get canCancel => stage.index < BackupRestoreStage.committing.index;
  double? get fraction => totalBooks == 0 ? null : completedBooks / totalBooks;
  String get label => switch (stage) {
    BackupRestoreStage.validating => 'Kiểm tra bản sao lưu',
    BackupRestoreStage.readingCurrent => 'Đối chiếu thư viện hiện tại',
    BackupRestoreStage.preparing =>
      'Chuẩn bị $completedBooks / $totalBooks truyện',
    BackupRestoreStage.committing => 'Lưu thư viện và bản phục hồi',
    BackupRestoreStage.completed => 'Khôi phục hoàn tất',
  };
}

class BackupRestoreCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const BackupRestoreCancelled();
  }
}

class BackupRestoreCancelled implements Exception {
  const BackupRestoreCancelled();
  @override
  String toString() => 'Đã hủy khôi phục trước khi thay đổi thư viện.';
}
