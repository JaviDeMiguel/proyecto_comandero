import 'package:equatable/equatable.dart';

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../mysql_database.dart';
import '../sql_executor.dart';

/// DDL de las tablas propias del TPV en la base de datos de FacturaScripts.
///
/// Decisiones (DESIGN_BRIEF §6 e informe de stock, apartados a, b y e):
///
/// * Prefijo `tpv_` en tablas, índices y constraints: FacturaScripts solo
///   revisa las tablas con XML propio y borra los índices cuyo nombre
///   contiene `fs_`; nada con `tpv_` le concierne.
/// * `CREATE TABLE IF NOT EXISTS` + `ENGINE=InnoDB`: DDL idempotente.
/// * Las columnas de referencia copian charset y collation de
///   `variantes.referencia` (parámetros de [TpvSchema]): MySQL exige que
///   coincidan con la columna referenciada por la FK.
/// * FK plato `ON DELETE CASCADE` (sin plato no hay receta) e ingrediente
///   `ON DELETE RESTRICT` (no se puede borrar una materia prima usada en
///   recetas); ambas `ON UPDATE CASCADE` porque FS renombra referencias con
///   un `UPDATE` simple y confía en la cascada.
/// * Sin CHECK `ref_plato <> ref_ingrediente`: MySQL 8 lo rechaza (errno
///   3823) en columnas con acción referencial `ON UPDATE CASCADE`. Esa regla
///   la valida `EscandalloRepository`. Los CHECK de `cantidad` y `merma`
///   sí van en el DDL (MySQL ≥ 8.0.16 los aplica; versiones anteriores y
///   MariaDB < 10.2 los ignoran sin error).
/// * `tpv_movimientos_stock` no tiene FK a tablas de FS: es un diario y debe
///   sobrevivir a borrados de referencias.
final class TpvSchema {
  const TpvSchema({
    this.charset = defaultCharset,
    this.collation = defaultCollation,
  });

  static const defaultCharset = 'utf8mb4';
  static const defaultCollation = 'utf8mb4_unicode_520_ci';

  static const tableEscandallos = 'tpv_escandallos';
  static const tableMovimientos = 'tpv_movimientos_stock';
  static const tables = [tableEscandallos, tableMovimientos];

  final String charset;
  final String collation;

  /// Tipo de las columnas que referencian `variantes.referencia`.
  String get _referenciaType =>
      'VARCHAR(30) CHARACTER SET $charset COLLATE $collation';

  String get _tableOptions =>
      'ENGINE=InnoDB DEFAULT CHARSET=$charset COLLATE=$collation';

  String get createEscandallos =>
      '''
CREATE TABLE IF NOT EXISTS $tableEscandallos (
  id INT NOT NULL AUTO_INCREMENT,
  ref_plato $_referenciaType NOT NULL,
  ref_ingrediente $_referenciaType NOT NULL,
  cantidad DOUBLE NOT NULL,
  merma DOUBLE NOT NULL DEFAULT 0,
  observaciones VARCHAR(255) NULL,
  creado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY tpv_uniq_escandallos_plato_ingrediente (ref_plato, ref_ingrediente),
  KEY tpv_idx_escandallos_ingrediente (ref_ingrediente),
  CONSTRAINT tpv_chk_escandallos_cantidad CHECK (cantidad > 0),
  CONSTRAINT tpv_chk_escandallos_merma CHECK (merma >= 0 AND merma < 100),
  CONSTRAINT tpv_fk_escandallos_plato FOREIGN KEY (ref_plato)
    REFERENCES variantes (referencia) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT tpv_fk_escandallos_ingrediente FOREIGN KEY (ref_ingrediente)
    REFERENCES variantes (referencia) ON DELETE RESTRICT ON UPDATE CASCADE
) $_tableOptions;''';

  String get createMovimientos =>
      '''
CREATE TABLE IF NOT EXISTS $tableMovimientos (
  id BIGINT NOT NULL AUTO_INCREMENT,
  operacion VARCHAR(64) NOT NULL,
  referencia $_referenciaType NOT NULL,
  codalmacen VARCHAR(4) NOT NULL,
  cantidad DOUBLE NOT NULL,
  motivo VARCHAR(20) NOT NULL,
  origen VARCHAR(100) NULL,
  creado DATETIME NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY tpv_uniq_movimientos_operacion (operacion, referencia, codalmacen),
  KEY tpv_idx_movimientos_referencia (referencia, codalmacen, creado)
) $_tableOptions;''';

  /// Sentencias en orden de creación.
  List<String> get statements => [createEscandallos, createMovimientos];

  /// Guion completo, equivalente a `sql/tpv_schema.sql` para los parámetros
  /// por defecto.
  String get script => '${statements.join('\n\n')}\n';
}

/// Definición observada de `variantes.referencia` en `information_schema`.
final class ReferenciaColumnInfo extends Equatable {
  const ReferenciaColumnInfo({
    required this.columnType,
    required this.charset,
    required this.collation,
    required this.hasUniqueIndex,
  });

  /// P. ej. `varchar(30)`.
  final String columnType;
  final String? charset;
  final String? collation;

  /// Existe `uniq_variantes_referencia` (o cualquier UNIQUE/PK sobre la
  /// columna): sin índice único la FK no puede crearse.
  final bool hasUniqueIndex;

  @override
  List<Object?> get props => [columnType, charset, collation, hasUniqueIndex];
}

/// Informe de [TpvSchemaMigrator.inspect] / [TpvSchemaMigrator.ensure].
final class SchemaInspection extends Equatable {
  const SchemaInspection({
    required this.variantesExists,
    this.referencia,
    required this.existingTables,
    required this.schema,
    this.warnings = const [],
  });

  /// `false` = instalación de FacturaScripts no soportada (antigua o sin
  /// datos).
  final bool variantesExists;
  final ReferenciaColumnInfo? referencia;

  /// Tablas `tpv_*` que ya existen.
  final Set<String> existingTables;

  /// Esquema ajustado a la definición real de `variantes.referencia`.
  final TpvSchema schema;

  /// Avisos legibles (collation distinta a la esperada, falta el UNIQUE...).
  final List<String> warnings;

  Set<String> get missingTables =>
      TpvSchema.tables.toSet().difference(existingTables);

  bool get isComplete => variantesExists && missingTables.isEmpty;

  @override
  List<Object?> get props => [
    variantesExists,
    referencia,
    existingTables,
    schema.charset,
    schema.collation,
    warnings,
  ];
}

/// Crea las tablas `tpv_*` adaptando el DDL a la instalación real.
final class TpvSchemaMigrator {
  TpvSchemaMigrator(this._db);

  static final _log = appLogger('database.schema');

  final MysqlDatabase _db;

  /// Lee en `information_schema` la definición de `variantes.referencia` y
  /// qué tablas `tpv_*` existen. No modifica nada.
  Future<SchemaInspection> inspect() => _db.run(_inspect);

  /// Crea las tablas que falten con el DDL ajustado a la instalación. Lanza
  /// [ConfigException] si no existe `variantes` (FacturaScripts antiguo o
  /// base de datos vacía) o si `referencia` no tiene índice único (la FK
  /// fallaría: `FS_DB_FOREIGN_KEYS = false`).
  Future<SchemaInspection> ensure() => _db.run((db) async {
    final before = await _inspect(db);
    if (!before.variantesExists) {
      throw ConfigException(
        'La base de datos "${_db.config.database}" no tiene la tabla '
        '"variantes": no es una instalación de FacturaScripts soportada '
        '(se requiere 2018+ con productos/variantes/stocks)',
      );
    }
    if (before.missingTables.isEmpty) return before;
    final referencia = before.referencia;
    if (referencia != null && !referencia.hasUniqueIndex) {
      throw ConfigException(
        'variantes.referencia no tiene índice UNIQUE: la clave ajena de '
        'tpv_escandallos no puede crearse (¿FS_DB_FOREIGN_KEYS = false?)',
      );
    }
    for (final statement in before.schema.statements) {
      _log.info('Creando tabla: ${statement.split('(').first.trim()}');
      await db.execute(statement);
    }
    return _inspect(db);
  });

  Future<SchemaInspection> _inspect(SqlExecutor db) async {
    final warnings = <String>[];
    final columnRows = await db.execute(
      'SELECT COLUMN_TYPE, CHARACTER_SET_NAME, COLLATION_NAME '
      'FROM information_schema.COLUMNS '
      'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :tabla '
      'AND COLUMN_NAME = :columna',
      {'tabla': 'variantes', 'columna': 'referencia'},
    );
    final tableRows = await db.execute(
      'SELECT TABLE_NAME FROM information_schema.TABLES '
      'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME IN (:t1, :t2)',
      {'t1': TpvSchema.tableEscandallos, 't2': TpvSchema.tableMovimientos},
    );
    final existing = {
      for (final row in tableRows.rows)
        if (row['TABLE_NAME'] case final String name) name.toLowerCase(),
    };

    final column = columnRows.firstOrNull;
    if (column == null) {
      warnings.add('No existe la tabla variantes (o no es visible)');
      return SchemaInspection(
        variantesExists: false,
        existingTables: existing,
        schema: const TpvSchema(),
        warnings: warnings,
      );
    }

    final uniqueRows = await db.execute(
      'SELECT COUNT(*) AS n FROM information_schema.STATISTICS '
      'WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = :tabla '
      'AND COLUMN_NAME = :columna AND NON_UNIQUE = 0 AND SEQ_IN_INDEX = 1',
      {'tabla': 'variantes', 'columna': 'referencia'},
    );
    final uniqueCount = switch (uniqueRows.firstOrNull?['n']) {
      final int n => n,
      final double n => n.toInt(),
      final String n => int.tryParse(n) ?? 0,
      _ => 0,
    };

    final columnType = _asString(column['COLUMN_TYPE']) ?? '';
    final charset = _asString(column['CHARACTER_SET_NAME']);
    final collation = _asString(column['COLLATION_NAME']);
    final referencia = ReferenciaColumnInfo(
      columnType: columnType,
      charset: charset,
      collation: collation,
      hasUniqueIndex: uniqueCount > 0,
    );

    if (!referencia.hasUniqueIndex) {
      warnings.add(
        'variantes.referencia no es UNIQUE: la clave ajena de '
        'tpv_escandallos fallará',
      );
    }
    if (columnType.toLowerCase() != 'varchar(30)') {
      warnings.add(
        'variantes.referencia es "$columnType" (se esperaba varchar(30))',
      );
    }
    if (charset == null || collation == null) {
      warnings.add(
        'variantes.referencia no informa charset/collation: se usan '
        '${TpvSchema.defaultCharset}/${TpvSchema.defaultCollation}',
      );
    } else if (charset != TpvSchema.defaultCharset ||
        collation != TpvSchema.defaultCollation) {
      warnings.add(
        'Collation de variantes.referencia distinta de la canónica: '
        '$charset/$collation (el DDL se ajusta a ella)',
      );
    }

    final schema = TpvSchema(
      charset: charset ?? TpvSchema.defaultCharset,
      collation: collation ?? TpvSchema.defaultCollation,
    );
    return SchemaInspection(
      variantesExists: true,
      referencia: referencia,
      existingTables: existing,
      schema: schema,
      warnings: warnings,
    );
  }

  static String? _asString(Object? value) => switch (value) {
    null => null,
    final String s => s,
    _ => value.toString(),
  };
}
