import 'package:api_to_dart/src/core/update_checker.dart';
import 'package:test/test.dart';

void main() {
  group('UpdateChecker.isNewer', () {
    test('detects a newer version in each semver position', () {
      expect(UpdateChecker.isNewer('0.7.0', '1.0.0'), isTrue);
      expect(UpdateChecker.isNewer('0.7.0', '0.8.0'), isTrue);
      expect(UpdateChecker.isNewer('0.7.0', '0.7.1'), isTrue);
    });

    test('rejects an older or identical version', () {
      expect(UpdateChecker.isNewer('0.7.0', '0.7.0'), isFalse);
      expect(UpdateChecker.isNewer('0.7.0', '0.6.9'), isFalse);
      expect(UpdateChecker.isNewer('1.0.0', '0.9.9'), isFalse);
    });

    test('treats a pre-release as older than the matching release', () {
      // Both sides parsed to 0.7.0 and compared equal, so a beta user was
      // never told the stable release existed.
      expect(UpdateChecker.isNewer('0.7.0-beta', '0.7.0'), isTrue);
      expect(UpdateChecker.isNewer('0.7.0', '0.7.0-beta'), isFalse);
      expect(UpdateChecker.isNewer('0.7.0-beta', '0.7.0-beta'), isFalse);
    });

    test('ignores build metadata', () {
      expect(UpdateChecker.isNewer('0.7.0+1', '0.7.0+2'), isFalse);
    });

    test('never reports an update against the 0.0.0 sentinel', () {
      // packageVersion falls back to 0.0.0 when the bundled pubspec can't be
      // found; every real release beats it, producing a permanent false nag.
      expect(UpdateChecker.isNewer('0.0.0', '0.7.0'), isFalse);
      expect(UpdateChecker.isNewer('0.0.0', '99.0.0'), isFalse);
    });

    test('tolerates malformed version strings', () {
      expect(UpdateChecker.isNewer('not-a-version', '0.7.0'), isFalse);
      expect(UpdateChecker.isNewer('0.7', '0.7.0'), isFalse);
      expect(UpdateChecker.isNewer('0.7', '0.8'), isTrue);
    });
  });
}
