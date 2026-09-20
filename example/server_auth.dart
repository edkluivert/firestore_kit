// Server-side / CLI usage with a Google service account.
//
//   FIREBASE_PROJECT_ID=my-project GOOGLE_APPLICATION_CREDENTIALS=sa.json dart run example/server_auth.dart
import 'dart:io';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  final keyFile = Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'] ?? 'service-account.json';
  final credentials = ServiceAccountCredentials.fromJson(File(keyFile).readAsStringSync());
  const scopes = ['https://www.googleapis.com/auth/datastore'];
  final authClient = http.Client();
  AccessCredentials? cached;

  FirebaseFirestore.initialize(
    // projectId is discovered from FIREBASE_PROJECT_ID / GOOGLE_CLOUD_PROJECT;
    // pass projectId: '...' to be explicit.
    tokenProvider: () async {
      if (cached == null || cached!.accessToken.hasExpired) {
        cached = await obtainAccessCredentialsViaServiceAccount(credentials, scopes, authClient);
      }
      return cached!.accessToken.data;
    },
    logger: FirestoreLogger(level: LogLevel.info),
  );

  final db = FirebaseFirestore.instance;
  final report = await db.collection('orders').where('status', isEqualTo: 'paid').count().get();
  stdout.writeln('paid orders: ${report.count}');

  await db.terminate();
  authClient.close();
}
