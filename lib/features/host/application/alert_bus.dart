import 'dart:async';

import '../../../core/logging/app_logger.dart';
import '../domain/operational_alert.dart';

/// Canal común de avisos operativos de todos los servicios del host.
///
/// Cada aviso se registra también en el log con su nivel. El stream es
/// *broadcast*: quien se suscriba tarde no recibe los anteriores; para eso
/// está [recientes].
final class AlertBus {
  AlertBus({DateTime Function()? now, this.maxRecientes = 100})
    : _now = now ?? DateTime.now;

  static final Logger _log = appLogger('host.alerts');

  final DateTime Function() _now;
  final int maxRecientes;
  final StreamController<OperationalAlert> _controller =
      StreamController<OperationalAlert>.broadcast();
  final List<OperationalAlert> _recientes = [];

  Stream<OperationalAlert> get stream => _controller.stream;

  /// Últimos avisos emitidos, del más antiguo al más nuevo.
  List<OperationalAlert> get recientes => List.unmodifiable(_recientes);

  void info(String titulo, {String? detalle, String? origen}) =>
      emit(AlertaNivel.info, titulo, detalle: detalle, origen: origen);

  void aviso(String titulo, {String? detalle, String? origen}) =>
      emit(AlertaNivel.aviso, titulo, detalle: detalle, origen: origen);

  /// [trabajoImpresion]: id del trabajo de impresión fallido, si lo hay
  /// (`OperationalAlert.trabajoImpresion`).
  void error(
    String titulo, {
    String? detalle,
    String? origen,
    String? trabajoImpresion,
  }) => emit(
    AlertaNivel.error,
    titulo,
    detalle: detalle,
    origen: origen,
    trabajoImpresion: trabajoImpresion,
  );

  void emit(
    AlertaNivel nivel,
    String titulo, {
    String? detalle,
    String? origen,
    String? trabajoImpresion,
  }) {
    final alert = OperationalAlert(
      nivel: nivel,
      titulo: titulo,
      detalle: detalle,
      origen: origen,
      cuando: _now(),
      trabajoImpresion: trabajoImpresion,
    );
    _log.log(switch (nivel) {
      AlertaNivel.info => Level.INFO,
      AlertaNivel.aviso => Level.WARNING,
      AlertaNivel.error => Level.SEVERE,
    }, '[${origen ?? 'host'}] $titulo${detalle == null ? '' : ': $detalle'}');
    _recientes.add(alert);
    if (_recientes.length > maxRecientes) _recientes.removeAt(0);
    if (!_controller.isClosed) _controller.add(alert);
  }

  Future<void> dispose() => _controller.close();
}
