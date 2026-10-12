import 'dart:convert';

import 'catalogue.dart';

enum SourceFilterType {
  header,
  separator,
  text,
  checkbox,
  tristate,
  select,
  sort,
  group,
  unsupported,
}

class SourceFilterNode {
  const SourceFilterNode({
    required this.name,
    required this.type,
    this.state,
    this.values = const [],
    this.children = const [],
    this.className = '',
  });
  final String name, className;
  final SourceFilterType type;
  final Object? state;
  final List<String> values;
  final List<SourceFilterNode> children;

  static const _keep = Object();
  SourceFilterNode copyWith({
    Object? state = _keep,
    List<SourceFilterNode>? children,
  }) => SourceFilterNode(
    name: name,
    type: type,
    state: identical(state, _keep) ? this.state : state,
    values: values,
    children: children ?? this.children,
    className: className,
  );

  static SourceFilterNode fromJson(
    Map<String, dynamic> json,
    int depth,
    List<int> count,
  ) {
    if (depth > 8 || ++count[0] > 2048 || json['name'] is! String) {
      throw const ApiException(
        'Bộ lọc của nguồn vượt giới hạn hoặc không hợp lệ.',
      );
    }
    final type = SourceFilterType.values
        .where((t) => t.name == json['type'])
        .firstOrNull;
    if (type == null ||
        json['supported'] != (type != SourceFilterType.unsupported)) {
      throw const ApiException('Engine trả loại bộ lọc chưa được hỗ trợ.');
    }
    final options = json['values'];
    final values = options == null
        ? <String>[]
        : options is List &&
              options.length <= 1024 &&
              options.every((v) => v is String)
        ? options.cast<String>()
        : throw const ApiException('Lựa chọn bộ lọc không hợp lệ.');
    final childJson = json['children'];
    final children = childJson == null
        ? <SourceFilterNode>[]
        : childJson is List
        ? childJson
              .map(
                (child) => child is Map<String, dynamic>
                    ? fromJson(child, depth + 1, count)
                    : throw const ApiException('Nhóm bộ lọc không hợp lệ.'),
              )
              .toList()
        : throw const ApiException('Nhóm bộ lọc không hợp lệ.');
    final state = json['state'];
    final valid = switch (type) {
      SourceFilterType.text => state is String && state.length <= 8192,
      SourceFilterType.checkbox => state is bool,
      SourceFilterType.tristate => state is int && state >= 0 && state <= 2,
      SourceFilterType.select =>
        state is int && state >= 0 && state < values.length,
      SourceFilterType.sort =>
        state == null ||
            state is Map<String, dynamic> &&
                state['index'] is int &&
                state['index'] >= 0 &&
                state['index'] < values.length &&
                state['ascending'] is bool,
      _ => true,
    };
    if (!valid) {
      throw const ApiException(
        'Trạng thái bộ lọc không hợp lệ. Hãy tải lại bộ lọc.',
      );
    }
    return SourceFilterNode(
      name: json['name'] as String,
      type: type,
      state: state,
      values: List.unmodifiable(values),
      children: List.unmodifiable(children),
      className: json['className'] is String ? json['className'] as String : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.name,
    'supported': type != SourceFilterType.unsupported,
    if (type == SourceFilterType.select || type == SourceFilterType.sort)
      'values': values,
    if (type == SourceFilterType.group)
      'children': children.map((n) => n.toJson()).toList(),
    if (type == SourceFilterType.unsupported) 'className': className,
    if (![
      SourceFilterType.header,
      SourceFilterType.separator,
      SourceFilterType.group,
      SourceFilterType.unsupported,
    ].contains(type))
      'state': state,
  };
}

class SourceFilterSet {
  const SourceFilterSet({required this.schema, required this.filters});
  final String schema;
  final List<SourceFilterNode> filters;

  factory SourceFilterSet.fromJson(Map<String, dynamic> json) {
    if (json['schema'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(json['schema'] as String) ||
        json['filters'] is! List) {
      throw const ApiException('Engine trả bộ lọc không hợp lệ.');
    }
    final count = [0];
    return SourceFilterSet(
      schema: json['schema'] as String,
      filters: List.unmodifiable(
        (json['filters'] as List).map(
          (node) => node is Map<String, dynamic>
              ? SourceFilterNode.fromJson(node, 0, count)
              : throw const ApiException('Bộ lọc không hợp lệ.'),
        ),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'filters': filters.map((n) => n.toJson()).toList(),
  };
  SourceFilterSet clone() => SourceFilterSet.fromJson(
    jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
  );
}
