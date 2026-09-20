import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// The Firebase project configuration a [FirebaseFirestore] instance connects
/// with, mirroring `firebase_core`'s `FirebaseOptions`.
///
/// `dartnative_firebase`'s `Firebase.initializeApp()` configures the native
/// SDKs from `GoogleService-Info.plist` / `google-services.json` but does not
/// expose those values to Dart, so `firestore_kit` discovers them itself; see
/// [FirebaseOptions.discover].
@immutable
class FirebaseOptions {
  const FirebaseOptions({
    required this.projectId,
    this.apiKey,
    this.appId,
    this.messagingSenderId,
    this.storageBucket,
    this.databaseId = '(default)',
    this.source = 'explicit',
  });

  /// The Firebase / Google Cloud project id.
  final String projectId;

  /// The web API key (`X-Goog-Api-Key`). Optional for Firestore.
  final String? apiKey;

  /// The Firebase app id (`GOOGLE_APP_ID` / `mobilesdk_app_id`).
  final String? appId;

  /// The Cloud Messaging sender id.
  final String? messagingSenderId;

  /// The default Cloud Storage bucket.
  final String? storageBucket;

  /// The Firestore database id, `(default)` unless using named databases.
  final String databaseId;

  /// Where these options came from (for diagnostics), e.g. `dart-define`,
  /// `environment`, or a file path.
  final String source;

  /// Dart-define keys consulted by [discover] (pass with `--dart-define`).
  static const String dartDefineProjectId = 'FIREBASE_PROJECT_ID';
  static const String dartDefineApiKey = 'FIREBASE_API_KEY';
  static const String dartDefineAppId = 'FIREBASE_APP_ID';
  static const String dartDefineDatabaseId = 'FIREBASE_DATABASE_ID';

  static const String _definedProjectId = String.fromEnvironment(dartDefineProjectId);
  static const String _definedApiKey = String.fromEnvironment(dartDefineApiKey);
  static const String _definedAppId = String.fromEnvironment(dartDefineAppId);
  static const String _definedDatabaseId = String.fromEnvironment(dartDefineDatabaseId);

  /// Options from `--dart-define=FIREBASE_PROJECT_ID=...` (and friends), or
  /// `null` when no project id was defined at compile time.
  static FirebaseOptions? get fromDartDefines {
    if (_definedProjectId.isEmpty) return null;
    return FirebaseOptions(
      projectId: _definedProjectId,
      apiKey: _definedApiKey.isEmpty ? null : _definedApiKey,
      appId: _definedAppId.isEmpty ? null : _definedAppId,
      databaseId: _definedDatabaseId.isEmpty ? '(default)' : _definedDatabaseId,
      source: 'dart-define',
    );
  }

  /// Options from process environment variables: `FIREBASE_PROJECT_ID`,
  /// `GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`, or the JSON `FIREBASE_CONFIG`
  /// used by Cloud Functions / Cloud Run, with `FIREBASE_API_KEY` and
  /// `FIREBASE_DATABASE_ID` as optional extras.
  static FirebaseOptions? fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    String? projectId = env['FIREBASE_PROJECT_ID'] ?? env['GOOGLE_CLOUD_PROJECT'] ?? env['GCLOUD_PROJECT'];
    String? storageBucket;

    final config = env['FIREBASE_CONFIG'];
    if (config != null && config.trim().isNotEmpty) {
      try {
        final json = jsonDecode(config);
        if (json is Map) {
          projectId ??= json['projectId'] as String?;
          storageBucket = json['storageBucket'] as String?;
        }
      } catch (_) {
        // Not JSON (Cloud Functions may pass a file path); ignore.
      }
    }

    if (projectId == null || projectId.isEmpty) return null;
    return FirebaseOptions(
      projectId: projectId,
      apiKey: _nonEmpty(env['FIREBASE_API_KEY']),
      appId: _nonEmpty(env['FIREBASE_APP_ID']),
      storageBucket: storageBucket,
      databaseId: _nonEmpty(env['FIREBASE_DATABASE_ID']) ?? '(default)',
      source: 'environment',
    );
  }

  /// Parses an Android `google-services.json` document.
  factory FirebaseOptions.fromGoogleServicesJson(
    Map<String, dynamic> json, {
    String source = 'google-services.json',
  }) {
    final projectInfo = json['project_info'] as Map? ?? const {};
    final clients = (json['client'] as List?) ?? const [];
    final client = clients.isNotEmpty ? clients.first as Map : const <String, dynamic>{};
    final apiKeys = (client['api_key'] as List?) ?? const [];
    final clientInfo = client['client_info'] as Map? ?? const {};

    final projectId = projectInfo['project_id'] as String?;
    if (projectId == null || projectId.isEmpty) {
      throw const FormatException('google-services.json is missing project_info.project_id');
    }
    return FirebaseOptions(
      projectId: projectId,
      apiKey: apiKeys.isNotEmpty ? (apiKeys.first as Map)['current_key'] as String? : null,
      appId: clientInfo['mobilesdk_app_id'] as String?,
      messagingSenderId: projectInfo['project_number']?.toString(),
      storageBucket: projectInfo['storage_bucket'] as String?,
      source: source,
    );
  }

  /// Parses an iOS/macOS `GoogleService-Info.plist` document (XML plist).
  factory FirebaseOptions.fromPlist(
    String plistXml, {
    String source = 'GoogleService-Info.plist',
  }) {
    final values = _parsePlistStrings(plistXml);
    final projectId = values['PROJECT_ID'];
    if (projectId == null || projectId.isEmpty) {
      throw const FormatException('GoogleService-Info.plist is missing PROJECT_ID');
    }
    return FirebaseOptions(
      projectId: projectId,
      apiKey: values['API_KEY'],
      appId: values['GOOGLE_APP_ID'],
      messagingSenderId: values['GCM_SENDER_ID'],
      storageBucket: values['STORAGE_BUCKET'],
      source: source,
    );
  }

  /// Loads options from a `google-services.json` or `GoogleService-Info.plist`
  /// file, chosen by extension.
  static FirebaseOptions fromFile(File file) {
    final contents = file.readAsStringSync();
    if (file.path.toLowerCase().endsWith('.plist')) {
      return FirebaseOptions.fromPlist(contents, source: file.path);
    }
    return FirebaseOptions.fromGoogleServicesJson(
      Map<String, dynamic>.from(jsonDecode(contents) as Map),
      source: file.path,
    );
  }

  /// Candidate config file locations, most specific first: next to the running
  /// executable (an iOS/macOS app bundle ships `GoogleService-Info.plist`
  /// there), then the usual project-layout paths relative to [directory]
  /// (defaults to the current directory).
  static List<File> candidateFiles({Directory? directory}) {
    final root = directory?.path ?? Directory.current.path;
    final sep = Platform.pathSeparator;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final paths = <String>[
      '$exeDir${sep}GoogleService-Info.plist',
      '$exeDir$sep..${sep}Resources${sep}GoogleService-Info.plist',
      '$exeDir${sep}google-services.json',
      '$root${sep}GoogleService-Info.plist',
      '$root${sep}google-services.json',
      '$root${sep}ios${sep}Runner${sep}GoogleService-Info.plist',
      '$root${sep}ios${sep}GoogleService-Info.plist',
      '$root${sep}macos${sep}Runner${sep}GoogleService-Info.plist',
      '$root${sep}android${sep}app${sep}google-services.json',
    ];
    return paths.map(File.new).toList();
  }

  /// Finds the first readable config file among [candidateFiles].
  static FirebaseOptions? fromFiles({Directory? directory}) {
    for (final file in candidateFiles(directory: directory)) {
      if (!file.existsSync()) continue;
      try {
        return fromFile(file);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// Discovers options automatically, in order: `--dart-define`s, environment
  /// variables, then config files. Returns `null` when nothing is found.
  static FirebaseOptions? discover({
    Map<String, String>? environment,
    Directory? directory,
  }) {
    return fromDartDefines ??
        fromEnvironment(environment) ??
        fromFiles(directory: directory);
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;

  static Map<String, String> _parsePlistStrings(String xml) {
    final result = <String, String>{};
    final pattern = RegExp(
      r'<key>\s*([^<]+?)\s*</key>\s*<(string|integer|true|false)\s*/?>(?:([^<]*)</\2>)?',
      multiLine: true,
    );
    for (final match in pattern.allMatches(xml)) {
      final key = match.group(1)!;
      final type = match.group(2)!;
      final value = match.group(3);
      result[key] = switch (type) {
        'true' => 'true',
        'false' => 'false',
        _ => _unescapeXml(value ?? ''),
      };
    }
    return result;
  }

  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  /// Returns a copy with the given fields replaced.
  FirebaseOptions copyWith({
    String? projectId,
    String? apiKey,
    String? appId,
    String? messagingSenderId,
    String? storageBucket,
    String? databaseId,
    String? source,
  }) {
    return FirebaseOptions(
      projectId: projectId ?? this.projectId,
      apiKey: apiKey ?? this.apiKey,
      appId: appId ?? this.appId,
      messagingSenderId: messagingSenderId ?? this.messagingSenderId,
      storageBucket: storageBucket ?? this.storageBucket,
      databaseId: databaseId ?? this.databaseId,
      source: source ?? this.source,
    );
  }

  /// Serializes the options.
  Map<String, dynamic> get asMap => {
        'projectId': projectId,
        'apiKey': apiKey,
        'appId': appId,
        'messagingSenderId': messagingSenderId,
        'storageBucket': storageBucket,
        'databaseId': databaseId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FirebaseOptions &&
          runtimeType == other.runtimeType &&
          projectId == other.projectId &&
          apiKey == other.apiKey &&
          appId == other.appId &&
          messagingSenderId == other.messagingSenderId &&
          storageBucket == other.storageBucket &&
          databaseId == other.databaseId;

  @override
  int get hashCode => Object.hash(projectId, apiKey, appId, messagingSenderId, storageBucket, databaseId);

  @override
  String toString() => 'FirebaseOptions(projectId: $projectId, databaseId: $databaseId, source: $source)';
}
