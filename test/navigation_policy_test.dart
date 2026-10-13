import 'package:flutter_test/flutter_test.dart';
import 'package:aurelia_pms/main.dart';

void main() {
  group('isAllowedTopLevelNavigation', () {
    test('allows bundled Flutter asset pages', () {
      expect(
        isAllowedTopLevelNavigation(
          'file:///android_asset/flutter_assets/assets/index.html',
        ),
        isTrue,
      );
    });

    test('allows explicit external-app schemes and blank pages', () {
      expect(isAllowedTopLevelNavigation('tel:+911234567890'), isTrue);
      expect(isAllowedTopLevelNavigation('mailto:help@example.com'), isTrue);
      expect(isAllowedTopLevelNavigation('about:blank'), isTrue);
    });

    test('blocks remote pages and untrusted file paths', () {
      expect(isAllowedTopLevelNavigation('https://example.com'), isFalse);
      expect(isAllowedTopLevelNavigation('http://example.com'), isFalse);
      expect(isAllowedTopLevelNavigation('file:///sdcard/private.txt'), isFalse);
      expect(
        isAllowedTopLevelNavigation(
          'file:///android_asset/flutter_assets/../../private.txt',
        ),
        isFalse,
      );
      expect(isAllowedTopLevelNavigation('not a url'), isFalse);
    });
  });
}
