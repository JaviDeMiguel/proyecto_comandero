import 'package:equatable/equatable.dart';

import '../../../core/isolates/reposicion/reposicion_models.dart';
import '../../../core/utils/json_map.dart';

/// Ajustes del reaprovisionamiento automático (pedidos a proveedor).
final class ReposicionSettings extends Equatable {
  const ReposicionSettings({
    this.automatica = true,
    this.enCierre = true,
    this.politica = const PoliticaReposicion(),
  });

  /// Lee los ajustes guardados. Campos ausentes → valor por defecto. Lanza
  /// [FormatException] si un campo presente es inválido.
  factory ReposicionSettings.fromJson(Map<String, Object?> json) {
    const defaults = ReposicionSettings();
    final politicaJson = json.optionalMap('politica');
    return ReposicionSettings(
      automatica: json.optionalBool('automatica') ?? defaults.automatica,
      enCierre: json.optionalBool('enCierre') ?? defaults.enCierre,
      politica: politicaJson == null
          ? defaults.politica
          : politicaFromJson(politicaJson),
    );
  }

  /// Proponer pedidos automáticamente cuando una materia prima entra en
  /// rotura (`disponible + pterecibir < stockmin`).
  final bool automatica;

  /// Ejecutar la auditoría de reposición al hacer el Cierre Z.
  final bool enCierre;

  /// Parámetros del motor de reposición.
  final PoliticaReposicion politica;

  /// Serializa una [PoliticaReposicion] (el motor no lo hace por sí mismo).
  static Map<String, Object?> politicaToJson(PoliticaReposicion politica) => {
    'factorSinMaximo': politica.factorSinMaximo,
    'multiploPedido': politica.multiploPedido,
    'incluirSinMinimo': politica.incluirSinMinimo,
  };

  /// Inversa de [politicaToJson]; campos ausentes → valores del motor. Lanza
  /// [FormatException] si un valor numérico no es admisible.
  static PoliticaReposicion politicaFromJson(Map<String, Object?> json) {
    const defaults = PoliticaReposicion();
    final factor =
        json.optionalDouble('factorSinMaximo') ?? defaults.factorSinMaximo;
    final multiplo =
        json.optionalDouble('multiploPedido') ?? defaults.multiploPedido;
    if (!(factor > 0) || !factor.isFinite) {
      throw FormatException("Campo 'factorSinMaximo': debe ser > 0: $factor");
    }
    if (!(multiplo >= 0.001) || !multiplo.isFinite) {
      throw FormatException(
        "Campo 'multiploPedido': debe ser >= 0.001: $multiplo",
      );
    }
    return PoliticaReposicion(
      factorSinMaximo: factor,
      multiploPedido: multiplo,
      incluirSinMinimo:
          json.optionalBool('incluirSinMinimo') ?? defaults.incluirSinMinimo,
    );
  }

  Map<String, Object?> toJson() => {
    'automatica': automatica,
    'enCierre': enCierre,
    'politica': politicaToJson(politica),
  };

  ReposicionSettings copyWith({
    bool? automatica,
    bool? enCierre,
    PoliticaReposicion? politica,
  }) => ReposicionSettings(
    automatica: automatica ?? this.automatica,
    enCierre: enCierre ?? this.enCierre,
    politica: politica ?? this.politica,
  );

  @override
  List<Object?> get props => [automatica, enCierre, politica];
}
