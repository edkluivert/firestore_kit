import 'dart:convert';
import 'dart:io';

/// A minimal fake of the Firestore REST API used to exercise commit, get and
/// runQuery over HTTP without touching the network.
class FakeRestServer {
  FakeRestServer._(this._server);

  final HttpServer _server;

  /// Every commit request body received, in order.
  final List<Map<String, dynamic>> commits = [];

  /// Documents keyed by full resource name (`projects/.../documents/...`).
  final Map<String, Map<String, dynamic>> documents = {};

  /// When set, commits fail with this HTTP status.
  int? failCommitsWithStatus;

  /// Number of GET document requests served.
  int getCount = 0;

  String get host => _server.address.host;
  int get port => _server.port;

  static Future<FakeRestServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeRestServer._(server);
    server.listen(fake._handle);
    return fake;
  }

  Future<void> close() => _server.close(force: true);

  /// Seeds a document in proto-JSON form.
  void seed(String name, Map<String, dynamic> fields) {
    documents[name] = {
      'name': name,
      'fields': fields,
      'createTime': '2024-01-01T00:00:00.000000Z',
      'updateTime': '2024-01-01T00:00:00.000000Z',
    };
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final body = await utf8.decoder.bind(request).join();
    final resource = path.startsWith('/v1/') ? path.substring(4) : path;

    Future<void> reply(int status, Object payload) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    }

    Future<void> error(int status, String code, String message) => reply(status, {
          'error': {'code': status, 'message': message, 'status': code}
        });

    if (resource.endsWith(':commit')) {
      final json = jsonDecode(body) as Map<String, dynamic>;
      commits.add(json);
      final failStatus = failCommitsWithStatus;
      if (failStatus != null) {
        return error(failStatus, failStatus == 403 ? 'PERMISSION_DENIED' : 'UNAVAILABLE',
            'commit rejected by fake server');
      }
      final writes = (json['writes'] as List?) ?? const [];
      for (final w in writes.cast<Map<String, dynamic>>()) {
        if (w['update'] is Map) {
          final update = Map<String, dynamic>.from(w['update'] as Map);
          final name = update['name'] as String;
          final existing = documents[name];
          if (w['updateMask'] != null && existing != null) {
            final fields = Map<String, dynamic>.from(existing['fields'] as Map? ?? {});
            fields.addAll(Map<String, dynamic>.from(update['fields'] as Map? ?? {}));
            seed(name, fields);
          } else {
            seed(name, Map<String, dynamic>.from(update['fields'] as Map? ?? {}));
          }
        } else if (w['delete'] is String) {
          documents.remove(w['delete']);
        }
      }
      return reply(200, {
        'writeResults': [for (final _ in writes) <String, dynamic>{}],
        'commitTime': DateTime.now().toUtc().toIso8601String(),
      });
    }

    if (resource.endsWith(':runQuery')) {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final parent = resource.substring(0, resource.length - ':runQuery'.length);
      final sq = Map<String, dynamic>.from(json['structuredQuery'] as Map);
      final from = (sq['from'] as List).first as Map;
      final collectionId = from['collectionId'] as String;
      final prefix = '$parent/$collectionId/';
      final matches = documents.entries
          .where((e) => e.key.startsWith(prefix) && !e.key.substring(prefix.length).contains('/'))
          .map((e) => {'document': e.value, 'readTime': DateTime.now().toUtc().toIso8601String()})
          .toList();
      if (matches.isEmpty) {
        matches.add({'readTime': DateTime.now().toUtc().toIso8601String()});
      }
      return reply(200, matches);
    }

    if (resource.endsWith(':beginTransaction')) {
      return reply(200, {'transaction': base64.encode(utf8.encode('txn'))});
    }

    if (request.method == 'GET') {
      getCount++;
      final doc = documents[resource];
      if (doc == null) return error(404, 'NOT_FOUND', 'Document not found: $resource');
      return reply(200, doc);
    }

    if (request.method == 'DELETE') {
      documents.remove(resource);
      return reply(200, <String, dynamic>{});
    }

    return error(404, 'NOT_FOUND', 'Unhandled $path');
  }
}

/// Returns a loopback port that nothing is listening on.
Future<int> closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
