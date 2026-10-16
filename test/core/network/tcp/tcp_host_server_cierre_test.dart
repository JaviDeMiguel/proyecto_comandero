/// `TcpHostServer.dispose` termina aunque un oyente tenga en pausa su
/// suscripción a [TcpHostServer.events] (p. ej. un proveedor de Riverpod de
/// una pantalla tapada).
library;

import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:test/test.dart';

void main() {
  test('dispose no espera a un oyente de events en pausa', () async {
    final server = TcpHostServer(
      identity: const HostIdentity(hostId: 'host', hostName: 'Host'),
      onRequest: (_, _) => const <String, Object?>{},
    );
    final suscripcion = server.events.listen((_) {})..pause();
    addTearDown(suscripcion.cancel);

    await expectLater(
      server.dispose().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
