import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import '../../inventory/inventory_models.dart';
import '../../logging/app_logger.dart';
import '../mysql_database.dart';
import '../schema/tpv_schema.dart';
import '../sql_executor.dart';

/// Resultado de [StockRepository.aplicarConsumos].
final class StockApplyResult extends Equatable {
  const StockApplyResult({
    required this.yaAplicada,
    required this.niveles,
    this.avisos = const [],
  });

  /// `true` si el diario ya contenía la operación: no se tocó nada y
  /// [niveles] refleja el estado actual.
  final bool yaAplicada;

  /// Nivel resultante de cada referencia con stock en el almacén (las
  /// `nostock` no aparecen).
  final List<NivelStock> niveles;

  /// Referencias omitidas (`nostock`), cantidades nulas, etc.
  final List<String> avisos;

  @override
  List<Object?> get props => [yaAplicada, niveles, avisos];
}

/// Datos de una variante y su producto relevantes para el stock.
final class ArticuloStockInfo extends Equatable {
  const ArticuloStockInfo({
    required this.referencia,
    required this.idproducto,
    required this.descripcion,
    required this.nostock,
    required this.ventasinstock,
    required this.secompra,
    required this.sevende,
  });

  final String referencia;
  final int idproducto;
  final String descripcion;

  /// FS no lleva stock de este producto (platos elaborados).
  final bool nostock;

  /// FS permite vender aunque el stock quede negativo.
  final bool ventasinstock;
  final bool secompra;
  final bool sevende;

  @override
  List<Object?> get props => [
    referencia,
    idproducto,
    descripcion,
    nostock,
    ventasinstock,
    secompra,
    sevende,
  ];
}

/// Señal interna: el diario ya tenía la operación. Se lanza dentro de la
/// transacción para forzar el ROLLBACK y se captura fuera; nunca sale del
/// repositorio.
final class _OperacionYaAplicada implements Exception {
  const _OperacionYaAplicada(this.referencia);
  final String referencia;
}

/// Descuento y lectura de stock de FacturaScripts por SQL directo.
///
/// [aplicarConsumos] replica exactamente lo que deja `Stock::save()` de FS
/// (informe de stock, apartado c) dentro de UNA transacción, con el diario
/// `tpv_movimientos_stock` como garantía de idempotencia (DESIGN_BRIEF §6).
final class StockRepository {
  StockRepository(this._db, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static final _log = appLogger('database.stock');
  static const _diario = TpvSchema.tableMovimientos;
  static const maxOperacionLength = 64;
  static const maxMotivoLength = 20;
  static const maxOrigenLength = 100;
  static const maxCodalmacenLength = 4;
  static const maxReferenciaLength = 30;

  final MysqlDatabase _db;
  final DateTime Function() _now;

  /// Descuenta (o devuelve) materias primas en un almacén.
  ///
  /// * [operacion]: clave idempotente (≤ 64 chars; p. ej. `<idLinea>` o
  ///   `<idLinea>:anulacion`). Si el diario ya la contiene para alguna
  ///   referencia, la transacción se deshace entera y se devuelve
  ///   `yaAplicada = true` sin tocar nada.
  /// * [consumos]: cantidad POSITIVA = consumo (resta stock); el llamador
  ///   pasa cantidades NEGATIVAS para revertir. Se agregan por referencia,
  ///   se redondean a 3 decimales (como `Stock::test()`) y se procesan en
  ///   orden alfabético para fijar el orden de bloqueo entre comanderos.
  /// * Secuencia por referencia: INSERT en el diario → resolver variante y
  ///   producto (sin `FOR UPDATE`) → `INSERT ... ON DUPLICATE KEY UPDATE`
  ///   en `stocks` (asignando `disponible` ANTES que `cantidad`, porque
  ///   MySQL evalúa el SET de izquierda a derecha y `cantidad` ya sería el
  ///   valor nuevo) → `stockfis` de `productos` (con `actualizado`) y
  ///   `variantes` → lectura del nivel resultante. Luego COMMIT.
  /// * Referencia desconocida → [ValidationException] y ROLLBACK total.
  ///   Producto `nostock = 1` → se omite `stocks` (FS no lleva su stock y
  ///   lo borraría) y se añade un aviso; el diario sí la registra.
  /// * Deadlock / lock wait timeout: `MysqlDatabase` repite la transacción.
  Future<StockApplyResult> aplicarConsumos({
    required String operacion,
    required List<ConsumoStock> consumos,
    required String codalmacen,
    required String motivo,
    String? origen,
  }) async {
    _requireLength(operacion, 'operacion', maxOperacionLength);
    _requireLength(codalmacen, 'codalmacen', maxCodalmacenLength);
    _requireLength(motivo, 'motivo', maxMotivoLength);
    if (origen != null && origen.length > maxOrigenLength) {
      throw ValidationException(
        'origen supera los $maxOrigenLength caracteres',
      );
    }
    final avisos = <String>[];
    final agregados = agregarConsumos(consumos, avisos: avisos);
    if (agregados.isEmpty) {
      avisos.add('Sin consumos que aplicar');
      return StockApplyResult(
        yaAplicada: false,
        niveles: const [],
        avisos: avisos,
      );
    }
    final creado = _now();
    try {
      final niveles = await _db.transaction((tx) async {
        final niveles = <NivelStock>[];
        for (final consumo in agregados) {
          final nivel = await _aplicarUno(
            tx,
            operacion: operacion,
            consumo: consumo,
            codalmacen: codalmacen,
            motivo: motivo,
            origen: origen,
            creado: creado,
            avisos: avisos,
          );
          if (nivel != null) niveles.add(nivel);
        }
        return niveles;
      });
      return StockApplyResult(
        yaAplicada: false,
        niveles: niveles,
        avisos: avisos,
      );
    } on _OperacionYaAplicada catch (signal) {
      _log.info(
        'Operación "$operacion" ya aplicada (diario: ${signal.referencia})',
      );
      final niveles = await leerNiveles(
        codalmacen: codalmacen,
        referencias: agregados.map((c) => c.referencia).toSet(),
      );
      return StockApplyResult(
        yaAplicada: true,
        niveles: niveles,
        avisos: avisos,
      );
    }
  }

  Future<NivelStock?> _aplicarUno(
    SqlExecutor tx, {
    required String operacion,
    required ConsumoStock consumo,
    required String codalmacen,
    required String motivo,
    required String? origen,
    required DateTime creado,
    required List<String> avisos,
  }) async {
    final referencia = consumo.referencia;
    // Delta con signo que se suma a stocks.cantidad: consumo => negativo.
    final delta = round3(-consumo.cantidad);

    // 1) Diario idempotente.
    try {
      await tx.execute(
        'INSERT INTO $_diario '
        '(operacion, referencia, codalmacen, cantidad, motivo, origen, creado) '
        'VALUES (:operacion, :referencia, :codalmacen, :cantidad, :motivo, '
        ':origen, :creado)',
        {
          'operacion': operacion,
          'referencia': referencia,
          'codalmacen': codalmacen,
          'cantidad': delta,
          'motivo': motivo,
          'origen': origen,
          'creado': creado,
        },
      );
    } on DatabaseException catch (error) {
      if (error.isDuplicateKey) throw _OperacionYaAplicada(referencia);
      rethrow;
    }

    // 2) Resolver variante y producto (sin FOR UPDATE: el bloqueo lo toma
    //    la escritura en stocks, en el mismo orden que FS).
    final articulo = await tx.execute(
      'SELECT v.idproducto, p.nostock, p.descripcion '
      'FROM variantes v JOIN productos p ON p.idproducto = v.idproducto '
      'WHERE v.referencia = :referencia',
      {'referencia': referencia},
    );
    final fila = articulo.firstOrNull;
    if (fila == null) {
      throw ValidationException(
        'Referencia desconocida en FacturaScripts: "$referencia"',
      );
    }
    final idproducto = _int(fila['idproducto']);
    if (_bool(fila['nostock'])) {
      avisos.add(
        'Referencia "$referencia" omitida: el producto es nostock '
        '(FacturaScripts no lleva su stock)',
      );
      return null;
    }

    // 3) stocks: crear la fila si falta o aplicar el delta.
    await tx.execute(
      'INSERT INTO stocks (codalmacen, referencia, idproducto, cantidad, '
      'disponible, reservada, pterecibir, stockmin, stockmax) '
      'VALUES (:codalmacen, :referencia, :idproducto, ROUND(:delta, 3), '
      'GREATEST(0, ROUND(:delta, 3)), 0, 0, 0, 0) '
      'ON DUPLICATE KEY UPDATE '
      'disponible = GREATEST(0, ROUND(COALESCE(cantidad, 0) + :delta, 3) '
      '- COALESCE(reservada, 0)), '
      'cantidad = ROUND(COALESCE(cantidad, 0) + :delta, 3)',
      {
        'codalmacen': codalmacen,
        'referencia': referencia,
        'idproducto': idproducto,
        'delta': delta,
      },
    );

    // 4) Derivados, igual que Stock::updateProductStock().
    await tx.execute(
      'UPDATE productos SET stockfis = (SELECT ROUND(COALESCE(SUM(s.cantidad), '
      '0), 3) FROM stocks s WHERE s.idproducto = :idproducto), '
      'actualizado = :ahora WHERE idproducto = :idproducto',
      {'idproducto': idproducto, 'ahora': creado},
    );
    await tx.execute(
      'UPDATE variantes SET stockfis = (SELECT ROUND(COALESCE(SUM(s.cantidad), '
      '0), 3) FROM stocks s WHERE s.idproducto = :idproducto '
      'AND s.referencia = :referencia) WHERE referencia = :referencia',
      {'idproducto': idproducto, 'referencia': referencia},
    );

    // 5) Nivel resultante.
    final nivel = await tx.execute(
      'SELECT cantidad, reservada, disponible, pterecibir, stockmin, stockmax '
      'FROM stocks WHERE codalmacen = :codalmacen AND referencia = :referencia',
      {'codalmacen': codalmacen, 'referencia': referencia},
    );
    final row = nivel.firstOrNull;
    if (row == null) {
      throw DatabaseException(
        'La fila de stocks de "$referencia" en $codalmacen no existe tras '
        'escribirla',
      );
    }
    return _nivelFromRow(
      row,
      referencia: referencia,
      codalmacen: codalmacen,
      descripcion: _stringOrNull(fila['descripcion']),
    );
  }

  /// Niveles de stock de un almacén, con la descripción del producto.
  /// [referencias] limita el resultado; [soloConMinimo] devuelve solo las
  /// filas con `stockmin > 0` (candidatas a reaprovisionamiento).
  Future<List<NivelStock>> leerNiveles({
    required String codalmacen,
    Set<String>? referencias,
    bool soloConMinimo = false,
  }) async {
    _requireLength(codalmacen, 'codalmacen', maxCodalmacenLength);
    if (referencias != null && referencias.isEmpty) return const [];
    return _db.run((db) async {
      final params = <String, Object?>{'codalmacen': codalmacen};
      final where = StringBuffer('WHERE s.codalmacen = :codalmacen');
      if (referencias != null) {
        where.write(' AND s.referencia IN (${_inList(referencias, params)})');
      }
      if (soloConMinimo) where.write(' AND s.stockmin > 0');
      final result = await db.execute(
        'SELECT s.referencia, s.codalmacen, s.cantidad, s.reservada, '
        's.disponible, s.pterecibir, s.stockmin, s.stockmax, p.descripcion '
        'FROM stocks s '
        'JOIN variantes v ON v.referencia = s.referencia '
        'JOIN productos p ON p.idproducto = v.idproducto '
        '$where ORDER BY s.referencia',
        params,
      );
      return [
        for (final row in result.rows)
          _nivelFromRow(
            row,
            referencia: _string(row['referencia']),
            codalmacen: _string(row['codalmacen']),
            descripcion: _stringOrNull(row['descripcion']),
          ),
      ];
    });
  }

  /// Consumos que el diario `tpv_movimientos_stock` registra para
  /// [operacion], agrupados por almacén y con el signo de [aplicarConsumos]
  /// (cantidad POSITIVA = consumo). Mapa vacío si la operación nunca se
  /// aplicó.
  ///
  /// Es la fuente de verdad para revertir exactamente lo que se aplicó (la
  /// receta puede haber cambiado desde entonces, o el descuento no haberse
  /// hecho nunca). Las filas a cero se omiten.
  Future<Map<String, List<ConsumoStock>>> leerConsumosAplicados(
    String operacion,
  ) async {
    _requireLength(operacion, 'operacion', maxOperacionLength);
    return _db.run((db) async {
      final result = await db.execute(
        'SELECT referencia, codalmacen, cantidad FROM $_diario '
        'WHERE operacion = :operacion ORDER BY codalmacen, referencia',
        {'operacion': operacion},
      );
      final porAlmacen = <String, List<ConsumoStock>>{};
      for (final row in result.rows) {
        // El diario guarda el delta sumado a stocks (consumo => negativo).
        final consumo = round3(-_double(row['cantidad']));
        if (consumo == 0) continue;
        porAlmacen
            .putIfAbsent(_string(row['codalmacen']), () => [])
            .add(
              ConsumoStock(
                referencia: _string(row['referencia']),
                cantidad: consumo,
              ),
            );
      }
      return porAlmacen;
    });
  }

  /// Ofertas de proveedor (`productosprov` JOIN `proveedores`) de las
  /// referencias dadas, excluyendo proveedores dados de baja
  /// (`fechabaja IS NOT NULL`).
  ///
  /// `precioNeto` = `productosprov.neto` (precio tras descuentos, que FS
  /// calcula al guardar por su modelo). Si `neto` es 0 o NULL (fila cargada
  /// sin pasar por el modelo, p. ej. importada por SQL) se usa `precio`.
  /// Las ofertas sin precio (0) se devuelven igualmente: decidir qué hacer
  /// con ellas es cosa del motor de reaprovisionamiento.
  Future<List<OfertaProveedor>> leerOfertas(Set<String> referencias) async {
    if (referencias.isEmpty) return const [];
    return _db.run((db) async {
      final params = <String, Object?>{};
      final result = await db.execute(
        'SELECT pp.referencia, pp.codproveedor, pr.nombre, pp.precio, pp.neto, '
        'pp.actualizado '
        'FROM productosprov pp '
        'JOIN proveedores pr ON pr.codproveedor = pp.codproveedor '
        'WHERE pr.fechabaja IS NULL '
        'AND pp.referencia IN (${_inList(referencias, params)}) '
        'ORDER BY pp.referencia, pp.codproveedor',
        params,
      );
      return [
        for (final row in result.rows)
          OfertaProveedor(
            referencia: _string(row['referencia']),
            codproveedor: _string(row['codproveedor']),
            nombreProveedor: _stringOrNull(row['nombre']),
            precioNeto: _precioNeto(row),
            actualizado: _dateOrNull(row['actualizado']),
          ),
      ];
    });
  }

  /// Variante + flags del producto de cada referencia (las desconocidas no
  /// aparecen).
  Future<List<ArticuloStockInfo>> leerArticulos(Set<String> referencias) async {
    if (referencias.isEmpty) return const [];
    return _db.run((db) async {
      final params = <String, Object?>{};
      final result = await db.execute(
        'SELECT v.referencia, v.idproducto, p.descripcion, p.nostock, '
        'p.ventasinstock, p.secompra, p.sevende '
        'FROM variantes v JOIN productos p ON p.idproducto = v.idproducto '
        'WHERE v.referencia IN (${_inList(referencias, params)}) '
        'ORDER BY v.referencia',
        params,
      );
      return [
        for (final row in result.rows)
          ArticuloStockInfo(
            referencia: _string(row['referencia']),
            idproducto: _int(row['idproducto']),
            descripcion: _stringOrNull(row['descripcion']) ?? '',
            nostock: _bool(row['nostock']),
            ventasinstock: _bool(row['ventasinstock']),
            // Defectos del modelo Producto de FS cuando la columna es NULL.
            secompra: _bool(row['secompra'], ifNull: true),
            sevende: _bool(row['sevende'], ifNull: true),
          ),
      ];
    });
  }

  /// Agrega por referencia, redondea a 3 decimales y ordena. Las cantidades
  /// que quedan en 0 tras agregar se omiten con aviso. Pública para que el
  /// host pueda prever qué se va a aplicar.
  static List<ConsumoStock> agregarConsumos(
    List<ConsumoStock> consumos, {
    List<String>? avisos,
  }) {
    final sumas = <String, double>{};
    for (final consumo in consumos) {
      final referencia = consumo.referencia;
      if (referencia.isEmpty || referencia.trim().isEmpty) {
        throw const ValidationException('Consumo con referencia vacía');
      }
      if (referencia.length > maxReferenciaLength) {
        throw ValidationException(
          'Referencia de consumo demasiado larga: "$referencia"',
        );
      }
      if (!consumo.cantidad.isFinite) {
        throw ValidationException(
          'Cantidad no válida para "$referencia": ${consumo.cantidad}',
        );
      }
      sumas.update(
        referencia,
        (total) => total + consumo.cantidad,
        ifAbsent: () => consumo.cantidad,
      );
    }
    final referencias = sumas.keys.toList()..sort();
    final resultado = <ConsumoStock>[];
    for (final referencia in referencias) {
      final cantidad = round3(sumas[referencia]!);
      if (cantidad == 0) {
        avisos?.add('Referencia "$referencia" omitida: cantidad neta 0');
        continue;
      }
      resultado.add(ConsumoStock(referencia: referencia, cantidad: cantidad));
    }
    return resultado;
  }

  /// Redondeo a 3 decimales (el `MAX_DECIMALS` del modelo `Stock` de FS),
  /// mitad hacia fuera de cero.
  static double round3(double value) {
    final scaled = value * 1000;
    final rounded = scaled.abs().round() * scaled.sign;
    final result = rounded / 1000;
    return result == 0 ? 0 : result;
  }

  static String _inList(Set<String> values, Map<String, Object?> params) {
    final sorted = values.toList()..sort();
    final names = <String>[];
    for (var i = 0; i < sorted.length; i++) {
      final name = 'r$i';
      params[name] = sorted[i];
      names.add(':$name');
    }
    return names.join(', ');
  }

  static void _requireLength(String value, String campo, int max) {
    if (value.isEmpty || value.trim().isEmpty) {
      throw ValidationException('$campo no puede estar vacío');
    }
    if (value.length > max) {
      throw ValidationException('$campo supera los $max caracteres');
    }
  }

  static NivelStock _nivelFromRow(
    SqlRow row, {
    required String referencia,
    required String codalmacen,
    required String? descripcion,
  }) => NivelStock(
    referencia: referencia,
    codalmacen: codalmacen,
    cantidad: _double(row['cantidad']),
    reservada: _double(row['reservada']),
    disponible: _double(row['disponible']),
    pterecibir: _double(row['pterecibir']),
    stockmin: _double(row['stockmin']),
    stockmax: _double(row['stockmax']),
    descripcion: descripcion,
  );

  static double _precioNeto(SqlRow row) {
    final neto = _double(row['neto']);
    return neto > 0 ? neto : _double(row['precio']);
  }

  static double _double(Object? value) => switch (value) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0,
    final bool b => b ? 1 : 0,
    _ => 0,
  };

  static int _int(Object? value) => switch (value) {
    final int i => i,
    final num n => n.toInt(),
    final String s =>
      int.tryParse(s) ??
          (throw DatabaseException('Valor entero no válido: "$s"')),
    _ => throw DatabaseException('Valor entero ausente (${value.runtimeType})'),
  };

  static bool _bool(Object? value, {bool ifNull = false}) => switch (value) {
    null => ifNull,
    final bool b => b,
    final num n => n != 0,
    final String s => s == '1' || s.toLowerCase() == 'true',
    _ => ifNull,
  };

  static String _string(Object? value) => switch (value) {
    final String s => s,
    null => throw const DatabaseException('Columna de texto nula inesperada'),
    _ => value.toString(),
  };

  static String? _stringOrNull(Object? value) => switch (value) {
    null => null,
    final String s => s,
    _ => value.toString(),
  };

  static DateTime? _dateOrNull(Object? value) => switch (value) {
    final DateTime d => d,
    final String s => DateTime.tryParse(s),
    _ => null,
  };
}
