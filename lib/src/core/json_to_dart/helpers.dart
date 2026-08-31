import 'dart:convert' as convert;

import 'syntax.dart';

Map<String, bool> PRIMITIVE_TYPES = {
  'int': true,
  'double': true,
  'String': true,
  'bool': true,
  'dynamic': true,
  'DateTime': false,
  'List<DateTime>': false,
  'List<int>': true,
  'List<double>': true,
  'List<String>': true,
  'List<bool>': true,
  'List<dynamic>': true,
  'Null': true,
};

enum ListType { Object, String, Double, Int, Bool, Null }

class MergeableListType {
  final ListType listType;
  final bool isAmbigous;

  MergeableListType(this.listType, this.isAmbigous);
}

MergeableListType mergeableListType(List<dynamic> list) {
  ListType t = ListType.Null;
  bool isAmbigous = false;
  for (var e in list) {
    ListType? inferredType = getInferredType(e);
    if (t != ListType.Null && t != inferredType) {
      isAmbigous = true;
    }
    t = inferredType ?? ListType.Null;
  }
  return MergeableListType(t, isAmbigous);
}

ListType? getInferredType(dynamic d) {
  // `is` rather than `runtimeType ==`: the latter misses platform-specific
  // subtypes (e.g. _Double, _OneByteString) and so silently returned null.
  if (d is int) {
    return ListType.Int;
  } else if (d is double) {
    return ListType.Double;
  } else if (d is String) {
    return ListType.String;
  } else if (d is bool) {
    return ListType.Bool;
  } else if (d is Map) {
    return ListType.Object;
  }
  return null;
}

String camelCase(String text) {
  String capitalize(Match m) =>
      m[0]!.substring(0, 1).toUpperCase() + m[0]!.substring(1);
  String skip(String s) => "";
  return text.splitMapJoin(RegExp(r'[a-zA-Z0-9]+'),
      onMatch: capitalize, onNonMatch: skip);
}

String camelCaseFirstLower(String text) {
  final camelCaseText = camelCase(text);
  final firstChar = camelCaseText.substring(0, 1).toLowerCase();
  final rest = camelCaseText.substring(1);
  return '$firstChar$rest';
}

decodeJSON(String rawJson) {
  return convert.json.decode(rawJson);
}

WithWarning<Map> mergeObj(Map obj, Map other, String path) {
  List<Warning> warnings = <Warning>[];
  final Map clone = Map.from(obj);
  other.forEach((k, v) {
    if (clone[k] == null) {
      clone[k] = v;
    } else {
      final String otherType = getTypeName(v);
      final String t = getTypeName(clone[k]);
      if (t != otherType) {
        if (t == 'int' && otherType == 'double') {
          clone[k] = v;
        } else if (!(t == 'double' && otherType == 'int')) {
          // The mirror of the widening above: double-then-int is still a
          // number, not an ambiguous type. This compared a Type to a String
          // and so was always true, warning on that benign pair too.
          warnings.add(newAmbiguousType('$path/$k'));
        }
      } else if (t == 'List') {
        List l = List.from(clone[k]);
        l.addAll(other[k]);
        final mergeableType = mergeableListType(l);
        if (ListType.Object == mergeableType.listType) {
          WithWarning<Map> mergedList = mergeObjectList(l, path);
          warnings.addAll(mergedList.warnings);
          clone[k] = List.filled(1, mergedList.result);
        } else {
          if (l.isNotEmpty) {
            clone[k] = List.filled(1, l[0]);
          }
          if (mergeableType.isAmbigous) {
            warnings.add(newAmbiguousType('$path/$k'));
          }
        }
      } else if (t == 'Class') {
        WithWarning<Map> mergedObj = mergeObj(clone[k], other[k], '$path/$k');
        warnings.addAll(mergedObj.warnings);
        clone[k] = mergedObj.result;
      }
    }
  });
  return WithWarning(clone, warnings);
}

WithWarning<Map> mergeObjectList(List<dynamic> list, String path,
    [int idx = -1]) {
  List<Warning> warnings = <Warning>[];
  Map obj = {};
  for (var i = 0; i < list.length; i++) {
    final toMerge = list[i];
    if (toMerge is Map) {
      toMerge.forEach((k, v) {
        final String t = getTypeName(obj[k]);
        if (obj[k] == null) {
          obj[k] = v;
        } else {
          final String otherType = getTypeName(v);
          if (t != otherType) {
            if (t == 'int' && otherType == 'double') {
              obj[k] = v;
            } else if (!(t == 'double' && otherType == 'int')) {
              // Mirror of the guard in mergeObj: only the double/int widening
              // is benign. The old `t != 'double' && otherType != 'int'` also
              // swallowed genuine mismatches such as String vs int.
              int realIndex = i;
              if (idx != -1) {
                realIndex = idx - i;
              }
              final String ambiguosTypePath = '$path[$realIndex]/$k';
              warnings.add(newAmbiguousType(ambiguosTypePath));
            }
          } else if (t == 'List') {
            List l = List.from(obj[k]);
            final int beginIndex = l.length;
            l.addAll(v);
            final mergeableType = mergeableListType(l);
            if (ListType.Object == mergeableType.listType) {
              WithWarning<Map> mergedList =
                  mergeObjectList(l, '$path[$i]/$k', beginIndex);
              warnings.addAll(mergedList.warnings);
              obj[k] = List.filled(1, mergedList.result);
            } else {
              if (l.isNotEmpty) {
                obj[k] = List.filled(1, l[0]);
              }
              if (mergeableType.isAmbigous) {
                warnings.add(newAmbiguousType('$path[$i]/$k'));
              }
            }
          } else if (t == 'Class') {
            int properIndex = i;
            if (idx != -1) {
              properIndex = i - idx;
            }
            WithWarning<Map> mergedObj = mergeObj(
              obj[k],
              v,
              '$path[$properIndex]/$k',
            );
            warnings.addAll(mergedObj.warnings);
            obj[k] = mergedObj.result;
          }
        }
      });
    }
  }
  return WithWarning(obj, warnings);
}

isPrimitiveType(String typeName) {
  final isPrimitive = PRIMITIVE_TYPES[typeName];
  if (isPrimitive == null) {
    return false;
  }
  return isPrimitive;
}

String fixFieldName(String name,
    {required TypeDefinition typeDef, bool privateField = false}) {
  var properName = name;
  if (name.startsWith('_') || name.startsWith(RegExp(r'[0-9]'))) {
    final firstCharType = typeDef.name.substring(0, 1).toLowerCase();
    properName = '$firstCharType$name';
  }
  final fieldName = camelCaseFirstLower(properName);
  if (privateField) {
    return '_$fieldName';
  }
  return fieldName;
}

String getTypeName(dynamic obj) {
  if (obj is String) {
    return 'String';
  } else if (obj is int) {
    return 'int';
  } else if (obj is double) {
    return 'double';
  } else if (obj is bool) {
    return 'bool';
  } else if (obj == null) {
    return 'Null';
  } else if (obj is List) {
    return 'List';
  } else {
    return 'Class';
  }
}
