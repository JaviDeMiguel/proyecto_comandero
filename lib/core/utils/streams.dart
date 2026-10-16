/// Utilidades de streams.
library;

import 'dart:async';

import '../logging/app_logger.dart';

final Logger _log = appLogger('core.streams');

/// Cierra [controller] sin esperar a que el «done» llegue a sus oyentes.
///
/// El `Future` de `close()` de un `StreamController.broadcast` no completa
/// hasta que TODOS sus oyentes han recibido el «done», y uno en pausa (p. ej.
/// el proveedor de Riverpod de una pantalla tapada) no lo recibe hasta que se
/// reanuda o se cancela: esperarlo puede colgar un `dispose` para siempre.
///
/// El controlador queda cerrado al instante (no admite más eventos); los
/// oyentes activos reciben el «done» como con `close()` y los pausados, al
/// reanudarse. Un error del cierre se registra en el log.
void cerrarSinEsperar<T>(StreamController<T> controller) {
  unawaited(
    controller.close().then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) =>
          _log.warning('Fallo al cerrar un stream', error, stackTrace),
    ),
  );
}
