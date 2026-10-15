import 'package:equatable/equatable.dart';

/// Gravedad de un aviso operativo del host.
enum AlertaNivel { info, aviso, error }

/// Aviso operativo para la interfaz de la tablet: fallo de impresión,
/// discrepancia con el ERP, cola en pausa, catálogo con incidencias...
final class OperationalAlert extends Equatable {
  const OperationalAlert({
    required this.nivel,
    required this.titulo,
    required this.cuando,
    this.detalle,
    this.origen,
    this.trabajoImpresion,
  });

  final AlertaNivel nivel;
  final String titulo;

  /// Texto largo opcional (mensaje del error, referencias afectadas...).
  final String? detalle;

  /// Servicio que lo emite (`sala`, `outbox`, `impresion`...).
  final String? origen;
  final DateTime cuando;

  /// Id del trabajo de la cola de impresión que falló, en los avisos
  /// «Fallo de impresión»: la interfaz ofrece «Reintentar» con él.
  final String? trabajoImpresion;

  @override
  List<Object?> get props => [
    nivel,
    titulo,
    detalle,
    origen,
    cuando,
    trabajoImpresion,
  ];

  @override
  String toString() =>
      'OperationalAlert(${nivel.name}, $titulo'
      '${detalle == null ? '' : ': $detalle'})';
}
