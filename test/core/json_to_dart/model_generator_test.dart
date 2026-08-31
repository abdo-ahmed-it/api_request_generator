import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  String generate(String json, [String className = 'SampleResponse']) =>
      ModelGenerator(className).generateDartClasses(json).code;

  group('ModelGenerator field types', () {
    test('infers scalar types and makes them nullable', () {
      final code = generate('{"id":1,"name":"Ali","score":9.5,"active":true}');

      expect(code, contains('int? id;'));
      expect(code, contains('String? name;'));
      expect(code, contains('double? score;'));
      expect(code, contains('bool? active;'));
    });

    test('generates a nested class for an object field', () {
      final code = generate('{"meta":{"city":"Cairo"}}');

      expect(code, contains('Meta? meta;'));
      expect(code, contains('class Meta {'));
      expect(code, contains('String? city;'));
    });

    test('types a homogeneous primitive list by its element type', () {
      final code = generate('{"tags":[true,false],"nums":[1,2]}');

      expect(code, contains('List<bool>? tags;'));
      expect(code, contains('List<int>? nums;'));
    });

    test('widens a heterogeneous list to dynamic', () {
      // Keeping the first element's type emitted `List<int>` for [1,"two"],
      // whose generated `.cast<int>()` threw at runtime.
      final code = generate('{"mixed":[1,"two"]}');

      expect(code, contains('List<dynamic>? mixed;'));
      expect(code, isNot(contains('List<int>? mixed;')));
      expect(code, isNot(contains('cast<int>()')));
    });

    test('falls back to dynamic for an empty list', () {
      final code = generate('{"empty":[]}');

      expect(code, contains('List<dynamic>? empty;'));
    });
  });

  group('ModelGenerator null safety in fromJson', () {
    test('guards a primitive list before casting', () {
      // Primitive lists were the only field type generated without a null
      // guard, so an absent key threw NoSuchMethodError on .cast().
      final code = generate('{"tags":[true]}');

      expect(code, contains("json['tags'] != null"));
      expect(code, isNot(contains("tags = json['tags'].cast<bool>();")));
    });

    test('guards every nullable assignment in fromJson', () {
      final code = generate('{"tags":[1],"meta":{"a":1},"objs":[{"b":2}]}');

      // No bare `.cast(` or `.forEach(` directly off a json lookup.
      final unguarded = RegExp(r"= json\['\w+'\]\.(cast|forEach|map)\(");
      expect(unguarded.hasMatch(code), isFalse,
          reason: 'found an unguarded dereference in:\n$code');
    });
  });

  group('ModelGenerator structure', () {
    test('emits fromJson and toJson for every class', () {
      final code = generate('{"meta":{"city":"Cairo"}}');

      expect(
          code, contains('SampleResponse.fromJson(Map<String, dynamic> json)'));
      expect(code, contains('Map<String, dynamic> toJson()'));
      expect(code, contains('Meta.fromJson(Map<String, dynamic> json)'));
    });

    test('names the root class as requested', () {
      final code = generate('{"id":1}', 'UserResponse');

      expect(code, contains('class UserResponse {'));
    });
  });
}
