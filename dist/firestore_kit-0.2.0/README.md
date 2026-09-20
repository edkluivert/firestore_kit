# firestore_kit

**Cloud Firestore for DartNative, in pure Dart.**

The complete `cloud_firestore` API, implemented on top of Firestore's REST and gRPC endpoints
instead of the native SDK. iOS, Android, macOS, Linux, Windows, and plain Dart on servers and
the command line.

> This is a data-layer package, not a native plugin. Firestore is one of the Firebase services
> that Dart can reach directly over its public APIs, so there is no native SDK to wrap — and no
> platform channel, JNI bridge or FFI layer in between. It pairs with
> [`dartnative_firebase`](https://dartpub.dev/plugins/dartnative_firebase) (Core, Crashlytics,
> Messaging) but does not depend on it. See [Scope](#scope).

## Why this package exists

Firestore is the database almost every Firebase app is built on, and the official client is a
Flutter plugin: Dart calls cross a method channel into the native Firestore SDK, which does the
networking, caching and realtime streaming on your behalf. That design is exactly what a
DartNative app doesn't have — and doesn't need.

- **Firestore speaks HTTP and gRPC.** Every operation the native SDK performs — reads, writes,
  transactions, aggregations, the realtime `Listen` stream — is a documented public API. Dart's
  `http` and `grpc` packages reach it directly.
- **No bridge means no bridge overhead.** Documents are decoded once, in the isolate that asked for
  them. Nothing is serialized across a platform channel, and nothing waits on a native thread.
- **One code path everywhere.** The same package runs in your DartNative app, your CLI tools, your
  Dart backend and your tests, against production or the emulator.

What the native SDK gives you beyond the wire protocol — an offline cache, queued writes, resume
tokens, snapshot listeners — this package implements in Dart, with the pieces exposed so you can
swap them (bring your own storage engine) or switch them off.

## Scope

`firestore_kit` covers Cloud Firestore, end to end:

| Included | What you get |
|---|---|
| **Client API** | `FirebaseFirestore`, collections, documents, queries, `Filter`, `FieldValue`, `FieldPath`, `Timestamp`, `GeoPoint`, converters — the `cloud_firestore` surface, name for name |
| **Writes** | `set` / `update` / `delete`, `WriteBatch`, `runTransaction`, field transforms (server timestamp, increment, array union/remove, delete) |
| **Reads** | `get` with `Source.server` / `cache` / `serverAndCache`, queries, cursors (values and snapshots), collection groups, `count` / `sum` / `average` aggregations |
| **Realtime** | `snapshots()` on the Firestore **Listen** gRPC stream — resume tokens, existence filters, backoff reconnection, HTTP polling fallback; `snapshotsInSync()` |
| **Offline** | automatic write queue with replay, `waitForPendingWrites`, `disableNetwork` / `enableNetwork`, `enablePersistence` / `clearPersistence`, pluggable cache adapters (file, memory, Hive, SharedPreferences, …) |
| **Bundles** | `loadBundle`, `namedQueryGet` |
| **Lifecycle & tooling** | `settings`, `terminate`, `useFirestoreEmulator`, safe request logging with credential redaction, HTTP interceptors |

**On the name.** `firestore_kit` is scoped to Firestore. Auth, Storage, Functions and the rest each
belong in their own package; this one only needs a project id and, optionally, a token provider
for the bearer token your security rules expect.

## Why you'll like it

- **Drop-in.** Code written against `cloud_firestore` compiles against `firestore_kit` with the
  import swapped. Same classes, same method names, same snapshot and metadata semantics.
- **Zero-config start.** `FirebaseFirestore.instance` finds your project from the
  `GoogleService-Info.plist` / `google-services.json` you already ship, a `--dart-define`, or the
  environment — the same files `Firebase.initializeApp()` reads.
- **Real realtime.** Snapshot listeners are pushed by the backend over a bidirectional gRPC stream,
  not polled, and survive reconnects with resume tokens.
- **Offline that behaves like the SDK.** Writes made offline complete locally, show up in cached
  reads with `hasPendingWrites`, and are replayed in order when the backend is reachable.
- **Nothing hidden.** The cache is an interface you can implement in a dozen lines. The logger
  redacts `Authorization` and API-key headers so request logs are safe to keep.
- **Verified against the real thing.** The test suite runs against the Firestore emulator as well
  as in-process fakes of the REST and gRPC services.

## Advantages over the official plugin

| | `cloud_firestore` (FlutterFire) | `firestore_kit` |
|---|:---:|:---:|
| Runs without Flutter (DartNative, CLI, server, CI) | ❌ | ✅ |
| No platform channel / native SDK round-trip per call | ❌ | ✅ |
| Same code path on every platform (no per-OS SDK differences) | ❌ | ✅ |
| Choose your own cache store (file, Hive, SharedPreferences, secure storage, Redis, …) | ❌ | ✅ |
| Inspect and control the offline queue (`pendingWriteCount`, `flushPendingWrites`, opt out) | ❌ | ✅ |
| Request logging with automatic credential redaction | ❌ | ✅ |
| HTTP interceptors for metrics and tracing | ❌ | ✅ |
| Tune realtime transport (backoff, reconnect limit, polling fallback) | ❌ | ✅ |
| Test against in-process fakes without a device or emulator | ❌ | ✅ |
| Server-side auth with a service account, same API as the app | ❌ | ✅ |
| Server timestamps, increments, array transforms resolved locally while offline | ✅ | ✅ |
| Realtime `snapshots()` pushed by the backend | ✅ | ✅ |
| Full `cloud_firestore` API surface | ✅ | ✅ |

## Highlights

- `FirebaseFirestore.instance` — zero-config; `FirebaseFirestore.initialize(...)` for explicit
  options, cache adapter, gRPC options and logging; `tokenProvider` settable at any time.
- `collection()` / `doc()` / `collectionGroup()` — `get`, `set`, `update`, `delete`, `add`,
  `withConverter`.
- Queries — `where` (all operators, `Filter.and` / `Filter.or`), `orderBy`, `limit`,
  `limitToLast`, `startAt` … `endBefore`, `startAtDocument` … `endBeforeDocument`,
  `count()` / `aggregate()`.
- Realtime — `snapshots()` on documents and queries with `docChanges`; `snapshotsInSync()`.
- Offline — `flushPendingWrites`, `waitForPendingWrites`, `pendingWriteCount`,
  `disableNetwork` / `enableNetwork`, `enablePersistence` / `clearPersistence`,
  `FileCacheAdapter`, `MemoryCacheAdapter`, `FirestoreCacheAdapter`, `CacheJsonCodec`.
- Bundles — `loadBundle` (progress via `LoadBundleTask`), `namedQueryGet`,
  `namedQueryWithConverterGet`.
- Tooling — `FirestoreLogger`, `FirestoreInterceptor`, `GrpcTransportOptions`,
  `useFirestoreEmulator`, `settings`, `terminate`.

## Install

```yaml
dependencies:
  firestore_kit: ^0.2.0
```

```sh
dn pub get      # DartNative apps
dart pub get    # everything else
```

If you also use `dartnative_firebase`, initialize it first as usual; `firestore_kit` picks up the
same project:

```dart
void main() async {
  DartNativePluginRegistrant.registerAll();
  await Firebase.initializeApp();          // dartnative_firebase (optional)
  final db = FirebaseFirestore.instance;   // firestore_kit — discovered automatically
  runApp(const MyApp());
}
```

Without a config file in reach, pass the project explicitly:

```dart
FirebaseFirestore.initialize(
  options: const FirebaseOptions(projectId: 'my-project', apiKey: 'AIza...'),
  tokenProvider: () async => await myAuth.idToken(), // bearer token for security rules
);
```

## Quick look

### Read, write, query

```dart
import 'package:firestore_kit/firestore_kit.dart';

final db = FirebaseFirestore.instance;

await db.collection('users').doc('alice').set({
  'name': 'Alice',
  'score': 10,
  'createdAt': FieldValue.serverTimestamp(),
});

await db.collection('users').doc('alice').update({
  'score': FieldValue.increment(5),
  'tags': FieldValue.arrayUnion(['beta']),
  'profile.city': 'Lagos',
});

final leaders = await db
    .collection('users')
    .where('score', isGreaterThan: 0)
    .orderBy('score', descending: true)
    .limit(10)
    .get();

for (final doc in leaders.docs) {
  print('${doc.id}: ${doc.get('score')}');
}

final nextPage = await db
    .collection('users')
    .orderBy('score', descending: true)
    .startAfterDocument(leaders.docs.last)
    .limit(10)
    .get();

final stats = await db.collection('users').aggregate(count(), average('score')).get();
```

### Realtime

```dart
final sub = db.collection('chats').doc(roomId).collection('messages')
    .orderBy('sentAt')
    .snapshots()
    .listen((snapshot) {
  for (final change in snapshot.docChanges) {
    print('${change.type.name}: ${change.doc.data()}');
  }
});
```

Enable the gRPC push stream with `useGrpcStreaming: true` (recommended); without it, `snapshots()`
polls over HTTP.

### Offline

```dart
await db.collection('todos').doc('t1').set({'title': 'Buy milk'}); // completes even offline

final snap = await db.doc('todos/t1').get();   // served from cache while offline
print(snap.metadata.hasPendingWrites);         // true until the backend acknowledges it

await db.waitForPendingWrites();               // resolves once everything is synced
```

Persist the cache across launches with a disk adapter, or your own storage engine:

```dart
FirebaseFirestore.initialize(
  cacheAdapter: FileCacheAdapter(cacheDirectory: Directory('.firestore_cache')),
);
```

```dart
class HiveCacheAdapter implements FirestoreCacheAdapter {
  HiveCacheAdapter(this.box);
  final Box<String> box;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final raw = box.get(path);
    return raw == null ? null : CacheJsonCodec.decode(jsonDecode(raw));
  }

  @override
  Future<void> putDocument(String path, Map<String, dynamic> data) =>
      box.put(path, jsonEncode(CacheJsonCodec.encode(data)));

  @override
  Future<void> deleteDocument(String path) => box.delete(path);

  @override
  Future<void> clear() => box.clear();
}
```

### Transactions and batches

```dart
await db.runTransaction((tx) async {
  final account = await tx.get(db.doc('accounts/a'));
  tx.update(db.doc('accounts/a'), {'balance': account.get('balance') + 50});
});

final batch = db.batch()
  ..update(db.doc('stats/visitors'), {'count': FieldValue.increment(1)})
  ..set(db.collection('logs').doc(), {'event': 'page_view'});
await batch.commit();
```

### Bundles

```dart
await db.loadBundle(bundleBytes).future;
final fromBundle = await db.namedQueryGet('recent-users', options: const GetOptions(source: Source.cache));
final refreshed  = await db.namedQueryGet('recent-users'); // re-runs the bundled query online
```

## Use cases

Everything below is complete and runnable; pick the scenario that matches yours.

### 1. A DartNative app on iOS and Android

```dart
import 'package:dartnative_firebase/dartnative_firebase.dart';
import 'package:firestore_kit/firestore_kit.dart';

void main() async {
  DartNativePluginRegistrant.registerAll();
  await Firebase.initializeApp();

  FirebaseFirestore.initialize(
    // iOS finds GoogleService-Info.plist in the bundle; Android needs
    // --dart-define=FIREBASE_PROJECT_ID=my-project (see Platform setup).
    cacheAdapter: FileCacheAdapter(cacheDirectory: Directory('${appSupportDir.path}/firestore')),
    useGrpcStreaming: true,
  );

  // Attach the user's ID token once they sign in.
  FirebaseFirestore.instance.tokenProvider = () async => await session.idToken();

  runApp(const MyApp());
}
```

### 2. A Flutter app (drop-in replacement)

Swap `cloud_firestore` for `firestore_kit` in `pubspec.yaml`, change the import, and add one
`initialize` call in `main()` with a cache directory from `path_provider`. Widgets built on
`StreamBuilder<QuerySnapshot>` and `FutureBuilder<DocumentSnapshot>` keep working unchanged.

### 3. A Dart server, worker or CLI with a service account

See `example/server_auth.dart`. The token provider caches the OAuth2 access token and refreshes it
on expiry:

```dart
final credentials = ServiceAccountCredentials.fromJson(File('service-account.json').readAsStringSync());
AccessCredentials? cached;

FirebaseFirestore.initialize(
  projectId: 'my-project',
  tokenProvider: () async {
    if (cached == null || cached!.accessToken.hasExpired) {
      cached = await obtainAccessCredentialsViaServiceAccount(
          credentials, ['https://www.googleapis.com/auth/datastore'], http.Client());
    }
    return cached!.accessToken.data;
  },
);
```

Service accounts bypass security rules, exactly like the Admin SDK.

### 4. Cloud Run, Cloud Functions, CI

Nothing to configure: the project comes from `GOOGLE_CLOUD_PROJECT` / `FIREBASE_CONFIG`, and the
token provider can return the metadata-server access token:

```dart
FirebaseFirestore.initialize(
  tokenProvider: () async {
    final res = await http.get(
      Uri.parse('http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'),
      headers: {'Metadata-Flavor': 'Google'},
    );
    return (jsonDecode(res.body) as Map)['access_token'] as String;
  },
);
```

### 5. Documents and subcollections

```dart
final users = db.collection('users');
final alice = users.doc('alice');                 // fixed id
final draft = users.doc();                        // auto id, not yet written
final posts = alice.collection('posts');          // subcollection
final byPath = db.doc('users/alice/posts/p1');    // any depth by path

await alice.set({'name': 'Alice'});                               // create or overwrite
await alice.set({'age': 30}, SetOptions(merge: true));            // merge fields
await alice.set({'a': 1, 'b': 2}, SetOptions(mergeFields: ['a'])); // merge only listed fields
await alice.update({'profile.city': 'Lagos'});                    // dot paths update nested fields
await alice.update({FieldPath(['weird.key']): 1});                // FieldPath for keys with dots
final ref = await posts.add({'title': 'Hello'});                  // returns the new reference
await ref.delete();

print(alice.id);            // alice
print(alice.path);          // users/alice
print(alice.parent.path);   // users
print(posts.parent?.path);  // users/alice
```

### 6. Field values and data types

```dart
await alice.update({
  'updatedAt': FieldValue.serverTimestamp(),
  'visits': FieldValue.increment(1),
  'tags': FieldValue.arrayUnion(['pro']),
  'oldTags': FieldValue.arrayRemove(['trial']),
  'legacyField': FieldValue.delete(),
  'when': Timestamp.now(),                  // or Timestamp.fromDate(DateTime)
  'where': const GeoPoint(6.5244, 3.3792),
  'avatar': Uint8List.fromList(bytes),      // stored as Firestore bytes
  'bestFriend': db.doc('users/bob'),        // stored as a document reference
  'nested': {'list': [1, 2.5, 'three', null]},
});

final snap = await alice.get();
final Timestamp when = snap.get('when');
final DateTime date = when.toDate();
final GeoPoint where = snap.get('where');
final Map<String, dynamic> nested = snap.get('nested');
final String bestFriendPath = snap.get('bestFriend'); // full resource name of the reference
print(snap.get('nested.list'));                       // dot paths work on reads too
print(snap.containsField('avatar'));
```

### 7. Reading with a source

```dart
final live   = await alice.get();                                        // server, cache on failure
final fresh  = await alice.get(const GetOptions(source: Source.server)); // server only, throws offline
final cached = await alice.get(const GetOptions(source: Source.cache));  // cache only

print(live.exists);
print(live.metadata.isFromCache);
print(live.metadata.hasPendingWrites);
```

### 8. Every query operator

```dart
final q = db.collection('products');

q.where('price', isEqualTo: 10);
q.where('price', isNotEqualTo: 10);
q.where('price', isLessThan: 10);
q.where('price', isLessThanOrEqualTo: 10);
q.where('price', isGreaterThan: 10);
q.where('price', isGreaterThanOrEqualTo: 10);
q.where('tags', arrayContains: 'sale');
q.where('tags', arrayContainsAny: ['sale', 'new']);
q.where('category', whereIn: ['toys', 'games']);
q.where('category', whereNotIn: ['archived']);
q.where('discontinuedAt', isNull: true);
q.where(FieldPath.documentId, isGreaterThan: 'p100');

// Composite filters
q.where(Filter.or(
  Filter('category', isEqualTo: 'toys'),
  Filter.and(Filter('price', isLessThan: 20), Filter('tags', arrayContains: 'sale')),
));

// Ordering and limits
q.orderBy('price').orderBy('name', descending: true).limit(20);
q.orderBy('createdAt').limitToLast(5); // the newest five, in ascending order
```

### 9. Pagination

```dart
// By values
final page1 = await q.orderBy('price').limit(20).get();
final lastPrice = page1.docs.last.get('price');
final page2 = await q.orderBy('price').startAfter([lastPrice]).limit(20).get();

// By document snapshot (exact, even with duplicate values)
final page3 = await q.orderBy('price').startAfterDocument(page2.docs.last).limit(20).get();

// Ranges
q.orderBy('price').startAt([10]).endBefore([100]);
q.orderBy('price').startAtDocument(first).endAtDocument(last);
```

### 10. Collection groups

```dart
// Every "comments" subcollection under any document
final recent = await db
    .collectionGroup('comments')
    .where('flagged', isEqualTo: true)
    .orderBy('createdAt', descending: true)
    .limit(50)
    .get();

for (final c in recent.docs) {
  print('${c.reference.path} -> ${c.get('text')}');
}
```

### 11. Aggregations

```dart
final total = await db.collection('orders').count().get();
print(total.count);

final stats = await db
    .collection('orders')
    .where('status', isEqualTo: 'paid')
    .aggregate(count(), sum('amount'), average('amount'))
    .get();
print('${stats.count} orders, ${stats.getSum('amount')} total, ${stats.getAverage('amount')} avg');
```

### 12. Typed models with converters

```dart
class User {
  User({required this.name, required this.score});
  final String name;
  final int score;

  factory User.fromJson(Map<String, dynamic> json) =>
      User(name: json['name'] as String, score: json['score'] as int);
  Map<String, dynamic> toJson() => {'name': name, 'score': score};
}

final users = db.collection('users').withConverter<User>(
  fromFirestore: (snap, _) => User.fromJson(snap.data()!),
  toFirestore: (user, _) => user.toJson(),
);

await users.doc('alice').set(User(name: 'Alice', score: 10));
final User? alice = (await users.doc('alice').get()).data();
final List<User> top = (await users.orderBy('score', descending: true).limit(3).get())
    .docs
    .map((d) => d.data())
    .toList();

// Converters flow through queries, snapshots(), batches and transactions.
users.orderBy('score').snapshots().listen((s) => s.docs.map((d) => d.data()));
```

### 13. Realtime listeners

```dart
// A single document
final docSub = db.doc('rooms/lobby').snapshots().listen((snap) {
  if (!snap.exists) return print('deleted');
  print(snap.data());
});

// A query, with per-document changes for efficient list updates
final querySub = db
    .collection('rooms/lobby/messages')
    .orderBy('sentAt')
    .limitToLast(100)
    .snapshots()
    .listen((snapshot) {
  for (final change in snapshot.docChanges) {
    switch (change.type) {
      case DocumentChangeType.added:
        insertAt(change.newIndex, change.doc);
      case DocumentChangeType.modified:
        moveAndUpdate(change.oldIndex, change.newIndex, change.doc);
      case DocumentChangeType.removed:
        removeAt(change.oldIndex);
    }
  }
}, onError: (Object e) {
  // Permanent failures (permission-denied, invalid query) end the stream here.
});

// Fires whenever every active listener has caught up with the backend
db.snapshotsInSync().listen((_) => hideSpinner());

await docSub.cancel();
await querySub.cancel();
```

Transport: with `useGrpcStreaming: true` listeners run on the Firestore Listen stream and
reconnect with resume tokens after transient failures; after `maxReconnectAttempts` they fall back
to HTTP polling when `fallbackToPolling` is set. Without gRPC, `snapshots()` polls
(`pollInterval` overrides the default 2–3 s).

### 14. Working offline

```dart
// Writes never block on the network: unreachable backend -> queued + applied to cache
await db.doc('todos/t1').set({'title': 'Buy milk', 'createdAt': FieldValue.serverTimestamp()});
await db.doc('todos/t1').update({'done': true});

print(await db.pendingWriteCount);                 // 2
print(await db.hasPendingWritesFor('todos/t1'));   // true
final local = await db.doc('todos/t1').get();      // from cache while offline
print(local.metadata.hasPendingWrites);            // true
print(local.get('createdAt'));                     // local estimate until the server confirms

// Sync
final synced = await db.flushPendingWrites();      // try now; returns how many went through
await db.waitForPendingWrites();                   // block until everything is acknowledged
await db.waitForPendingWrites(timeout: const Duration(seconds: 15)); // or give up

// Explicit control (airplane-mode toggle, battery saver, tests)
await db.disableNetwork();  // reads from cache, writes queue, listeners pause
await db.enableNetwork();   // listeners resume, queue flushes
```

Transactions are never queued: they need the backend and fail with `unavailable` when offline.
Pass `autoQueueOfflineWrites: false` to `initialize` if you would rather get the network error.

### 15. Persistence and cache adapters

```dart
// Built in
FirebaseFirestore.initialize(cacheAdapter: MemoryCacheAdapter());                             // process lifetime
FirebaseFirestore.initialize(cacheAdapter: FileCacheAdapter(cacheDirectory: Directory('.fs'))); // survives restarts

// Or turn it on later; installs a FileCacheAdapter under .firestore_kit_cache/<project>/
await db.enablePersistence();
await db.enablePersistence(PersistenceSettings(cacheDirectory: Directory('/data/app/cache')));

// Wipe everything local (documents, queued writes, loaded bundles)
await db.clearPersistence();
```

Any key-value store works — implement four methods. Run data through `CacheJsonCodec` if your
store only takes JSON strings (it preserves `Timestamp`, `GeoPoint`, bytes and references):

```dart
class PrefsCacheAdapter implements FirestoreCacheAdapter {
  PrefsCacheAdapter(this.prefs);
  final SharedPreferences prefs;

  @override
  Future<Map<String, dynamic>?> getDocument(String path) async {
    final raw = prefs.getString('fs:$path');
    return raw == null ? null : CacheJsonCodec.decode(jsonDecode(raw) as Map<String, dynamic>);
  }

  @override
  Future<void> putDocument(String path, Map<String, dynamic> data) =>
      prefs.setString('fs:$path', jsonEncode(CacheJsonCodec.encode(data)));

  @override
  Future<void> deleteDocument(String path) => prefs.remove('fs:$path');

  @override
  Future<void> clear() async {
    for (final k in prefs.getKeys().where((k) => k.startsWith('fs:'))) {
      await prefs.remove(k);
    }
  }
}
```

Adapter failures are logged, never thrown: a broken cache degrades to cache misses.

### 16. Transactions

```dart
final newBalance = await db.runTransaction<int>((tx) async {
  final from = await tx.get(db.doc('accounts/a'));
  final to = await tx.get(db.doc('accounts/b'));
  if (!from.exists) throw StateError('missing account');

  final balance = from.get('balance') as int;
  if (balance < 50) throw StateError('insufficient funds'); // aborts, no retry

  tx.update(db.doc('accounts/a'), {'balance': balance - 50});
  tx.update(db.doc('accounts/b'), {'balance': (to.get('balance') as int) + 50});
  tx.set(db.collection('transfers').doc(), {'amount': 50, 'at': FieldValue.serverTimestamp()});
  return balance - 50;
}, maxAttempts: 5, timeout: const Duration(seconds: 30));
```

Reads must happen before writes. Contention (`aborted`) and transient network errors are retried
with backoff and the failed attempt is rolled back; anything else is thrown to you as-is.

### 17. Batched writes

```dart
final batch = db.batch();
for (final item in cart) {
  batch.set(db.collection('orders/$orderId/items').doc(item.sku), item.toJson());
}
batch.update(db.doc('orders/$orderId'), {'itemCount': FieldValue.increment(cart.length)});
batch.delete(db.doc('carts/$userId'));
await batch.commit(); // all-or-nothing; queued as one unit if offline
```

### 18. Bundles (pre-fetched data)

```dart
final bytes = await http.readBytes(Uri.parse('https://cdn.example.com/catalog.bundle'));

final task = db.loadBundle(bytes);
task.stream.listen((p) => print('${p.documentsLoaded}/${p.totalDocuments}'));
await task.future;

// Instant, from the bundle
final catalog = await db.namedQueryGet('catalog', options: const GetOptions(source: Source.cache));

// Fresh, re-running the same query on the backend (falls back to the bundle when offline)
final latest = await db.namedQueryGet('catalog');

final typed = await db.namedQueryWithConverterGet<Product>(
  'catalog',
  fromFirestore: (snap, _) => Product.fromJson(snap.data()!),
  toFirestore: (p, _) => p.toJson(),
);
```

### 19. Multiple projects and named databases

```dart
final analytics = FirebaseFirestore.instanceFor(projectId: 'my-project', databaseId: 'analytics');
final other = FirebaseFirestore.instanceFor(
  projectId: 'partner-project',
  tokenProvider: partnerToken,
  cacheAdapter: MemoryCacheAdapter(),
);
```

Each project/database pair is its own instance with its own cache, queue and listeners.

### 20. Emulator and local development

```dart
final db = FirebaseFirestore.instance..useFirestoreEmulator('127.0.0.1', 8080);
// or
db.settings = const Settings(host: '127.0.0.1:8080', sslEnabled: false, persistenceEnabled: true);
```

### 21. Logging, metrics and tracing

```dart
FirebaseFirestore.initialize(
  logger: FirestoreLogger(
    level: LogLevel.info,                  // none, error, warning, info, debug
    redactSensitiveHeaders: true,          // Authorization / API key never reach the log
    printer: (level, message, [error, stack]) => myLogger.log(level.name, message, error),
  ),
  interceptors: [LatencyInterceptor()],
);

class LatencyInterceptor implements FirestoreInterceptor {
  @override
  void onRequest(http.BaseRequest request) {}

  @override
  void onResponse(http.BaseResponse response, Duration latency) =>
      metrics.timing('firestore.${response.request?.url.pathSegments.last}', latency);

  @override
  void onError(Object error, StackTrace? stackTrace) => metrics.increment('firestore.errors');
}
```

### 22. Error handling

```dart
try {
  await db.doc('private/secret').get(const GetOptions(source: Source.server));
} on FirebaseFirestoreException catch (e) {
  switch (e.code) {
    case 'permission-denied':   // security rules
    case 'unauthenticated':     // missing or expired token
      await signInAgain();
    case 'not-found':
    case 'already-exists':
    case 'failed-precondition':  // e.g. update() on a missing doc, or a missing index
    case 'invalid-argument':
      showError(e.message);
    default:
      if (e.isOffline) showOfflineBanner(); // unavailable / deadline-exceeded
      else if (e.isRetryable) scheduleRetry();
  }
}
```

Codes follow `cloud_firestore` (`[cloud_firestore/permission-denied] ...`), so existing error
handling ports as-is.

### 23. Lifecycle

```dart
await db.waitForPendingWrites(); // drain before exit
await db.terminate();            // cancel listeners, close connections, release the instance
// FirebaseFirestore.instance now returns a fresh instance; queued writes stay in the cache adapter.
```

### 24. Testing your own code

Point the instance at a fake with `useFirestoreEmulator` and run either the Firestore emulator or a
tiny in-process HTTP server; `test/helpers/fake_rest_server.dart` and
`test/helpers/fake_grpc_server.dart` in this repository show both. `disableNetwork()` plus a
`MemoryCacheAdapter` gives you a fully offline Firestore for unit tests with no server at all:

```dart
final db = FirebaseFirestore.instanceFor(projectId: 'test', cacheAdapter: MemoryCacheAdapter());
await db.disableNetwork();
await db.doc('users/u1').set({'name': 'Test'});
expect((await db.doc('users/u1').get()).get('name'), 'Test');
```

## Platform setup

Firestore needs to know which project to talk to. `firestore_kit` looks, in order, at:

1. `--dart-define=FIREBASE_PROJECT_ID=<id>` (plus optional `FIREBASE_API_KEY`,
   `FIREBASE_APP_ID`, `FIREBASE_DATABASE_ID`)
2. Environment variables `FIREBASE_PROJECT_ID`, `GOOGLE_CLOUD_PROJECT`, `GCLOUD_PROJECT`, or the
   JSON `FIREBASE_CONFIG` that Cloud Functions and Cloud Run set
3. A `GoogleService-Info.plist` next to the executable or under `ios/Runner/` / `macos/Runner/`,
   or a `google-services.json` in the project root or `android/app/`

If none is found, `FirebaseFirestore.instance` throws a `failed-precondition` error that lists
these options.

### iOS / macOS

Add the `GoogleService-Info.plist` from your Firebase project to the app target, as you would for
any Firebase app. It ships inside the app bundle and is read at launch — nothing else to configure.

### Android

`google-services.json` is compiled into resources by the Google Services Gradle plugin and is not
a file at runtime, so pass the project id at build time:

```sh
dn build apk --dart-define=FIREBASE_PROJECT_ID=my-project
```

or call `FirebaseFirestore.initialize(projectId: ...)` in `main()`. No Gradle changes are needed
for Firestore itself.

### Servers, CLIs, CI

Set `FIREBASE_PROJECT_ID` (or `GOOGLE_CLOUD_PROJECT`) in the environment, or keep a
`google-services.json` in the working directory. Supply a `tokenProvider` that returns a Google
OAuth2 access token or Firebase ID token with the access your security rules require.

### Emulator

```dart
FirebaseFirestore.instance.useFirestoreEmulator('127.0.0.1', 8080);
```

Both the REST client and the gRPC stream follow the emulator host; auth is bypassed with the
emulator's owner token.

### Authentication

Requests carry whatever your `tokenProvider` returns as a bearer token, plus the API key if one
is configured. Attach it whenever your auth layer is ready — it can be set or replaced at runtime:

```dart
FirebaseFirestore.instance.tokenProvider = () async => await FirebaseAuth.instance.currentUser?.getIdToken();
```

## Example

- `example/main.dart` — an app-style flow: writes a todo, listens over the gRPC stream, updates,
  counts, waits for pending writes and shuts down, against the emulator.
- `example/server_auth.dart` — a server/CLI flow authenticated with a service account.

Borrow from them freely.

## Migrating from FlutterFire

The public API deliberately mirrors `cloud_firestore`, so imports and call sites port unchanged:
swap the dependency in `pubspec.yaml`, change the import to `package:firestore_kit/firestore_kit.dart`,
follow [Platform setup](#platform-setup), and keep your Firebase project and config files as they
are. Differences worth knowing:

- Initialization discovers the project itself; there is no `Firebase.initializeApp()` dependency.
- Auth is decoupled: hand Firestore a `tokenProvider` instead of relying on a shared native app.
- Query results are not served from the local cache (`GetOptions(source: Source.cache)` applies
  to documents and bundles); realtime queries are always live.
- Persistence is whatever cache adapter you plug in; `enablePersistence()` installs a
  `FileCacheAdapter` by default.

## Testing

`dart test` runs the unit suite against in-process fakes of the REST and gRPC services. The
end-to-end suite runs against the Firestore emulator when the host is set:

```sh
firebase emulators:start --only firestore --project demo-firestore-kit
FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 dart test test/live_emulator_test.dart
```

## Regenerating the gRPC stubs

`lib/src/grpc/generated` is produced from the official
[googleapis](https://github.com/googleapis/googleapis) protos with `protoc` and `protoc_plugin`:

```sh
protoc -I protos --dart_out=grpc:lib/src/grpc/generated \
  google/firestore/v1/*.proto google/rpc/status.proto google/type/latlng.proto
```

Well-known types come from `package:protobuf/well_known_types`; the `.pbjson.dart` descriptor
files are not needed.

## Credits & license

An independent, pure-Dart implementation of the `cloud_firestore` API (FlutterFire) over
Firestore's public REST and gRPC endpoints; no FlutterFire source is included. Generated protobuf
classes derive from Google's Apache-2.0 API definitions (see `NOTICES`).

MIT — see `LICENSE`.
