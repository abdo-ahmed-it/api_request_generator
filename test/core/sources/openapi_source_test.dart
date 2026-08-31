import 'dart:io';

import 'package:api_to_dart/api_to_dart.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() => tempDir = Directory.systemTemp.createTempSync('api2dart_oas'));
  tearDown(() => tempDir.deleteSync(recursive: true));

  Future<EndpointTree> parse(String spec) async {
    final file = File('${tempDir.path}/spec.yaml')..writeAsStringSync(spec);
    return OpenApiSource().parse(ApiSourceConfig(filePath: file.path));
  }

  /// Builds a spec whose response schema nests [levels] deep and ends in a
  /// `$ref` to a component. Deep nesting is what a depth cap truncates.
  String deeplyNestedSpec(int levels) {
    final buffer = StringBuffer('''
openapi: 3.0.0
info: {title: Deep, version: "1.0"}
paths:
  /deep:
    get:
      responses:
        '200':
          content:
            application/json:
              schema:
                type: object
                properties:
''');
    var indent = '                  ';
    for (var i = 0; i < levels; i++) {
      buffer.writeln('${indent}level$i:');
      buffer.writeln('$indent  type: object');
      buffer.writeln('$indent  properties:');
      indent = '$indent    ';
    }
    buffer.writeln('${indent}leaf:');
    buffer.writeln('$indent  \$ref: "#/components/schemas/Leaf"');
    buffer.write('''
components:
  schemas:
    Leaf:
      type: object
      properties:
        leafField: {type: string, example: "found"}
''');
    return buffer.toString();
  }

  group('OpenApiSource \$ref resolution', () {
    test('resolves a top-level ref into the response schema', () async {
      final tree = await parse('''
openapi: 3.0.0
info: {title: Ref, version: "1.0"}
paths:
  /user:
    get:
      responses:
        '200':
          content:
            application/json:
              schema: {\$ref: "#/components/schemas/User"}
components:
  schemas:
    User:
      type: object
      properties:
        id: {type: integer, example: 1}
        name: {type: string, example: "Ali"}
''');

      final endpoint = tree.allEndpoints.single;
      expect(endpoint.response?.jsonBody, contains('name'));
      expect(endpoint.response?.jsonBody, contains('Ali'));
    });

    test('resolves a ref nested several levels inside a schema', () async {
      // A depth cap on _resolveRef counted structural descent (two units per
      // nesting level), so refs stopped resolving at ~8 levels of objects and
      // the field silently lost its shape. It was reverted: a matched $ref
      // returns verbatim without recursing, so no cycle is possible here.
      //
      // 4 levels stays inside the separate `depth > 5` guard in
      // _schemaToFullExample, which is a pre-existing limit on example
      // synthesis and not what this test is about.
      final tree = await parse(deeplyNestedSpec(4));

      final jsonBody = tree.allEndpoints.single.response?.jsonBody;
      expect(jsonBody, isNotNull);
      expect(jsonBody, contains('leafField'),
          reason: 'nested \$ref was left unresolved:\n$jsonBody');
      expect(jsonBody, isNot(contains(r'$ref')));
    });

    test('a self-referential schema terminates instead of overflowing',
        () async {
      final tree = await parse('''
openapi: 3.0.0
info: {title: Cycle, version: "1.0"}
paths:
  /node:
    get:
      responses:
        '200':
          content:
            application/json:
              schema: {\$ref: "#/components/schemas/Node"}
components:
  schemas:
    Node:
      type: object
      properties:
        name: {type: string, example: "root"}
        child: {\$ref: "#/components/schemas/Node"}
''');

      // A matched ref is returned verbatim without recursing, so this cannot
      // loop; the example synthesiser has its own depth guard.
      expect(tree.allEndpoints, hasLength(1));
    });

    test('leaves an unsupported ref form in place rather than failing',
        () async {
      final tree = await parse('''
openapi: 3.0.0
info: {title: Legacy, version: "1.0"}
paths:
  /a:
    get:
      responses:
        '200':
          content:
            application/json:
              schema: {\$ref: "#/definitions/Legacy"}
definitions:
  Legacy:
    type: object
    properties: {id: {type: integer}}
''');

      // Only `#/components/schemas/` is supported; the endpoint still parses.
      expect(tree.allEndpoints, hasLength(1));
      expect(tree.allEndpoints.single.path, '/a');
    });
  });
}
