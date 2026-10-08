import 'library_repository.dart';

/// Browser preview uses its bounded local store and never imports native Isar schemas.
Future<LibraryRepository> openLibrary({String? directoryPath}) =>
    LibraryRepository.openWebPreview();
