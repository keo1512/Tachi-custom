import 'library_book.dart';
import 'library_reading.dart';
export 'library_reading.dart' show readChapterCount;

typedef _Predicate = bool Function(LibraryBook);

/// Mihon-style boolean metadata queries, using only fields the library stores.
class LibrarySearch {
  LibrarySearch(String query) {
    if (query.length > 4096) {
      _match = (_) => false;
      return;
    }
    final parser = _Parser(query);
    _match = parser.or();
  }
  late final _Predicate _match;
  bool matches(LibraryBook book) => _match(book);
}

class _Parser {
  _Parser(String input) : tokens = _tokenize(input);
  final List<String> tokens;
  int position = 0;
  String? get peek => position < tokens.length ? tokens[position] : null;
  String take() => tokens[position++];

  _Predicate or([int depth = 0]) {
    final children = <_Predicate>[and(depth)];
    while (peek == '||') {
      take();
      children.add(and(depth));
    }
    return (book) => children.any((match) => match(book));
  }

  _Predicate and(int depth) {
    final children = <_Predicate>[];
    while (peek != null && peek != '||' && peek != ')') {
      if (peek == '&&') {
        take();
      } else {
        children.add(term(depth));
      }
    }
    return (book) => children.every((match) => match(book));
  }

  _Predicate term(int depth) {
    var negate = false;
    while (peek == '-') {
      take();
      negate = !negate;
    }
    late _Predicate match;
    if (peek == '(') {
      take();
      if (depth > 64) {
        position = tokens.length;
        return (_) => false;
      }
      match = or(depth + 1);
      if (peek == ')') take();
    } else {
      match = _atom(peek == null ? '' : take());
    }
    return negate ? (book) => !match(book) : match;
  }
}

List<String> _tokenize(String query) {
  final tokens = <String>[];
  var index = 0;
  while (index < query.length) {
    final char = query[index];
    if (RegExp(r'[\s,]').hasMatch(char)) {
      index++;
      continue;
    }
    if (char == '(' ||
        char == ')' ||
        (char == '-' &&
            index + 1 < query.length &&
            !RegExp(r'[\s,]').hasMatch(query[index + 1]))) {
      tokens.add(char);
      index++;
      continue;
    }
    final pair = index + 1 < query.length
        ? query.substring(index, index + 2)
        : '';
    if (pair == '&&' || pair == '||') {
      tokens.add(pair);
      index += 2;
      continue;
    }
    final value = StringBuffer();
    String? quote;
    while (index < query.length) {
      final current = query[index];
      if (quote != null) {
        if (current == quote) {
          quote = null;
        } else {
          value.write(current);
        }
      } else if (current == '"' || current == "'") {
        quote = current;
      } else if (RegExp(r'[\s,()]').hasMatch(current) ||
          query.startsWith('&&', index) ||
          query.startsWith('||', index)) {
        break;
      } else {
        value.write(current);
      }
      index++;
    }
    tokens.add(value.toString());
  }
  return tokens;
}

_Predicate _atom(String value) {
  final compare = RegExp(
    r'^(read|unread|total)(>=|<=|=|>|<)(\d+)$',
    caseSensitive: false,
  ).firstMatch(value);
  if (compare != null) {
    final count = BigInt.parse(compare[3]!);
    return (book) {
      final read = readChapterCount(book);
      final actual = BigInt.from(switch (compare[1]!.toLowerCase()) {
        'read' => read,
        'unread' => book.chapters.length - read,
        _ => book.chapters.length,
      });
      return switch (compare[2]) {
        '>=' => actual >= count,
        '<=' => actual <= count,
        '>' => actual > count,
        '<' => actual < count,
        _ => actual == count,
      };
    };
  }
  final colon = value.indexOf(':');
  if (colon > 0) {
    final field = value.substring(0, colon).toLowerCase(),
        input = value.substring(colon + 1).toLowerCase();
    if (['source_id', 'sourceid', 'src_id', 'srcid'].contains(field)) {
      return (book) =>
          BigInt.tryParse(input) != null &&
          BigInt.tryParse(book.sourceId) == BigInt.tryParse(input);
    }
    if ([
      'title',
      'author',
      'artist',
      'description',
      'desc',
      'genre',
      'tag',
      'notes',
      'note',
      'source',
      'src',
      'series',
      'collection',
    ].contains(field)) {
      return (book) {
        final texts = switch (field) {
          'title' => [book.title],
          'author' => [book.author],
          'artist' => [book.artist],
          'description' || 'desc' => [book.description],
          'notes' || 'note' => [book.notes],
          'genre' || 'tag' => book.genres,
          'source' || 'src' => [book.engine],
          'series' => [book.series],
          _ => [book.collection],
        };
        if (input.isEmpty) {
          return texts.isEmpty || texts.every((text) => text.isEmpty);
        }
        return texts.any((text) => text.toLowerCase().contains(input));
      };
    }
  }
  final text = value.toLowerCase();
  return (book) => [
    book.title,
    book.author,
    book.artist,
    book.description,
    book.notes,
    book.engine,
    book.series,
    book.collection,
    ...book.genres,
  ].any((field) => field.toLowerCase().contains(text));
}
