import 'dart:io';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:firestore_kit/src/types/binary_plist.dart';
import 'package:test/test.dart';

void main() {
  final fixture = File('test/fixtures/GoogleService-Info-binary.plist');

  test('parses the binary plist Xcode writes into the bundle', () {
    final bytes = fixture.readAsBytesSync();
    expect(isBinaryPlist(bytes), isTrue);
    final top = parseBinaryPlist(bytes) as Map<String, Object?>;
    expect(top['PROJECT_ID'], 'binary-fixture');
    expect(top['IS_ADS_ENABLED'], false);
    expect(top['IS_GCM_ENABLED'], true);
    expect(top['GOOGLE_APP_ID'], '1:424242424242:ios:0123456789abcdef');
    final strings = plistStrings(bytes);
    expect(strings['IS_ADS_ENABLED'], 'false');
    expect(strings['API_KEY'], 'AIzaSyBinaryFixtureKey000000000000000000');
  });

  test('FirebaseOptions.fromFile handles binary and XML plists', () {
    final binary = FirebaseOptions.fromFile(fixture);
    expect(binary.projectId, 'binary-fixture');
    expect(binary.apiKey, 'AIzaSyBinaryFixtureKey000000000000000000');
    expect(binary.appId, '1:424242424242:ios:0123456789abcdef');
    expect(binary.messagingSenderId, '424242424242');
    expect(binary.storageBucket, 'binary-fixture.firebasestorage.app');

    final xml = File('${Directory.systemTemp.path}/fak-xml.plist')
      ..writeAsStringSync('<plist><dict><key>PROJECT_ID</key><string>x</string>'
          '<key>API_KEY</key><string>k</string><key>GOOGLE_APP_ID</key><string>1:1:ios:1</string>'
          '<key>GCM_SENDER_ID</key><string>1</string></dict></plist>');
    addTearDown(xml.deleteSync);
    expect(FirebaseOptions.fromFile(xml).projectId, 'x');
  });

  test('rejects garbage', () {
    expect(() => parseBinaryPlist(File('test/fixtures/google_services.apk').readAsBytesSync()),
        throwsFormatException);
  });
}
