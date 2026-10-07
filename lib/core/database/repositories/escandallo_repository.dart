import '../../errors/app_exception.dart';
import '../../inventory/inventory_models.dart';
import '../mysql_database.dart';
import '../schema/tpv_schema.dart';
import '../sql_executor.dart';

/// Acceso a `tpv_escandallos` (recetas con merma).
///
/// Las reglas de negocio se validan aquí ANTES de tocar la base de datos
/// (lanzan [ValidationException]) y los errores de integridad que solo el
/// servidor puede detectar se traducen con un mensaje útil:
///
/// * 1452 (FK): la referencia de plato o ingrediente no existe en
///   `variantes`;
/// * 1451 (RESTRICT): FS u otro proceso intenta borrar una materia prima
///   usada en recetas (no debería llegar por este repositorio, pero se
///   traduce igualmente);
/// * 3819 (CHECK): cantidad o merma fuera de rango, por si la validación
///   local se saltó.
final class EscandalloRepository {
  EscandalloRepository(this._db);

  static const _table = TpvSchema.tableEscandallos;
  static const maxReferenciaLength = 30;

  static const _select =
      'SELECT ref_plato, ref_ingrediente, cantidad, merma FROM $_table';

  final MysqlDatabase _db;

  /// Todas las líneas de receta, ordenadas por plato e ingrediente.
  Future<List<RecetaLinea>> listAll() => _db.run((db) async {
    final result = await db.execute(
      '$_select ORDER BY ref_plato, ref_ingrediente',
    );
    return result.rows.map(_fromRow).toList(growable: false);
  });

  /// Líneas de receta de un plato.
  Future<List<RecetaLinea>> byPlato(String refPlato) async {
    _validateReferencia(refPlato, 'refPlato');
    return _db.run((db) async {
      final result = await db.execute(
        '$_select WHERE ref_plato = :plato ORDER BY ref_ingrediente',
        {'plato': refPlato},
      );
      return result.rows.map(_fromRow).toList(growable: false);
    });
  }

  /// Inserta o actualiza una línea (clave: plato + ingrediente).
  Future<void> upsert(RecetaLinea linea) async {
    validate(linea);
    return _db.run((db) => _guard(() => _upsert(db, linea)));
  }

  /// Borra una línea. No falla si no existía.
  Future<void> delete(String refPlato, String refIngrediente) async {
    _validateReferencia(refPlato, 'refPlato');
    _validateReferencia(refIngrediente, 'refIngrediente');
    return _db.run(
      (db) => _guard(
        () => db.execute(
          'DELETE FROM $_table '
          'WHERE ref_plato = :plato AND ref_ingrediente = :ingrediente',
          {'plato': refPlato, 'ingrediente': refIngrediente},
        ),
      ),
    );
  }

  /// Sustituye la receta completa de un plato en una transacción: borra las
  /// líneas actuales e inserta [lineas]. Una lista vacía deja el plato sin
  /// receta. Todas las líneas deben ser de [refPlato].
  Future<void> replacePlato(String refPlato, List<RecetaLinea> lineas) async {
    _validateReferencia(refPlato, 'refPlato');
    final ingredientes = <String>{};
    for (final linea in lineas) {
      validate(linea);
      if (linea.refPlato != refPlato) {
        throw ValidationException(
          'La línea de "${linea.refPlato}" no pertenece al plato "$refPlato"',
        );
      }
      if (!ingredientes.add(linea.refIngrediente)) {
        throw ValidationException(
          'Ingrediente repetido en la receta de "$refPlato": '
          '"${linea.refIngrediente}"',
        );
      }
    }
    return _db.transaction(
      (tx) => _guard(() async {
        await tx.execute('DELETE FROM $_table WHERE ref_plato = :plato', {
          'plato': refPlato,
        });
        for (final linea in lineas) {
          await _upsert(tx, linea);
        }
      }),
    );
  }

  /// Reglas de una línea de receta. Pública para que la UI valide antes de
  /// enviar.
  static void validate(RecetaLinea linea) {
    _validateReferencia(linea.refPlato, 'refPlato');
    _validateReferencia(linea.refIngrediente, 'refIngrediente');
    if (linea.refPlato == linea.refIngrediente) {
      throw ValidationException(
        'Un plato no puede ser ingrediente de sí mismo ("${linea.refPlato}")',
      );
    }
    if (!linea.cantidadNeta.isFinite || linea.cantidadNeta <= 0) {
      throw ValidationException(
        'La cantidad de "${linea.refIngrediente}" en "${linea.refPlato}" '
        'debe ser mayor que 0 (recibido ${linea.cantidadNeta})',
      );
    }
    if (!linea.mermaPct.isFinite ||
        linea.mermaPct < 0 ||
        linea.mermaPct >= 100) {
      throw ValidationException(
        'La merma de "${linea.refIngrediente}" en "${linea.refPlato}" debe '
        'estar en [0, 100) (recibido ${linea.mermaPct})',
      );
    }
  }

  static void _validateReferencia(String referencia, String campo) {
    if (referencia.isEmpty || referencia.trim().isEmpty) {
      throw ValidationException('$campo no puede estar vacío');
    }
    if (referencia.length > maxReferenciaLength) {
      throw ValidationException(
        '$campo supera los $maxReferenciaLength caracteres de '
        'variantes.referencia: "$referencia"',
      );
    }
  }

  static Future<void> _upsert(SqlExecutor db, RecetaLinea linea) async {
    await db.execute(
      'INSERT INTO $_table (ref_plato, ref_ingrediente, cantidad, merma) '
      'VALUES (:plato, :ingrediente, :cantidad, :merma) '
      'ON DUPLICATE KEY UPDATE cantidad = :cantidad, merma = :merma',
      {
        'plato': linea.refPlato,
        'ingrediente': linea.refIngrediente,
        'cantidad': linea.cantidadNeta,
        'merma': linea.mermaPct,
      },
    );
  }

  static RecetaLinea _fromRow(SqlRow row) => RecetaLinea(
    refPlato: _string(row, 'ref_plato'),
    refIngrediente: _string(row, 'ref_ingrediente'),
    cantidadNeta: _double(row, 'cantidad'),
    mermaPct: _double(row, 'merma'),
  );

  static String _string(SqlRow row, String column) => switch (row[column]) {
    final String s => s,
    final Object v => v.toString(),
    null => throw DatabaseException('Columna $column nula en $_table'),
  };

  static double _double(SqlRow row, String column) => switch (row[column]) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s) ?? 0,
    _ => 0,
  };

  /// Traduce los errores de integridad del servidor a [ValidationException].
  static Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on DatabaseException catch (error, stackTrace) {
      final translated = translateIntegrityError(error);
      if (translated == null) rethrow;
      Error.throwWithStackTrace(translated, stackTrace);
    }
  }

  /// Convierte 1452 / 1451 / 3819 en [ValidationException]; `null` si el
  /// error no es de integridad.
  static ValidationException? translateIntegrityError(DatabaseException e) =>
      switch (e.errorCode) {
        1452 => ValidationException(
          'La referencia no existe en variantes de FacturaScripts '
          '(plato o ingrediente desconocido)',
          cause: e,
        ),
        1451 => ValidationException(
          'La referencia está en uso en recetas (tpv_escandallos) y no '
          'puede borrarse',
          cause: e,
        ),
        3819 => ValidationException(
          'Cantidad o merma fuera de rango según las restricciones de '
          'tpv_escandallos',
          cause: e,
        ),
        _ => null,
      };
}
