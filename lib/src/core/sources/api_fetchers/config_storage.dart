import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

/// Manages stored API keys and config in .api2dart/config.yaml (project root).
class ConfigStorage {
  // Resolved on every access, not cached in a `static final`: those are
  // initialized once on first use and would freeze onto whatever the CWD
  // happened to be then, so any later `Directory.current` change would keep
  // reading and writing the original project's config.
  static String get _configDir => p.join(Directory.current.path, '.api2dart');
  static String get _configPath => p.join(_configDir, 'config.yaml');

  /// Gets a stored value by key path (e.g. 'postman.api_key').
  static String? get(String key) {
    final config = _readConfig();
    final parts = key.split('.');
    dynamic current = config;
    for (final part in parts) {
      if (current is Map && current.containsKey(part)) {
        current = current[part];
      } else {
        return null;
      }
    }
    return current?.toString();
  }

  /// Sets a value by key path (e.g. 'postman.api_key', 'my-token').
  static void set(String key, String value) {
    final config = _readConfig();
    final parts = key.split('.');

    Map<String, dynamic> current = config;
    for (int i = 0; i < parts.length - 1; i++) {
      current.putIfAbsent(parts[i], () => <String, dynamic>{});
      final next = current[parts[i]];
      if (next is Map<String, dynamic>) {
        current = next;
      } else {
        current[parts[i]] = <String, dynamic>{};
        current = current[parts[i]] as Map<String, dynamic>;
      }
    }
    current[parts.last] = value;

    _writeConfig(config);
  }

  /// Remove a key (and all its children if it's a section).
  static void remove(String key) {
    final config = _readConfig();
    final parts = key.split('.');

    if (parts.length == 1) {
      config.remove(parts[0]);
    } else {
      Map<String, dynamic> current = config;
      for (int i = 0; i < parts.length - 1; i++) {
        final next = current[parts[i]];
        if (next is Map<String, dynamic>) {
          current = next;
        } else {
          return; // path doesn't exist
        }
      }
      current.remove(parts.last);
    }

    _writeConfig(config);
  }

  /// Check if a key exists.
  static bool has(String key) => get(key) != null;

  static Map<String, dynamic> _readConfig() {
    final file = File(_configPath);
    if (!file.existsSync()) return {};

    final content = file.readAsStringSync();
    try {
      final yaml = loadYaml(content);
      if (yaml is YamlMap) {
        return _yamlToMap(yaml);
      }
    } catch (_) {
      // The file exists but won't parse (e.g. corrupted by an older version).
      // Don't silently treat it as empty — that would let the next write wipe
      // real data (tokens, etc). Preserve the bad file as a `.bak` and start
      // fresh, so the user can recover their values if needed.
      if (content.trim().isNotEmpty) {
        try {
          File('$_configPath.bak').writeAsStringSync(content);
        } catch (_) {/* best-effort */}
      }
    }
    return {};
  }

  static void _writeConfig(Map<String, dynamic> config) {
    Directory(_configDir).createSync(recursive: true);
    final sb = StringBuffer();
    _writeYaml(sb, config, 0);
    File(_configPath).writeAsStringSync(sb.toString());
  }

  static void _writeYaml(
      StringBuffer sb, Map<String, dynamic> map, int indent) {
    final prefix = '  ' * indent;
    map.forEach((key, value) {
      if (value is Map<String, dynamic>) {
        sb.writeln('$prefix$key:');
        _writeYaml(sb, value, indent + 1);
      } else {
        sb.writeln('$prefix$key: ${_quote(value.toString())}');
      }
    });
  }

  /// Emits a YAML double-quoted scalar with proper escaping, so values
  /// containing quotes/backslashes/newlines (e.g. a JSON blob) round-trip
  /// safely instead of corrupting the file.
  static String _quote(String value) {
    final escaped = value
        .replaceAll('\\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t');
    return '"$escaped"';
  }

  static Map<String, dynamic> _yamlToMap(YamlMap yamlMap) {
    final map = <String, dynamic>{};
    for (final entry in yamlMap.entries) {
      if (entry.value is YamlMap) {
        map[entry.key.toString()] = _yamlToMap(entry.value as YamlMap);
      } else {
        map[entry.key.toString()] = entry.value;
      }
    }
    return map;
  }
}
