import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart'
    show FamiliaCatalogo;
import '../../../core/utils/json_map.dart';
import 'linea_comanda.dart';

/// De dónde sale el destino de preparación de una familia.
enum OrigenDestino {
  /// Regla explícita del TPV (pantalla de enrutamiento).
  reglaTpv,

  /// Destino de la familia en el ERP (`familias.tpv_destino`).
  erp,

  /// Ningún nivel de la jerarquía define destino: se usa el destino por
  /// defecto del enrutamiento.
  porDefecto,
}

/// Resultado de resolver el destino de una familia: el destino, la familia
/// del nivel que lo define (la propia o una antecesora; `null` si es el
/// destino por defecto) y si lo define una regla del TPV o el ERP.
final class ResolucionDestino extends Equatable {
  const ResolucionDestino({
    required this.destino,
    required this.origen,
    this.familia,
  });

  final DestinoPreparacion destino;
  final OrigenDestino origen;

  /// Familia cuyo nivel fija el destino (`null` con
  /// [OrigenDestino.porDefecto]).
  final String? familia;

  @override
  List<Object?> get props => [destino, origen, familia];
}

/// Reglas de enrutamiento de las comandas a los puestos de preparación
/// (cocina / barra) según la familia del artículo en FacturaScripts.
///
/// Las reglas se definen por `codfamilia` y se **heredan** por la jerarquía
/// de familias (`familias.madre`): una subfamilia sin regla propia usa la de
/// su madre, la de su abuela... y, si ninguna antecesora tiene regla, el
/// destino [porDefecto]. Así basta con decir "Bebidas → barra" para que
/// "Refrescos" o "Cervezas" (subfamilias de Bebidas) salgan por barra.
///
/// El ERP también puede definir el destino de cada familia
/// (`familias.tpv_destino`, columna del plugin de hostelería; ver
/// [destinosErp]). La precedencia es **por nivel**: se recorre la jerarquía
/// desde la familia del artículo hacia sus madres y, en cada nivel, manda
/// primero la regla del TPV y después el destino del ERP; si ningún nivel
/// define nada, se usa [porDefecto]. Así una regla del TPV en "Cervezas"
/// sobrescribe el destino del ERP de "Cervezas" y el de "Bebidas", pero el
/// destino del ERP de "Cervezas" gana a una regla del TPV en "Bebidas".
///
/// El host es la autoridad: fija el destino de cada línea con su
/// enrutamiento y publica a los comanderos el enrutamiento efectivo
/// ([conDestinosErp]) en el snapshot de sala.
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
  /// [jerarquia]); sin ella no hay herencia. [erp] son los destinos que
  /// define el ERP por familia (ver [destinosErp]). Un ciclo en la jerarquía
  /// (datos corruptos del ERP) no cuelga la búsqueda: se corta al repetir
  /// una familia y se usa [porDefecto].
  DestinoPreparacion destinoDe(
    String? codfamilia, {
    Map<String, String?> madreDe = const {},
    Map<String, DestinoPreparacion> erp = const {},
  }) => origenDe(codfamilia, madreDe: madreDe, erp: erp).destino;

  /// Como [destinoDe], pero indica también de qué nivel sale el destino y
  /// si lo fija una regla del TPV, el ERP o el valor por defecto. La
  /// pantalla de configuración lo usa para explicar cada destino.
  ResolucionDestino origenDe(
    String? codfamilia, {
    Map<String, String?> madreDe = const {},
    Map<String, DestinoPreparacion> erp = const {},
  }) {
    final visitadas = <String>{};
    var actual = _limpio(codfamilia);
    while (actual != null && visitadas.add(actual)) {
      final regla = porFamilia[actual];
      if (regla != null) {
        return ResolucionDestino(
          destino: regla,
          origen: OrigenDestino.reglaTpv,
          familia: actual,
        );
      }
      final delErp = erp[actual];
      if (delErp != null) {
        return ResolucionDestino(
          destino: delErp,
          origen: OrigenDestino.erp,
          familia: actual,
        );
      }
      actual = _limpio(madreDe[actual]);
    }
    return ResolucionDestino(
      destino: porDefecto,
      origen: OrigenDestino.porDefecto,
    );
  }

  /// Enrutamiento efectivo con los destinos del ERP de [familias] ya
  /// incorporados como reglas, para publicarlo a los comanderos.
  ///
  /// Cada familia del catálogo cuyo destino sale de una regla del TPV o del
  /// ERP (propia o heredada) queda con una regla explícita igual a su
  /// destino resuelto; las que caen en [porDefecto] no llevan regla (ni
  /// ninguna de sus antecesoras, así que siguen resolviendo a
  /// [porDefecto]). Las reglas de familias que no están en el catálogo se
  /// conservan. Quien lo reciba obtiene para cualquier familia de
  /// [familias] el mismo destino que el host, tenga o no la jerarquía y los
  /// destinos del ERP (la operación es idempotente). Sin destinos en el ERP
  /// devuelve este mismo enrutamiento.
  EnrutamientoComandas conDestinosErp(Iterable<FamiliaCatalogo> familias) {
    final erp = destinosErp(familias);
    if (erp.isEmpty) return this;
    final madreDe = jerarquia(familias);
    final reglas = Map<String, DestinoPreparacion>.of(porFamilia);
    for (final familia in familias) {
      final codfamilia = _limpio(familia.codfamilia);
      if (codfamilia == null) continue;
      final resolucion = origenDe(codfamilia, madreDe: madreDe, erp: erp);
      if (resolucion.origen != OrigenDestino.porDefecto) {
        reglas[codfamilia] = resolucion.destino;
      }
    }
    return EnrutamientoComandas(
      porFamilia: Map.unmodifiable(reglas),
      porDefecto: porDefecto,
    );
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

  /// Destinos que define el ERP (`familias.tpv_destino`) por `codfamilia`,
  /// para [destinoDe]. Las familias sin destino (heredan) no figuran.
  static Map<String, DestinoPreparacion> destinosErp(
    Iterable<FamiliaCatalogo> familias,
  ) => {
    for (final familia in familias)
      familia.codfamilia: ?destinoDeErp(familia.destino),
  };

  /// Traduce un valor de `familias.tpv_destino` (`'cocina'` / `'barra'`) a
  /// [DestinoPreparacion]; cualquier otro valor es `null` (hereda).
  static DestinoPreparacion? destinoDeErp(String? valor) =>
      switch (FamiliaCatalogo.normalizarDestino(valor)) {
        FamiliaCatalogo.destinoCocina => DestinoPreparacion.cocina,
        FamiliaCatalogo.destinoBarra => DestinoPreparacion.barra,
        _ => null,
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
