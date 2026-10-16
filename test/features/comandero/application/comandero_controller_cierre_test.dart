/// `ComanderoController.dispose` termina aunque un oyente tenga en pausa su
/// suscripción a uno de sus streams (p. ej. un proveedor de Riverpod de una
/// pantalla tapada).
library;

import 'package:proyecto_comandero/features/comandero/application/comandero_controller.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:test/test.dart';

void main() {
  test('dispose no espera a oyentes en pausa de states, pedidosCambiados y '
      'avisos', () async {
    final controller = ComanderoController(
      config: const ComanderoConfig(
        deviceId: 'movil-1',
        deviceName: 'Comandero 1',
        appVersion: '1.0.0',
      ),
    );
    for (final stream in <Stream<Object?>>[
      controller.states,
      controller.pedidosCambiados,
      controller.avisos,
    ]) {
      final suscripcion = stream.listen((_) {})..pause();
      addTearDown(suscripcion.cancel);
    }

    await expectLater(
      controller.dispose().timeout(const Duration(seconds: 2)),
      completes,
    );
  });
}
