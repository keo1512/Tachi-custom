// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'isar_models.dart';

// **************************************************************************
// IsarCollectionGenerator
// **************************************************************************

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetLibraryRecordCollection on Isar {
  IsarCollection<LibraryRecord> get libraryRecords => this.collection();
}

const LibraryRecordSchema = CollectionSchema(
  name: r'LibraryRecord',
  id: 650076859638582379,
  properties: {
    r'bookId': PropertySchema(id: 0, name: r'bookId', type: IsarType.string),
    r'payload': PropertySchema(id: 1, name: r'payload', type: IsarType.string),
  },

  estimateSize: _libraryRecordEstimateSize,
  serialize: _libraryRecordSerialize,
  deserialize: _libraryRecordDeserialize,
  deserializeProp: _libraryRecordDeserializeProp,
  idName: r'id',
  indexes: {
    r'bookId': IndexSchema(
      id: 3567540928881766442,
      name: r'bookId',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'bookId',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _libraryRecordGetId,
  getLinks: _libraryRecordGetLinks,
  attach: _libraryRecordAttach,
  version: '3.3.2',
);

int _libraryRecordEstimateSize(
  LibraryRecord object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.bookId.length * 3;
  bytesCount += 3 + object.payload.length * 3;
  return bytesCount;
}

void _libraryRecordSerialize(
  LibraryRecord object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.bookId);
  writer.writeString(offsets[1], object.payload);
}

LibraryRecord _libraryRecordDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = LibraryRecord();
  object.bookId = reader.readString(offsets[0]);
  object.id = id;
  object.payload = reader.readString(offsets[1]);
  return object;
}

P _libraryRecordDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _libraryRecordGetId(LibraryRecord object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _libraryRecordGetLinks(LibraryRecord object) {
  return [];
}

void _libraryRecordAttach(
  IsarCollection<dynamic> col,
  Id id,
  LibraryRecord object,
) {
  object.id = id;
}

extension LibraryRecordByIndex on IsarCollection<LibraryRecord> {
  Future<LibraryRecord?> getByBookId(String bookId) {
    return getByIndex(r'bookId', [bookId]);
  }

  LibraryRecord? getByBookIdSync(String bookId) {
    return getByIndexSync(r'bookId', [bookId]);
  }

  Future<bool> deleteByBookId(String bookId) {
    return deleteByIndex(r'bookId', [bookId]);
  }

  bool deleteByBookIdSync(String bookId) {
    return deleteByIndexSync(r'bookId', [bookId]);
  }

  Future<List<LibraryRecord?>> getAllByBookId(List<String> bookIdValues) {
    final values = bookIdValues.map((e) => [e]).toList();
    return getAllByIndex(r'bookId', values);
  }

  List<LibraryRecord?> getAllByBookIdSync(List<String> bookIdValues) {
    final values = bookIdValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'bookId', values);
  }

  Future<int> deleteAllByBookId(List<String> bookIdValues) {
    final values = bookIdValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'bookId', values);
  }

  int deleteAllByBookIdSync(List<String> bookIdValues) {
    final values = bookIdValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'bookId', values);
  }

  Future<Id> putByBookId(LibraryRecord object) {
    return putByIndex(r'bookId', object);
  }

  Id putByBookIdSync(LibraryRecord object, {bool saveLinks = true}) {
    return putByIndexSync(r'bookId', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByBookId(List<LibraryRecord> objects) {
    return putAllByIndex(r'bookId', objects);
  }

  List<Id> putAllByBookIdSync(
    List<LibraryRecord> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'bookId', objects, saveLinks: saveLinks);
  }
}

extension LibraryRecordQueryWhereSort
    on QueryBuilder<LibraryRecord, LibraryRecord, QWhere> {
  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension LibraryRecordQueryWhere
    on QueryBuilder<LibraryRecord, LibraryRecord, QWhereClause> {
  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> idEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> idNotEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause> bookIdEqualTo(
    String bookId,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'bookId', value: [bookId]),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterWhereClause>
  bookIdNotEqualTo(String bookId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [],
                upper: [bookId],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [bookId],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [bookId],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [],
                upper: [bookId],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension LibraryRecordQueryFilter
    on QueryBuilder<LibraryRecord, LibraryRecord, QFilterCondition> {
  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bookId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'bookId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bookId', value: ''),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  bookIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'bookId', value: ''),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'payload',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'payload',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'payload',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'payload', value: ''),
      );
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterFilterCondition>
  payloadIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'payload', value: ''),
      );
    });
  }
}

extension LibraryRecordQueryObject
    on QueryBuilder<LibraryRecord, LibraryRecord, QFilterCondition> {}

extension LibraryRecordQueryLinks
    on QueryBuilder<LibraryRecord, LibraryRecord, QFilterCondition> {}

extension LibraryRecordQuerySortBy
    on QueryBuilder<LibraryRecord, LibraryRecord, QSortBy> {
  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> sortByBookId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.asc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> sortByBookIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.desc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> sortByPayload() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'payload', Sort.asc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> sortByPayloadDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'payload', Sort.desc);
    });
  }
}

extension LibraryRecordQuerySortThenBy
    on QueryBuilder<LibraryRecord, LibraryRecord, QSortThenBy> {
  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenByBookId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.asc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenByBookIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.desc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenByPayload() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'payload', Sort.asc);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QAfterSortBy> thenByPayloadDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'payload', Sort.desc);
    });
  }
}

extension LibraryRecordQueryWhereDistinct
    on QueryBuilder<LibraryRecord, LibraryRecord, QDistinct> {
  QueryBuilder<LibraryRecord, LibraryRecord, QDistinct> distinctByBookId({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bookId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<LibraryRecord, LibraryRecord, QDistinct> distinctByPayload({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'payload', caseSensitive: caseSensitive);
    });
  }
}

extension LibraryRecordQueryProperty
    on QueryBuilder<LibraryRecord, LibraryRecord, QQueryProperty> {
  QueryBuilder<LibraryRecord, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<LibraryRecord, String, QQueryOperations> bookIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bookId');
    });
  }

  QueryBuilder<LibraryRecord, String, QQueryOperations> payloadProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'payload');
    });
  }
}

// coverage:ignore-file
// ignore_for_file: duplicate_ignore, non_constant_identifier_names, constant_identifier_names, invalid_use_of_protected_member, unnecessary_cast, prefer_const_constructors, lines_longer_than_80_chars, require_trailing_commas, inference_failure_on_function_invocation, unnecessary_parenthesis, unnecessary_raw_strings, unnecessary_null_checks, join_return_with_assignment, prefer_final_locals, avoid_js_rounded_ints, avoid_positional_boolean_parameters, always_specify_types

extension GetChapterRecordCollection on Isar {
  IsarCollection<ChapterRecord> get chapterRecords => this.collection();
}

const ChapterRecordSchema = CollectionSchema(
  name: r'ChapterRecord',
  id: 4790732669122426389,
  properties: {
    r'bookId': PropertySchema(id: 0, name: r'bookId', type: IsarType.string),
    r'chapterIndex': PropertySchema(
      id: 1,
      name: r'chapterIndex',
      type: IsarType.long,
    ),
    r'chapterKey': PropertySchema(
      id: 2,
      name: r'chapterKey',
      type: IsarType.string,
    ),
    r'headersJson': PropertySchema(
      id: 3,
      name: r'headersJson',
      type: IsarType.string,
    ),
    r'html': PropertySchema(id: 4, name: r'html', type: IsarType.string),
    r'imagesJson': PropertySchema(
      id: 5,
      name: r'imagesJson',
      type: IsarType.string,
    ),
    r'kind': PropertySchema(id: 6, name: r'kind', type: IsarType.string),
  },

  estimateSize: _chapterRecordEstimateSize,
  serialize: _chapterRecordSerialize,
  deserialize: _chapterRecordDeserialize,
  deserializeProp: _chapterRecordDeserializeProp,
  idName: r'id',
  indexes: {
    r'chapterKey': IndexSchema(
      id: -4016351542418244567,
      name: r'chapterKey',
      unique: true,
      replace: true,
      properties: [
        IndexPropertySchema(
          name: r'chapterKey',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
    r'bookId': IndexSchema(
      id: 3567540928881766442,
      name: r'bookId',
      unique: false,
      replace: false,
      properties: [
        IndexPropertySchema(
          name: r'bookId',
          type: IndexType.hash,
          caseSensitive: true,
        ),
      ],
    ),
  },
  links: {},
  embeddedSchemas: {},

  getId: _chapterRecordGetId,
  getLinks: _chapterRecordGetLinks,
  attach: _chapterRecordAttach,
  version: '3.3.2',
);

int _chapterRecordEstimateSize(
  ChapterRecord object,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  var bytesCount = offsets.last;
  bytesCount += 3 + object.bookId.length * 3;
  bytesCount += 3 + object.chapterKey.length * 3;
  bytesCount += 3 + object.headersJson.length * 3;
  bytesCount += 3 + object.html.length * 3;
  bytesCount += 3 + object.imagesJson.length * 3;
  bytesCount += 3 + object.kind.length * 3;
  return bytesCount;
}

void _chapterRecordSerialize(
  ChapterRecord object,
  IsarWriter writer,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  writer.writeString(offsets[0], object.bookId);
  writer.writeLong(offsets[1], object.chapterIndex);
  writer.writeString(offsets[2], object.chapterKey);
  writer.writeString(offsets[3], object.headersJson);
  writer.writeString(offsets[4], object.html);
  writer.writeString(offsets[5], object.imagesJson);
  writer.writeString(offsets[6], object.kind);
}

ChapterRecord _chapterRecordDeserialize(
  Id id,
  IsarReader reader,
  List<int> offsets,
  Map<Type, List<int>> allOffsets,
) {
  final object = ChapterRecord();
  object.bookId = reader.readString(offsets[0]);
  object.chapterIndex = reader.readLong(offsets[1]);
  object.chapterKey = reader.readString(offsets[2]);
  object.headersJson = reader.readString(offsets[3]);
  object.html = reader.readString(offsets[4]);
  object.id = id;
  object.imagesJson = reader.readString(offsets[5]);
  object.kind = reader.readString(offsets[6]);
  return object;
}

P _chapterRecordDeserializeProp<P>(
  IsarReader reader,
  int propertyId,
  int offset,
  Map<Type, List<int>> allOffsets,
) {
  switch (propertyId) {
    case 0:
      return (reader.readString(offset)) as P;
    case 1:
      return (reader.readLong(offset)) as P;
    case 2:
      return (reader.readString(offset)) as P;
    case 3:
      return (reader.readString(offset)) as P;
    case 4:
      return (reader.readString(offset)) as P;
    case 5:
      return (reader.readString(offset)) as P;
    case 6:
      return (reader.readString(offset)) as P;
    default:
      throw IsarError('Unknown property with id $propertyId');
  }
}

Id _chapterRecordGetId(ChapterRecord object) {
  return object.id;
}

List<IsarLinkBase<dynamic>> _chapterRecordGetLinks(ChapterRecord object) {
  return [];
}

void _chapterRecordAttach(
  IsarCollection<dynamic> col,
  Id id,
  ChapterRecord object,
) {
  object.id = id;
}

extension ChapterRecordByIndex on IsarCollection<ChapterRecord> {
  Future<ChapterRecord?> getByChapterKey(String chapterKey) {
    return getByIndex(r'chapterKey', [chapterKey]);
  }

  ChapterRecord? getByChapterKeySync(String chapterKey) {
    return getByIndexSync(r'chapterKey', [chapterKey]);
  }

  Future<bool> deleteByChapterKey(String chapterKey) {
    return deleteByIndex(r'chapterKey', [chapterKey]);
  }

  bool deleteByChapterKeySync(String chapterKey) {
    return deleteByIndexSync(r'chapterKey', [chapterKey]);
  }

  Future<List<ChapterRecord?>> getAllByChapterKey(
    List<String> chapterKeyValues,
  ) {
    final values = chapterKeyValues.map((e) => [e]).toList();
    return getAllByIndex(r'chapterKey', values);
  }

  List<ChapterRecord?> getAllByChapterKeySync(List<String> chapterKeyValues) {
    final values = chapterKeyValues.map((e) => [e]).toList();
    return getAllByIndexSync(r'chapterKey', values);
  }

  Future<int> deleteAllByChapterKey(List<String> chapterKeyValues) {
    final values = chapterKeyValues.map((e) => [e]).toList();
    return deleteAllByIndex(r'chapterKey', values);
  }

  int deleteAllByChapterKeySync(List<String> chapterKeyValues) {
    final values = chapterKeyValues.map((e) => [e]).toList();
    return deleteAllByIndexSync(r'chapterKey', values);
  }

  Future<Id> putByChapterKey(ChapterRecord object) {
    return putByIndex(r'chapterKey', object);
  }

  Id putByChapterKeySync(ChapterRecord object, {bool saveLinks = true}) {
    return putByIndexSync(r'chapterKey', object, saveLinks: saveLinks);
  }

  Future<List<Id>> putAllByChapterKey(List<ChapterRecord> objects) {
    return putAllByIndex(r'chapterKey', objects);
  }

  List<Id> putAllByChapterKeySync(
    List<ChapterRecord> objects, {
    bool saveLinks = true,
  }) {
    return putAllByIndexSync(r'chapterKey', objects, saveLinks: saveLinks);
  }
}

extension ChapterRecordQueryWhereSort
    on QueryBuilder<ChapterRecord, ChapterRecord, QWhere> {
  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhere> anyId() {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(const IdWhereClause.any());
    });
  }
}

extension ChapterRecordQueryWhere
    on QueryBuilder<ChapterRecord, ChapterRecord, QWhereClause> {
  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> idEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(IdWhereClause.between(lower: id, upper: id));
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> idNotEqualTo(
    Id id,
  ) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            )
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            );
      } else {
        return query
            .addWhereClause(
              IdWhereClause.greaterThan(lower: id, includeLower: false),
            )
            .addWhereClause(
              IdWhereClause.lessThan(upper: id, includeUpper: false),
            );
      }
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> idGreaterThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.greaterThan(lower: id, includeLower: include),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> idLessThan(
    Id id, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.lessThan(upper: id, includeUpper: include),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> idBetween(
    Id lowerId,
    Id upperId, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IdWhereClause.between(
          lower: lowerId,
          includeLower: includeLower,
          upper: upperId,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause>
  chapterKeyEqualTo(String chapterKey) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'chapterKey', value: [chapterKey]),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause>
  chapterKeyNotEqualTo(String chapterKey) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'chapterKey',
                lower: [],
                upper: [chapterKey],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'chapterKey',
                lower: [chapterKey],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'chapterKey',
                lower: [chapterKey],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'chapterKey',
                lower: [],
                upper: [chapterKey],
                includeUpper: false,
              ),
            );
      }
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause> bookIdEqualTo(
    String bookId,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addWhereClause(
        IndexWhereClause.equalTo(indexName: r'bookId', value: [bookId]),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterWhereClause>
  bookIdNotEqualTo(String bookId) {
    return QueryBuilder.apply(this, (query) {
      if (query.whereSort == Sort.asc) {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [],
                upper: [bookId],
                includeUpper: false,
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [bookId],
                includeLower: false,
                upper: [],
              ),
            );
      } else {
        return query
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [bookId],
                includeLower: false,
                upper: [],
              ),
            )
            .addWhereClause(
              IndexWhereClause.between(
                indexName: r'bookId',
                lower: [],
                upper: [bookId],
                includeUpper: false,
              ),
            );
      }
    });
  }
}

extension ChapterRecordQueryFilter
    on QueryBuilder<ChapterRecord, ChapterRecord, QFilterCondition> {
  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'bookId',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'bookId',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'bookId',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'bookId', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  bookIdIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'bookId', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterIndexEqualTo(int value) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chapterIndex', value: value),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterIndexGreaterThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chapterIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterIndexLessThan(int value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chapterIndex',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterIndexBetween(
    int lower,
    int upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chapterIndex',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'chapterKey',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'chapterKey',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'chapterKey',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'chapterKey', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  chapterKeyIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'chapterKey', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'headersJson',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'headersJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'headersJson',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'headersJson', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  headersJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'headersJson', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> htmlEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> htmlBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'html',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'html',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> htmlMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'html',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'html', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  htmlIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'html', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> idEqualTo(
    Id value,
  ) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'id', value: value),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  idGreaterThan(Id value, {bool include = false}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> idLessThan(
    Id value, {
    bool include = false,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'id',
          value: value,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> idBetween(
    Id lower,
    Id upper, {
    bool includeLower = true,
    bool includeUpper = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'id',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonEqualTo(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'imagesJson',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'imagesJson',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonMatches(String pattern, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'imagesJson',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'imagesJson', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  imagesJsonIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'imagesJson', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> kindEqualTo(
    String value, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindGreaterThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(
          include: include,
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindLessThan(
    String value, {
    bool include = false,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.lessThan(
          include: include,
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> kindBetween(
    String lower,
    String upper, {
    bool includeLower = true,
    bool includeUpper = true,
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.between(
          property: r'kind',
          lower: lower,
          includeLower: includeLower,
          upper: upper,
          includeUpper: includeUpper,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindStartsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.startsWith(
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindEndsWith(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.endsWith(
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindContains(String value, {bool caseSensitive = true}) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.contains(
          property: r'kind',
          value: value,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition> kindMatches(
    String pattern, {
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.matches(
          property: r'kind',
          wildcard: pattern,
          caseSensitive: caseSensitive,
        ),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindIsEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.equalTo(property: r'kind', value: ''),
      );
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterFilterCondition>
  kindIsNotEmpty() {
    return QueryBuilder.apply(this, (query) {
      return query.addFilterCondition(
        FilterCondition.greaterThan(property: r'kind', value: ''),
      );
    });
  }
}

extension ChapterRecordQueryObject
    on QueryBuilder<ChapterRecord, ChapterRecord, QFilterCondition> {}

extension ChapterRecordQueryLinks
    on QueryBuilder<ChapterRecord, ChapterRecord, QFilterCondition> {}

extension ChapterRecordQuerySortBy
    on QueryBuilder<ChapterRecord, ChapterRecord, QSortBy> {
  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByBookId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByBookIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  sortByChapterIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterIndex', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  sortByChapterIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterIndex', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByChapterKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterKey', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  sortByChapterKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterKey', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByHeadersJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'headersJson', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  sortByHeadersJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'headersJson', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByHtml() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'html', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByHtmlDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'html', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByImagesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'imagesJson', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  sortByImagesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'imagesJson', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByKind() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kind', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> sortByKindDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kind', Sort.desc);
    });
  }
}

extension ChapterRecordQuerySortThenBy
    on QueryBuilder<ChapterRecord, ChapterRecord, QSortThenBy> {
  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByBookId() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByBookIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'bookId', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  thenByChapterIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterIndex', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  thenByChapterIndexDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterIndex', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByChapterKey() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterKey', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  thenByChapterKeyDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'chapterKey', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByHeadersJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'headersJson', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  thenByHeadersJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'headersJson', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByHtml() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'html', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByHtmlDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'html', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenById() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByIdDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'id', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByImagesJson() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'imagesJson', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy>
  thenByImagesJsonDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'imagesJson', Sort.desc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByKind() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kind', Sort.asc);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QAfterSortBy> thenByKindDesc() {
    return QueryBuilder.apply(this, (query) {
      return query.addSortBy(r'kind', Sort.desc);
    });
  }
}

extension ChapterRecordQueryWhereDistinct
    on QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> {
  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByBookId({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'bookId', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct>
  distinctByChapterIndex() {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chapterIndex');
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByChapterKey({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'chapterKey', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByHeadersJson({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'headersJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByHtml({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'html', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByImagesJson({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'imagesJson', caseSensitive: caseSensitive);
    });
  }

  QueryBuilder<ChapterRecord, ChapterRecord, QDistinct> distinctByKind({
    bool caseSensitive = true,
  }) {
    return QueryBuilder.apply(this, (query) {
      return query.addDistinctBy(r'kind', caseSensitive: caseSensitive);
    });
  }
}

extension ChapterRecordQueryProperty
    on QueryBuilder<ChapterRecord, ChapterRecord, QQueryProperty> {
  QueryBuilder<ChapterRecord, int, QQueryOperations> idProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'id');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> bookIdProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'bookId');
    });
  }

  QueryBuilder<ChapterRecord, int, QQueryOperations> chapterIndexProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chapterIndex');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> chapterKeyProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'chapterKey');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> headersJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'headersJson');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> htmlProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'html');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> imagesJsonProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'imagesJson');
    });
  }

  QueryBuilder<ChapterRecord, String, QQueryOperations> kindProperty() {
    return QueryBuilder.apply(this, (query) {
      return query.addPropertyName(r'kind');
    });
  }
}
