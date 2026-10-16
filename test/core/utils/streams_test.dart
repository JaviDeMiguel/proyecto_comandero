import 'dart:async';

import 'package:proyecto_comandero/core/utils/streams.dart';
import 'package:test/test.dart';

void main() {
  group('cerrarSinEsperar', () {
    test('cierra al instante aunque un oyente esté en pausa, y el oyente '
        'recibe los eventos y el «done» al reanudarse', () async {
      final controller = StreamController<int>.broadcast();
      final recibidos = <int>[];
      final terminado = Completer<void>();
      final suscripcion = controller.stream.listen(
        recibidos.add,
        onDone: terminado.complete,
      )..pause();
      controller.add(1);

      cerrarSinEsperar(controller);

      expect(controller.isClosed, isTrue);
      expect(() => controller.add(2), throwsStateError);
      suscripcion.resume();
      await terminado.future.timeout(const Duration(seconds: 2));
      expect(recibidos, [1]);
    });

    test('un oyente activo recibe el «done» igual que con close()', () async {
      final controller = StreamController<String>.broadcast();
      final terminado = Completer<void>();
      controller.stream.listen((_) {}, onDone: terminado.complete);

      cerrarSinEsperar(controller);

      await expectLater(
        terminado.future.timeout(const Duration(seconds: 2)),
        completes,
      );
    });

    test('un controlador ya cerrado no lanza', () async {
      final controller = StreamController<void>.broadcast();
      await controller.close();

      expect(() => cerrarSinEsperar(controller), returnsNormally);
    });
  });
}
