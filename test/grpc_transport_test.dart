import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('gRPC Transport & Realtime Streaming', () {
    test('initializes Firestore with gRPC streaming enabled', () async {
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'grpc-test-proj',
        useGrpcStreaming: true,
        grpcOptions: const GrpcTransportOptions(
          host: 'localhost',
          port: 8080,
          useTls: false,
        ),
      );

      expect(firestore.useGrpcStreaming, isTrue);
      expect(firestore.grpcTransport, isNotNull);
      expect(firestore.grpcTransport!.options.host, equals('localhost'));
      expect(firestore.grpcTransport!.options.port, equals(8080));
      expect(firestore.grpcTransport!.options.useTls, isFalse);

      final callOptions = await firestore.grpcTransport!.getCallOptions();
      expect(callOptions, isNotNull);

      await firestore.grpcTransport!.close();
    });

    test('GrpcStreamManager document stream handles fallback gracefully', () async {
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'grpc-fallback-proj',
        useGrpcStreaming: true,
      );

      final docRef = firestore.collection('items').doc('item_123');

      // Request stream (uses gRPC manager with HTTP fallback)
      final stream = docRef.snapshots();
      expect(stream, isNotNull);

      await firestore.grpcTransport?.close();
    });
  });
}
