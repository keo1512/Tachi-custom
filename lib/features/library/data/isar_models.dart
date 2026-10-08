import 'package:isar_community/isar.dart';
part 'isar_models.g.dart';

@collection
class LibraryRecord {
  Id id = Isar.autoIncrement;
  @Index(unique: true, replace: true)
  late String bookId;
  late String payload;
}

@collection
class ChapterRecord {
  Id id = Isar.autoIncrement;
  @Index(unique: true, replace: true)
  late String chapterKey;
  @Index()
  late String bookId;
  late int chapterIndex;
  late String kind;
  late String html;
  late String imagesJson;
  late String headersJson;
}
