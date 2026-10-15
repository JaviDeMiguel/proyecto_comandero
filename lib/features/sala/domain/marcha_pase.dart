import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';

/// Marcha de un pase: la orden a cocina de que empiece a preparar el pase
/// (el primero puede marcharse solo al enviar la comanda: [automatica]).
///
/// La comanda las conserva en orden cronológico. [id] es el `marchaId` de la
/// petición `comanda.pase.marchar`, que la hace idempotente ante
/// retransmisiones; en una marcha automática es un uuid del host.
final class MarchaPase extends Equatable {
  const MarchaPase({
    required this.id,
    required this.pase,
    required this.cuando,
    this.camarero,
    this.automatica = false,
    this.repetida = false,
  });

  /// Lectura estricta: [FormatException] si falta un campo, tiene otro tipo
  /// o [pase] no es positivo. `Comanda.fromJson` la envuelve con
  /// `listaTolerante` y descarta la marcha ilegible.
  factory MarchaPase.fromJson(Map<String, Object?> json) {
    final pase = json.requireInt('pase');
    if (pase < 1) {
      throw FormatException(
        "Campo 'pase': se esperaba un entero positivo y llegó $pase",
      );
    }
    return MarchaPase(
      id: json.requireString('id'),
      pase: pase,
      cuando: DateTime.parse(json.requireString('cuando')),
      camarero: json.optionalString('camarero'),
      automatica: json.optionalBool('automatica') ?? false,
      repetida: json.optionalBool('repetida') ?? false,
    );
  }

  /// `marchaId` del comandero, o uuid del host si la marcha es automática.
  final String id;

  /// Pase marchado: `1..n`, posición en base 1 en `PasesConfig.nombres`.
  final int pase;

  /// Reloj del host al registrar la marcha.
  final DateTime cuando;

  /// Quién marchó (camarero o dispositivo).
  final String? camarero;

  /// Marcha implícita del primer pase al enviar la comanda.
  final bool automatica;

  /// El pase ya estaba marchado: se reimprime con la cabecera de repetición.
  final bool repetida;

  /// [camarero] solo si no es nulo; [automatica] y [repetida] solo si son
  /// `true`.
  Map<String, Object?> toJson() => {
    'id': id,
    'pase': pase,
    'cuando': cuando.toIso8601String(),
    if (camarero != null) 'camarero': camarero,
    if (automatica) 'automatica': true,
    if (repetida) 'repetida': true,
  };

  @override
  List<Object?> get props => [id, pase, cuando, camarero, automatica, repetida];
}
