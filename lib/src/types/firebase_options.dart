import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'apk_resources.dart';
import 'binary_plist.dart';

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
    return FirebaseOptions._fromPlistValues(xmlPlistStrings(plistXml), source: source);
  }

  /// Parses a `GoogleService-Info.plist` from its bytes, XML or the binary
  /// form Xcode writes into the app bundle.
  factory FirebaseOptions.fromPlistBytes(
    Uint8List bytes, {
    String source = 'GoogleService-Info.plist',
  }) {
    return FirebaseOptions._fromPlistValues(plistStrings(bytes), source: source);
  }

  factory FirebaseOptions._fromPlistValues(
    Map<String, String> values, {
    required String source,
  }) {
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
    final bytes = file.readAsBytesSync();
    if (file.path.toLowerCase().endsWith('.plist') || isBinaryPlist(bytes)) {
      return FirebaseOptions.fromPlistBytes(bytes, source: file.path);
    }
    return FirebaseOptions.fromGoogleServicesJson(
      Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map),
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

  /// Options from the string resources the Google Services Gradle plugin
  /// compiles into an Android app (`project_id`, `google_api_key`,
  /// `google_app_id`, `gcm_defaultSenderId`, `google_storage_bucket`).
  static FirebaseOptions? fromAndroidResources(
    Map<String, String> resources, {
    String source = 'resources.arsc',
  }) {
    final projectId = _nonEmpty(resources['project_id']);
    if (projectId == null) return null;
    return FirebaseOptions(
      projectId: projectId,
      apiKey: _nonEmpty(resources['google_api_key']),
      appId: _nonEmpty(resources['google_app_id']),
      messagingSenderId: _nonEmpty(resources['gcm_defaultSenderId']),
      storageBucket: _nonEmpty(resources['google_storage_bucket']),
      source: source,
    );
  }

  /// Options found inside the Android APK at [apkPath]: the resources written
  /// by the Google Services Gradle plugin, or a `google-services.json`
  /// bundled as an asset. `null` when the APK holds neither.
  static FirebaseOptions? fromApk(String apkPath) {
    final config = readApkFirebaseConfig(apkPath);
    if (config == null) return null;
    final resources = config.resources;
    if (resources != null) {
      final options = fromAndroidResources(resources, source: '$apkPath!resources.arsc');
      if (options != null) return options;
    }
    final json = config.googleServicesJson;
    if (json != null) {
      try {
        final decoded = jsonDecode(json);
        if (decoded is Map) {
          return FirebaseOptions.fromGoogleServicesJson(
            Map<String, dynamic>.from(decoded),
            source: '$apkPath!${config.assetPath}',
          );
        }
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// Options from the APK the current Android process runs from, or `null`
  /// when not on Android or when the APK carries no Firebase configuration.
  static FirebaseOptions? fromCurrentApk() {
    final path = currentApkPath();
    if (path == null) return null;
    try {
      return fromApk(path);
    } catch (_) {
      return null;
    }
  }

  /// Config files bundled as DartNative / Flutter assets, found by walking the
  /// `flutter_assets` directory an iOS or macOS app bundle ships next to the
  /// executable.
  static FirebaseOptions? fromBundledAssets() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final sep = Platform.pathSeparator;
    final roots = <Directory>[
      Directory('${exeDir.path}${sep}Frameworks${sep}App.framework${sep}flutter_assets'),
      Directory('${exeDir.path}${sep}flutter_assets'),
      Directory('${exeDir.path}$sep..${sep}Resources${sep}flutter_assets'),
    ];
    for (final root in roots) {
      if (!root.existsSync()) continue;
      try {
        for (final entity in root.listSync(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          if (name == 'GoogleService-Info.plist' || name == 'google-services.json') {
            try {
              return fromFile(entity);
            } on FormatException {
              continue;
            }
          }
        }
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  /// Discovers options automatically, in order: `--dart-define`s, environment
  /// variables, the config files next to the app, the Android APK (Google
  /// Services Gradle plugin resources or a bundled `google-services.json`
  /// asset), then config files bundled as assets. Returns `null` when nothing
  /// is found.
  static FirebaseOptions? discover({
    Map<String, String>? environment,
    Directory? directory,
  }) {
    return fromDartDefines ??
        fromEnvironment(environment) ??
        fromFiles(directory: directory) ??
        (Platform.isAndroid ? fromCurrentApk() : null) ??
        fromBundledAssets();
  }

  static String? _nonEmpty(String? value) =>
      (value == null || value.isEmpty) ? null : value;


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
