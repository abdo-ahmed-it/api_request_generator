import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'version.dart';

/// Checks pub.dev for a newer version of the CLI.
///
/// Caches the latest known version in `~/.api2dart/update_check.json` and
/// only hits the network once per [cacheTtl] (default: 1 day).
class UpdateChecker {
  static const Duration cacheTtl = Duration(days: 1);
  static const Duration networkTimeout = Duration(seconds: 3);

  static String get _cacheDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        Directory.systemTemp.path;
    return p.join(home, '.api2dart');
  }

  static String get _cachePath => p.join(_cacheDir, 'update_check.json');

  /// Fetches the latest version, using the cache when fresh.
  ///
  /// Returns `null` if the lookup fails (offline, timeout, etc.) so callers
  /// can silently skip showing an update message.
  static Future<String?> fetchLatestVersion({bool force = false}) async {
    if (!force) {
      final cached = _readCache();
      if (cached != null) return cached;
    }

    try {
      final response = await http.get(
        Uri.parse('https://pub.dev/api/packages/$packageName'),
        headers: {'Accept': 'application/json'},
      ).timeout(networkTimeout);

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latest = data['latest'] as Map<String, dynamic>?;
      final version = latest?['version'] as String?;
      if (version == null) return null;

      _writeCache(version);
      return version;
    } catch (_) {
      return null;
    }
  }

  /// Compares two semver strings. Returns true if [latest] > [current].
  /// A pre-release (`0.7.0-beta`) sorts below the matching release (`0.7.0`).
  ///
  /// Returns false when [current] is the `0.0.0` sentinel that
  /// `packageVersion` falls back to when the bundled pubspec can't be located,
  /// and when it can't be read as a version at all — every real release
  /// compares newer than those, which would show a permanent bogus
  /// "update available" notice. A nag we can't justify is worse than silence.
  static bool isNewer(String current, String latest) {
    // Both sides must be readable. A malformed pub.dev response such as "1"
    // otherwise parsed to [1,0,0] and announced a bogus upgrade to version 1.
    if (!_isParseableVersion(current)) return false;
    if (!_isParseableVersion(latest)) return false;

    if (_versionCore(current) == '0.0.0') return false;

    final c = _parseVersion(current);
    final l = _parseVersion(latest);
    for (var i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }

    // Numerically equal: a pre-release current is older than a plain latest.
    return _isPreRelease(current) && !_isPreRelease(latest);
  }

  /// True when a version carries a `-suffix` pre-release tag.
  static bool _isPreRelease(String version) =>
      version.split('+').first.contains('-');

  /// Strips pre-release/build suffixes and a conventional leading `v`.
  ///
  /// `v0.7.0` is a tag spelling, not a malformed version — treating it as
  /// unreadable silenced its update notice permanently.
  static String _versionCore(String version) {
    final core = version.split('-').first.split('+').first.trim();
    return core.startsWith('v') || core.startsWith('V')
        ? core.substring(1)
        : core;
  }

  /// True when [version] reads as `major.minor[.patch...]` with numeric parts.
  ///
  /// `_parseVersion` maps anything else to `[0,0,0]`, which would otherwise be
  /// indistinguishable from a real `0.0.0` and compare older than every
  /// release.
  ///
  /// Only the first three parts are compared, but a fourth is not a reason to
  /// call the version unreadable: rejecting `1.2.3.4` reintroduced exactly the
  /// permanent-silence failure this guard exists to prevent.
  static bool _isParseableVersion(String version) {
    final core = _versionCore(version);
    if (core.isEmpty) return false;
    final parts = core.split('.');
    if (parts.length < 2) return false;
    return parts.every((p) => p.isNotEmpty && int.tryParse(p) != null);
  }

  static List<int> _parseVersion(String version) {
    final parts = _versionCore(version).split('.');
    final result = <int>[0, 0, 0];
    for (var i = 0; i < 3 && i < parts.length; i++) {
      result[i] = int.tryParse(parts[i]) ?? 0;
    }
    return result;
  }

  static String? _readCache() {
    try {
      final file = File(_cachePath);
      if (!file.existsSync()) return null;
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final checkedAt = DateTime.tryParse(data['checked_at'] as String? ?? '');
      final version = data['latest'] as String?;
      if (checkedAt == null || version == null) return null;
      if (DateTime.now().difference(checkedAt) > cacheTtl) return null;
      return version;
    } catch (_) {
      return null;
    }
  }

  static void _writeCache(String version) {
    try {
      Directory(_cacheDir).createSync(recursive: true);
      File(_cachePath).writeAsStringSync(jsonEncode({
        'latest': version,
        'checked_at': DateTime.now().toIso8601String(),
      }));
    } catch (_) {
      // Cache failures are non-fatal.
    }
  }
}
