/// Modelos del catálogo de venta (carta) construidos desde FacturaScripts.
///
/// El catálogo se serializa a JSON para cachearlo en disco en el host y para
/// enviarlo a los comanderos, que nunca hablan con FacturaScripts.
library;

import 'package:equatable/equatable.dart';

import '../../money/money.dart';
import '../../utils/json_map.dart';

/// Familia de productos (`familias`).
final class FamiliaCatalogo extends Equatable {
  const FamiliaCatalogo({
    required this.codfamilia,
    required this.descripcion,
    this.madre,
  });

  factory FamiliaCatalogo.fromJson(Map<String, Object?> json) =>
      FamiliaCatalogo(
        codfamilia: json.requireString('codfamilia'),
        descripcion: json.requireString('descripcion'),
        madre: json.optionalString('madre'),
      );

  final String codfamilia;
  final String descripcion;

  /// Familia padre (jerarquía de la carta), si la hay.
  final String? madre;

  Map<String, Object?> toJson() => {
    'codfamilia': codfamilia,
    'descripcion': descripcion,
    'madre': madre,
  };

  @override
  List<Object?> get props => [codfamilia, descripcion, madre];
}

/// Impuesto (`impuestos`). El IVA se identifica siempre por [codimpuesto],
/// nunca por porcentaje: FacturaScripts calcula con el código del producto.
final class ImpuestoCatalogo extends Equatable {
  const ImpuestoCatalogo({
    required this.codimpuesto,
    required this.descripcion,
    required this.ivaBp,
    this.recargoBp = 0,
    this.codsubcuentarep,
    this.activo = true,
  });

  factory ImpuestoCatalogo.fromJson(Map<String, Object?> json) =>
      ImpuestoCatalogo(
        codimpuesto: json.requireString('codimpuesto'),
        descripcion: json.requireString('descripcion'),
        ivaBp: json.requireInt('ivaBp'),
        recargoBp: json.optionalInt('recargoBp') ?? 0,
        codsubcuentarep: json.optionalString('codsubcuentarep'),
        activo: json.optionalBool('activo') ?? true,
      );

  final String codimpuesto;
  final String descripcion;

  /// Tipo de IVA en puntos básicos (`1000` = 10 %).
  final int ivaBp;

  /// Recargo de equivalencia en puntos básicos (0 en hostelería).
  final int recargoBp;

  /// Subcuenta de IVA repercutido (477xxxxxxx) para el asiento del Cierre Z.
  final String? codsubcuentarep;
  final bool activo;

  Map<String, Object?> toJson() => {
    'codimpuesto': codimpuesto,
    'descripcion': descripcion,
    'ivaBp': ivaBp,
    'recargoBp': recargoBp,
    'codsubcuentarep': codsubcuentarep,
    'activo': activo,
  };

  @override
  List<Object?> get props => [
    codimpuesto,
    descripcion,
    ivaBp,
    recargoBp,
    codsubcuentarep,
    activo,
  ];
}

/// Artículo vendible o comprable: una variante unida a su producto y al
/// impuesto del producto.
final class ArticuloCatalogo extends Equatable {
  const ArticuloCatalogo({
    required this.referencia,
    required this.idproducto,
    required this.idvariante,
    required this.descripcion,
    this.codfamilia,
    this.codimpuesto,
    required this.ivaBp,
    required this.precioNeto,
    required this.pvpCents,
    this.nostock = false,
    this.ventasinstock = true,
    this.secompra = true,
    this.sevende = true,
    this.bloqueado = false,
    this.codbarras,
    this.coste = 0,
  });

  factory ArticuloCatalogo.fromJson(Map<String, Object?> json) =>
      ArticuloCatalogo(
        referencia: json.requireString('referencia'),
        idproducto: json.requireInt('idproducto'),
        idvariante: json.requireInt('idvariante'),
        descripcion: json.requireString('descripcion'),
        codfamilia: json.optionalString('codfamilia'),
        codimpuesto: json.optionalString('codimpuesto'),
        ivaBp: json.requireInt('ivaBp'),
        precioNeto: json.requireDouble('precioNeto'),
        pvpCents: json.requireInt('pvpCents'),
        nostock: json.requireBool('nostock'),
        ventasinstock: json.requireBool('ventasinstock'),
        secompra: json.requireBool('secompra'),
        sevende: json.requireBool('sevende'),
        bloqueado: json.requireBool('bloqueado'),
        codbarras: json.optionalString('codbarras'),
        coste: json.optionalDouble('coste') ?? 0,
      );

  /// PVP con IVA en céntimos a partir del precio neto (hasta 5 decimales) y
  /// el IVA en puntos básicos, redondeando como PHP (`round()` mitad hacia
  /// fuera de cero): `10.90909` al 10 % → `1200`.
  static int pvpCentsFrom(double precioNeto, int ivaBp) =>
      roundHalfAwayFromZero(precioNeto * (10000 + ivaBp) / 10000 * 100);

  /// Referencia de la variante (clave de `stocks` y de las líneas de factura).
  final String referencia;
  final int idproducto;
  final int idvariante;
  final String descripcion;
  final String? codfamilia;

  /// `productos.codimpuesto` (el impuesto siempre es del producto).
  final String? codimpuesto;

  /// IVA en puntos básicos (resuelto desde [codimpuesto]).
  final int ivaBp;

  /// `variantes.precio`: precio sin IVA, hasta 5 decimales. Es lo que se
  /// envía como `pvpunitario` en las líneas de factura.
  final double precioNeto;

  /// Precio con IVA en céntimos, el que se muestra en la carta.
  final int pvpCents;

  /// FacturaScripts no lleva stock de este producto (platos de carta).
  final bool nostock;

  /// Permite vender sin existencias; si es `false` y `nostock` también,
  /// FacturaScripts rechaza la factura cuando el stock se agota.
  final bool ventasinstock;
  final bool secompra;
  final bool sevende;
  final bool bloqueado;
  final String? codbarras;

  /// `variantes.coste`: coste de compra (escandallos, pedidos a proveedor).
  final double coste;

  /// Aparece en la carta del TPV. La API no valida ninguno de los dos flags:
  /// el filtro es responsabilidad del TPV.
  bool get vendible => sevende && !bloqueado;

  Map<String, Object?> toJson() => {
    'referencia': referencia,
    'idproducto': idproducto,
    'idvariante': idvariante,
    'descripcion': descripcion,
    'codfamilia': codfamilia,
    'codimpuesto': codimpuesto,
    'ivaBp': ivaBp,
    'precioNeto': precioNeto,
    'pvpCents': pvpCents,
    'nostock': nostock,
    'ventasinstock': ventasinstock,
    'secompra': secompra,
    'sevende': sevende,
    'bloqueado': bloqueado,
    'codbarras': codbarras,
    'coste': coste,
  };

  @override
  List<Object?> get props => [
    referencia,
    idproducto,
    idvariante,
    descripcion,
    codfamilia,
    codimpuesto,
    ivaBp,
    precioNeto,
    pvpCents,
    nostock,
    ventasinstock,
    secompra,
    sevende,
    bloqueado,
    codbarras,
    coste,
  ];
}

/// Foto completa del catálogo en un instante.
final class CatalogSnapshot extends Equatable {
  const CatalogSnapshot({
    required this.familias,
    required this.impuestos,
    required this.articulos,
    required this.avisos,
    required this.obtenidoEn,
  });

  /// Lanza [FormatException] si el JSON no tiene la forma esperada.
  factory CatalogSnapshot.fromJson(Map<String, Object?> json) =>
      CatalogSnapshot(
        familias: [
          for (final item in json.requireMapList('familias'))
            FamiliaCatalogo.fromJson(item),
        ],
        impuestos: [
          for (final item in json.requireMapList('impuestos'))
            ImpuestoCatalogo.fromJson(item),
        ],
        articulos: [
          for (final item in json.requireMapList('articulos'))
            ArticuloCatalogo.fromJson(item),
        ],
        avisos: [
          for (final item in json.requireList('avisos')) item.toString(),
        ],
        obtenidoEn: DateTime.parse(json.requireString('obtenidoEn')),
      );

  final List<FamiliaCatalogo> familias;
  final List<ImpuestoCatalogo> impuestos;
  final List<ArticuloCatalogo> articulos;

  /// Incidencias detectadas al construir el catálogo (variantes huérfanas,
  /// impuestos desconocidos, productos que FacturaScripts podría rechazar).
  final List<String> avisos;
  final DateTime obtenidoEn;

  /// Solo los artículos de la carta.
  List<ArticuloCatalogo> get vendibles => [
    for (final a in articulos)
      if (a.vendible) a,
  ];

  ArticuloCatalogo? porReferencia(String referencia) {
    for (final articulo in articulos) {
      if (articulo.referencia == referencia) return articulo;
    }
    return null;
  }

  ImpuestoCatalogo? impuesto(String codimpuesto) {
    for (final impuesto in impuestos) {
      if (impuesto.codimpuesto == codimpuesto) return impuesto;
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'familias': [for (final f in familias) f.toJson()],
    'impuestos': [for (final i in impuestos) i.toJson()],
    'articulos': [for (final a in articulos) a.toJson()],
    'avisos': avisos,
    'obtenidoEn': obtenidoEn.toIso8601String(),
  };

  @override
  List<Object?> get props => [
    familias,
    impuestos,
    articulos,
    avisos,
    obtenidoEn,
  ];
}
