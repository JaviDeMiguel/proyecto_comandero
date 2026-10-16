/// `TcpComanderoClient.dispose` termina aunque un oyente tenga en pausa su
/// suscripción a [TcpComanderoClient.states] o [TcpComanderoClient.messages].
library;

import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:test/test.dart';

void main() {
  test('dispose no espera a oyentes en pausa de states y messages', () async {
    final client = TcpComanderoClient(
      identity: const ClientIdentity(deviceId: 'movil', deviceName: 'Móvil'),
    );
    for (final stream in <Stream<Object?>>[client.states, client.messages]) {
      final suscripcion = stream.listen((_) {})..pause();
      addTearDown(suscripcion.cancel);
    }

    await expectLater(
      client.dispose().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
