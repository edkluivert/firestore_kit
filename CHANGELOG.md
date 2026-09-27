## 0.2.1

- **Android zero-config**: `FirebaseFirestore.instance` now reads the project from the installed
  APK — the `project_id` / `google_api_key` / `google_app_id` string resources the Google Services
  Gradle plugin compiles from `google-services.json`, or a `google-services.json` bundled as a
  `dartnative: assets:` entry. `--dart-define=FIREBASE_PROJECT_ID` is no longer required on Android.
  New `FirebaseOptions.fromApk`, `fromAndroidResources`, `fromCurrentApk`, `fromBundledAssets`.
- Config files bundled as assets are also found in the iOS / macOS bundle's `flutter_assets`.

## 0.2.0

- **Zero-config initialization**: `FirebaseFirestore.instance` discovers the project from
  `--dart-define=FIREBASE_PROJECT_ID`, environment variables (`FIREBASE_PROJECT_ID`,
  `GOOGLE_CLOUD_PROJECT`, `FIREBASE_CONFIG`) or the `GoogleService-Info.plist` /
  `google-services.json` shipped with the app. New `FirebaseOptions` class and
  `FirebaseFirestore.initialize(options: ...)`. `tokenProvider` is now settable at runtime.
- **True gRPC Listen (Firestore Watch)**: `snapshots()` uses a bidirectional Listen stream with
  resume tokens, existence-filter resyncs, exponential-backoff reconnection and optional HTTP
  polling fallback. Generated protobuf/gRPC stubs live in `lib/src/grpc/generated`.
- **Automatic offline sync**: writes that fail because the backend is unreachable are queued as
  `Write` protos, mirrored into the cache, and replayed by `flushPendingWrites()`,
  `enableNetwork()` and `waitForPendingWrites()`. `autoQueueOfflineWrites` opts out.
- **Built-in `FileCacheAdapter`** with `CacheJsonCodec` for JSON-safe persistence of
  `Timestamp`, `GeoPoint`, bytes and references.
- **Lifecycle API parity**: `enablePersistence()`, `clearPersistence()`, `waitForPendingWrites()`,
  `terminate()`, `disableNetwork()`, `enableNetwork()`, `snapshotsInSync()`, `settings`.
- **Bundles**: `loadBundle()` returns a `LoadBundleTask`; `namedQueryGet()` /
  `namedQueryWithConverterGet()` serve from the bundle or re-run the bundled query online.
- **Snapshot cursors**: `startAtDocument`, `startAfterDocument`, `endAtDocument`,
  `endBeforeDocument`.
- Verified end to end against the Firestore emulator (`test/live_emulator_test.dart`, run with
  `FIRESTORE_EMULATOR_HOST=host:port`).
- Fixes: `limitToLast()` now reverses ordering as the backend requires; query `parent` resources
  are computed correctly for nested collections; aggregation results were reported under the
  wrong aliases (`count` / `getSum` / `getAverage` returned null); `Transaction.get` uses
  `batchGet` and failed transactions are rolled back and retried only on retryable errors;
  `Timestamp` keeps nanosecond precision instead of truncating through `DateTime`; cache adapter
  failures are logged instead of breaking reads and streams; `SnapshotMetadata.hasPendingWrites`
  reflects queued writes; exceptions use the `cloud_firestore` plugin prefix.

## 0.1.0

- Initial release.
