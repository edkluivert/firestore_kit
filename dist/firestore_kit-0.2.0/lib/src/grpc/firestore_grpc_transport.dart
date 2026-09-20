import 'dart:async';

import 'package:grpc/grpc.dart';

import '../firestore.dart';
import 'generated/google/firestore/v1/firestore.pb.dart' as pb;
import 'generated/google/firestore/v1/firestore.pbgrpc.dart' as pbgrpc;

/// Configuration options for gRPC bidirectional streaming transport.
class GrpcTransportOptions {
  const GrpcTransportOptions({
    this.host = 'firestore.googleapis.com',
    this.port = 443,
    this.useTls = true,
    this.maxReconnectAttempts = 5,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.fallbackToPolling = true,
    this.pollInterval,
  });

  /// The gRPC host endpoint.
  final String host;

  /// The gRPC port (defaults to 443 for HTTPS/TLS).
  final int port;

  /// Whether to use secure TLS credentials.
  final bool useTls;

  /// How many consecutive failed (re)connections a Listen stream tolerates
  /// before giving up (and, if [fallbackToPolling] is set, switching to
  /// HTTP polling).
  final int maxReconnectAttempts;

  /// Backoff before the first reconnection attempt; doubles each retry.
  final Duration initialBackoff;

  /// Upper bound for the reconnection backoff.
  final Duration maxBackoff;

  /// Whether `snapshots()` streams degrade to HTTP polling once the gRPC
  /// stream is exhausted.
  final bool fallbackToPolling;

  /// Poll interval used by the fallback (defaults to the polling manager's own).
  final Duration? pollInterval;

  /// Returns a copy pointed at an emulator (plaintext).
  GrpcTransportOptions forEmulator(String host, int port) => GrpcTransportOptions(
        host: host,
        port: port,
        useTls: false,
        maxReconnectAttempts: maxReconnectAttempts,
        initialBackoff: initialBackoff,
        maxBackoff: maxBackoff,
        fallbackToPolling: fallbackToPolling,
        pollInterval: pollInterval,
      );
}

/// gRPC Realtime push transport engine for Cloud Firestore.
///
/// Owns the [ClientChannel] and the generated Firestore stub, and opens
/// `Listen` (Firestore Watch) streams on behalf of `snapshots()`.
class FirestoreGrpcTransport {
  FirestoreGrpcTransport({
    required this.firestore,
    GrpcTransportOptions? options,
  }) : options = options ?? const GrpcTransportOptions();

  final FirebaseFirestore firestore;
  final GrpcTransportOptions options;

  ClientChannel? _channel;
  pbgrpc.FirestoreClient? _stub;

  /// Returns the underlying gRPC [ClientChannel].
  ClientChannel get channel {
    _channel ??= ClientChannel(
      options.host,
      port: options.port,
      options: ChannelOptions(
        credentials: options.useTls
            ? const ChannelCredentials.secure()
            : const ChannelCredentials.insecure(),
        keepAlive: const ClientKeepAliveOptions(
          pingInterval: Duration(seconds: 30),
          timeout: Duration(seconds: 10),
        ),
      ),
    );
    return _channel!;
  }

  /// The generated Firestore gRPC stub bound to [channel].
  pbgrpc.FirestoreClient get stub => _stub ??= pbgrpc.FirestoreClient(channel);

  /// Static headers attached to every call.
  Map<String, String> get _staticHeaders => {
        'google-cloud-resource-prefix': firestore.client.databasePath,
        'x-goog-request-params': 'database=${firestore.client.databasePath}',
      };

  Future<void> _authProvider(Map<String, String> metadata, String uri) async {
    final client = firestore.client;
    if (client.isEmulator) {
      metadata['authorization'] = 'Bearer owner';
      return;
    }
    if (client.apiKey != null && client.apiKey!.isNotEmpty) {
      metadata['x-goog-api-key'] = client.apiKey!;
    }
    if (client.tokenProvider != null) {
      try {
        final token = await client.tokenProvider!();
        if (token != null && token.isNotEmpty) {
          metadata['authorization'] = 'Bearer $token';
        }
      } catch (_) {}
    }
  }

  /// Builds gRPC [CallOptions] containing authorization metadata headers.
  Future<CallOptions> getCallOptions() async {
    final headers = Map<String, String>.from(_staticHeaders);
    await _authProvider(headers, '');
    return CallOptions(metadata: headers);
  }

  /// [CallOptions] that resolve auth lazily on every (re)connection.
  CallOptions get streamingCallOptions => CallOptions(
        metadata: _staticHeaders,
        providers: [_authProvider],
      );

  /// Opens a Firestore `Listen` bidirectional stream.
  ResponseStream<pb.ListenResponse> listen(Stream<pb.ListenRequest> requests) {
    return stub.listen(requests, options: streamingCallOptions);
  }

  /// Closes the gRPC channel connection.
  Future<void> close() async {
    final channel = _channel;
    _channel = null;
    _stub = null;
    await channel?.shutdown();
  }
}
