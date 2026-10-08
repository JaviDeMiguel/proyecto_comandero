/// Carga del catálogo (familias, impuestos, productos y variantes) desde
/// FacturaScripts y su unión en artículos listos para la carta.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../money/money.dart';
import '../fs_api.dart';
import '../fs_resources.dart';
import '../fs_values.dart';
import 'catalog_models.dart';

export 'catalog_models.dart';

/// Construye un [CatalogSnapshot] con cuatro listados paginados.
///
/// No existe la tabla `articulos`: el maestro es `productos` (flags, familia,
/// impuesto, descripción) + `variantes` (referencia, precio neto, coste,
/// código de barras). El IVA se toma SIEMPRE del producto.
final class FsCatalogService {
  FsCatalogService(this._api);

  final FsApi _api;
  final Logger _log = appLogger('facturascripts.catalog');

  /// Descarga el catálogo completo.
  ///
  /// [codimpuestoPorDefecto] (de `settings/default`) resuelve el IVA de los
  /// productos cuyo `codimpuesto` falta o no existe en `impuestos`; sin él
  /// esos artículos quedan con IVA 0 y un aviso. [now] fija `obtenidoEn`.
  ///
  /// Lanza [ErpApiException] si falla la API o un registro es ininterpretable
  /// (código 200, `kind` = `unexpected`).
  Future<CatalogSnapshot> cargar({
    DateTime Function()? now,
    String? codimpuestoPorDefecto,
  }) async {
    final avisos = <String>[];

    final familiasRaw = await _api.listAll(
      FsResources.familias,
      sortBy: 'codfamilia',
    );
    final impuestosRaw = await _api.listAll(
      FsResources.impuestos,
      sortBy: 'codimpuesto',
    );
    final productosRaw = await _api.listAll(
      FsResources.productos,
      sortBy: 'idproducto',
    );
    final variantesRaw = await _api.listAll(
      FsResources.variantes,
      sortBy: 'idvariante',
    );

    final familias = [
      for (final r in familiasRaw) _parse(FsResources.familias, r, _familia),
    ];
    final impuestos = [
      for (final r in impuestosRaw) _parse(FsResources.impuestos, r, _impuesto),
    ];
    final impuestosPorCodigo = {for (final i in impuestos) i.codimpuesto: i};
    final productosPorId = <int, FsRecord>{};
    for (final record in productosRaw) {
      final id = _parse(
        FsResources.productos,
        record,
        (r) => r.fsRequireInt('idproducto'),
      );
      productosPorId[id] = record;
    }

    final impuestoDefecto = codimpuestoPorDefecto == null
        ? null
        : impuestosPorCodigo[codimpuestoPorDefecto];
    if (codimpuestoPorDefecto != null && impuestoDefecto == null) {
      avisos.add(
        "el impuesto por defecto '$codimpuestoPorDefecto' de los ajustes no "
        'existe en impuestos',
      );
    }

    final articulos = <ArticuloCatalogo>[];
    for (final varianteRaw in variantesRaw) {
      final variante = _parse(FsResources.variantes, varianteRaw, _variante);
      final productoRaw = productosPorId[variante.idproducto];
      if (productoRaw == null) {
        avisos.add(
          "variante '${variante.referencia}' (idvariante ${variante.idvariante}) "
          'sin producto ${variante.idproducto}; ignorada',
        );
        continue;
      }
      final producto = _parse(FsResources.productos, productoRaw, _producto);

      var ivaBp = 0;
      final codimpuesto = producto.codimpuesto;
      final impuesto = codimpuesto == null
          ? null
          : impuestosPorCodigo[codimpuesto];
      if (impuesto != null) {
        ivaBp = impuesto.ivaBp;
      } else if (impuestoDefecto != null) {
        ivaBp = impuestoDefecto.ivaBp;
        avisos.add(
          "producto '${producto.referencia}' con impuesto "
          "${codimpuesto == null ? 'vacío' : "'$codimpuesto' desconocido"}; "
          "se aplica el impuesto por defecto '${impuestoDefecto.codimpuesto}'",
        );
      } else {
        avisos.add(
          "producto '${producto.referencia}' con impuesto "
          "${codimpuesto == null ? 'vacío' : "'$codimpuesto' desconocido"}; "
          'se aplica IVA 0',
        );
      }

      final articulo = ArticuloCatalogo(
        referencia: variante.referencia,
        idproducto: producto.idproducto,
        idvariante: variante.idvariante,
        descripcion: producto.descripcion,
        codfamilia: producto.codfamilia,
        codimpuesto: codimpuesto,
        ivaBp: ivaBp,
        precioNeto: variante.precio,
        pvpCents: ArticuloCatalogo.pvpCentsFrom(variante.precio, ivaBp),
        nostock: producto.nostock,
        ventasinstock: producto.ventasinstock,
        secompra: producto.secompra,
        sevende: producto.sevende,
        bloqueado: producto.bloqueado,
        codbarras: variante.codbarras,
        coste: variante.coste,
      );
      articulos.add(articulo);

      if (articulo.vendible && !articulo.nostock && !articulo.ventasinstock) {
        avisos.add(
          'producto ${articulo.referencia} vendible con nostock=0 y '
          'ventasinstock=0 (FacturaScripts rechazará la factura si se agota)',
        );
      }
    }

    _log.info(
      'Catálogo cargado: ${familias.length} familias, ${impuestos.length} '
      'impuestos, ${articulos.length} artículos, ${avisos.length} avisos',
    );
    return CatalogSnapshot(
      familias: familias,
      impuestos: impuestos,
      articulos: articulos,
      avisos: avisos,
      obtenidoEn: (now ?? DateTime.now)(),
    );
  }

  // ---------------------------------------------------------------------------

  static FamiliaCatalogo _familia(FsRecord r) => FamiliaCatalogo(
    codfamilia: r.fsRequireString('codfamilia'),
    descripcion: r.fsString('descripcion') ?? '',
    madre: r.fsNonEmptyString('madre'),
    // Columna del plugin de hostelería; sin el plugin no viene y es `null`.
    destino: FamiliaCatalogo.normalizarDestino(r['tpv_destino']),
  );

  static ImpuestoCatalogo _impuesto(FsRecord r) => ImpuestoCatalogo(
    codimpuesto: r.fsRequireString('codimpuesto'),
    descripcion: r.fsString('descripcion') ?? '',
    ivaBp: basisPointsFromPercent(r.fsDouble('iva') ?? 0),
    recargoBp: basisPointsFromPercent(r.fsDouble('recargo') ?? 0),
    codsubcuentarep: r.fsNonEmptyString('codsubcuentarep'),
    activo: r.fsBool('activo', orElse: true),
  );

  static _Producto _producto(FsRecord r) => _Producto(
    idproducto: r.fsRequireInt('idproducto'),
    referencia: r.fsString('referencia') ?? '',
    descripcion: r.fsString('descripcion') ?? '',
    codfamilia: r.fsNonEmptyString('codfamilia'),
    codimpuesto: r.fsNonEmptyString('codimpuesto'),
    nostock: r.fsBool('nostock'),
    ventasinstock: r.fsBool('ventasinstock'),
    secompra: r.fsBool('secompra'),
    sevende: r.fsBool('sevende'),
    bloqueado: r.fsBool('bloqueado'),
  );

  static _Variante _variante(FsRecord r) => _Variante(
    idvariante: r.fsRequireInt('idvariante'),
    idproducto: r.fsRequireInt('idproducto'),
    referencia: r.fsRequireString('referencia'),
    precio: r.fsDouble('precio') ?? 0,
    coste: r.fsDouble('coste') ?? 0,
    codbarras: r.fsNonEmptyString('codbarras'),
  );

  T _parse<T>(String resource, FsRecord record, T Function(FsRecord) build) {
    try {
      return build(record);
    } on FormatException catch (error) {
      throw ErpApiException(
        'Registro de $resource no interpretable: ${error.message}',
        statusCode: 200,
        cause: error,
      );
    }
  }
}

final class _Producto {
  const _Producto({
    required this.idproducto,
    required this.referencia,
    required this.descripcion,
    required this.codfamilia,
    required this.codimpuesto,
    required this.nostock,
    required this.ventasinstock,
    required this.secompra,
    required this.sevende,
    required this.bloqueado,
  });

  final int idproducto;
  final String referencia;
  final String descripcion;
  final String? codfamilia;
  final String? codimpuesto;
  final bool nostock;
  final bool ventasinstock;
  final bool secompra;
  final bool sevende;
  final bool bloqueado;
}

final class _Variante {
  const _Variante({
    required this.idvariante,
    required this.idproducto,
    required this.referencia,
    required this.precio,
    required this.coste,
    required this.codbarras,
  });

  final int idvariante;
  final int idproducto;
  final String referencia;
  final double precio;
  final double coste;
  final String? codbarras;
}
