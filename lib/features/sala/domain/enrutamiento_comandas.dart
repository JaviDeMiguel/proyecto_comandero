import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart'
    show FamiliaCatalogo;
import '../../../core/utils/json_map.dart';
import 'linea_comanda.dart';

/// Reglas de enrutamiento de las comandas a los puestos de preparación
/// (cocina / barra) según la familia del artículo en FacturaScripts.
///
/// Las reglas se definen por `codfamilia` y se **heredan** por la jerarquía
/// de familias (`familias.madre`): una subfamilia sin regla propia usa la de
/// su madre, la de su abuela... y, si ninguna antecesora tiene regla, el
/// destino [porDefecto]. Así basta con decir "Bebidas → barra" para que
/// "Refrescos" o "Cervezas" (subfamilias de Bebidas) salgan por barra.
///
/// El host es la autoridad: fija el destino de cada línea con su
/// enrutamiento y lo publica a los comanderos en el snapshot de sala.
///
/// El constructor `const` no copia [porFamilia]: quien lo construya no debe
/// modificar el mapa después. [fromJson], [conRegla] y [conPorDefecto]
/// devuelven siempre mapas inmodificables.
final class EnrutamientoComandas extends Equatable {
  const EnrutamientoComandas({
    this.porFamilia = const {},
    this.porDefecto = DestinoPreparacion.cocina,
  });

  /// Lee un enrutamiento guardado o recibido.
  ///
  /// Tolerante con lo que falta: sin `porDefecto` se usa cocina y sin
  /// `porFamilia` no hay reglas. Lanza [FormatException] si un campo tiene un
  /// tipo inválido, un destino desconocido o una familia vacía.
  factory EnrutamientoComandas.fromJson(Map<String, Object?> json) {
    final porDefecto = switch (json.optionalString('porDefecto')) {
      final String nombre => _destino(nombre, campo: 'porDefecto'),
      null => DestinoPreparacion.cocina,
    };
    final reglas = <String, DestinoPreparacion>{};
    final crudo = json.optionalMap('porFamilia') ?? const {};
    for (final MapEntry(key: codfamilia, value: valor) in crudo.entries) {
      if (codfamilia.trim().isEmpty) {
        throw const FormatException(
          "Campo 'porFamilia': hay una familia sin código",
        );
      }
      if (valor is! String) {
        throw FormatException(
          "Campo 'porFamilia.$codfamilia': se esperaba String",
        );
      }
      reglas[codfamilia] = _destino(valor, campo: 'porFamilia.$codfamilia');
    }
    return EnrutamientoComandas(
      porFamilia: Map.unmodifiable(reglas),
      porDefecto: porDefecto,
    );
  }

  /// Regla explícita por `codfamilia`. Las familias que no figuran heredan.
  final Map<String, DestinoPreparacion> porFamilia;

  /// Destino de los artículos sin familia o cuya familia (ni ninguna
  /// antecesora) tiene regla.
  final DestinoPreparacion porDefecto;

  /// Ningún artículo va a barra con este enrutamiento.
  bool get todoACocina =>
      porDefecto == DestinoPreparacion.cocina &&
      !porFamilia.values.contains(DestinoPreparacion.barra);

  /// Algún artículo puede ir a [destino] (por regla o por defecto).
  bool usa(DestinoPreparacion destino) =>
      porDefecto == destino || porFamilia.values.contains(destino);

  /// Regla propia de [codfamilia] (`null` = hereda).
  DestinoPreparacion? reglaDe(String codfamilia) => porFamilia[codfamilia];

  /// Destino efectivo de un artículo de la familia [codfamilia].
  ///
  /// [madreDe] es la jerarquía de familias (`codfamilia → madre`, ver
  /// [jerarquia]); sin ella no hay herencia. Un ciclo en la jerarquía
  /// (datos corruptos del ERP) no cuelga la búsqueda: se corta al repetir
  /// una familia y se usa [porDefecto].
  DestinoPreparacion destinoDe(
    String? codfamilia, {
    Map<String, String?> madreDe = const {},
  }) => origenDe(codfamilia, madreDe: madreDe).destino;

  /// Como [destinoDe], pero indica también de qué familia sale la regla
  /// (`null` si se aplica [porDefecto]). La pantalla de configuración lo usa
  /// para explicar el destino heredado.
  ({DestinoPreparacion destino, String? familia}) origenDe(
    String? codfamilia, {
    Map<String, String?> madreDe = const {},
  }) {
    final visitadas = <String>{};
    var actual = _limpio(codfamilia);
    while (actual != null && visitadas.add(actual)) {
      final regla = porFamilia[actual];
      if (regla != null) return (destino: regla, familia: actual);
      actual = _limpio(madreDe[actual]);
    }
    return (destino: porDefecto, familia: null);
  }

  /// Copia con la regla de [codfamilia] fijada a [destino]; `null` la quita
  /// (la familia pasa a heredar).
  EnrutamientoComandas conRegla(
    String codfamilia,
    DestinoPreparacion? destino,
  ) {
    final reglas = Map<String, DestinoPreparacion>.of(porFamilia);
    if (destino == null) {
      reglas.remove(codfamilia);
    } else {
      reglas[codfamilia] = destino;
    }
    return EnrutamientoComandas(
      porFamilia: Map.unmodifiable(reglas),
      porDefecto: porDefecto,
    );
  }

  /// Copia con otro destino por defecto.
  EnrutamientoComandas conPorDefecto(DestinoPreparacion destino) =>
      EnrutamientoComandas(
        porFamilia: Map.unmodifiable(porFamilia),
        porDefecto: destino,
      );

  /// Jerarquía `codfamilia → madre` de las familias del catálogo, para
  /// [destinoDe].
  static Map<String, String?> jerarquia(Iterable<FamiliaCatalogo> familias) => {
    for (final familia in familias) familia.codfamilia: familia.madre,
  };

  Map<String, Object?> toJson() => {
    'porDefecto': porDefecto.name,
    'porFamilia': {
      for (final MapEntry(key: codfamilia, value: destino)
          in porFamilia.entries)
        codfamilia: destino.name,
    },
  };

  static DestinoPreparacion _destino(String nombre, {required String campo}) {
    for (final destino in DestinoPreparacion.values) {
      if (destino.name == nombre) return destino;
    }
    throw FormatException(
      "Campo '$campo': destino desconocido '$nombre' (válidos: "
      '${DestinoPreparacion.values.map((d) => d.name).join(', ')})',
    );
  }

  static String? _limpio(String? codfamilia) {
    final limpio = codfamilia?.trim();
    return (limpio == null || limpio.isEmpty) ? null : limpio;
  }

  @override
  List<Object?> get props => [porFamilia, porDefecto];
}
