<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 *
 * DDL canónico de las tablas propias del TPV (tpv_escandallos y tpv_movimientos_stock).
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Tools;
use FacturaScripts\Dinamic\Model\Variante;

/**
 * Crea las tablas tpv_* con EXACTAMENTE el mismo DDL que la app Flutter
 * (proyecto_comandero: sql/tpv_schema.sql y lib/core/database/schema/tpv_schema.dart).
 *
 * Por qué no se deja a FacturaScripts crearlas desde Table/*.xml:
 *  - MysqlQueries::fixPostgresql() sustituye CURRENT_TIMESTAMP por una fecha fija al
 *    crear la tabla, y el XML no puede expresar ON UPDATE CURRENT_TIMESTAMP, BIGINT
 *    AUTO_INCREMENT, el índice tpv_idx_* (FS antepone "fs_" a los índices del XML) ni
 *    la collation de columna copiada de variantes.referencia.
 *  - La app compara su DDL con la tabla real (TpvSchemaMigrator) y FS compara la tabla
 *    con el XML (DbUpdater::updateTable). Con este DDL + el XML del plugin ninguno de
 *    los dos genera ALTER, sea quien sea el primero en crearlas.
 *
 * Los modelos TpvEscandallo y TpvMovimientoStock llaman a ensureTable() antes de que el
 * DbUpdater revise su tabla, de modo que el XML solo se usa para comparar.
 */
final class TpvSchema
{
    const DEFAULT_CHARSET = 'utf8mb4';
    const DEFAULT_COLLATION = 'utf8mb4_unicode_520_ci';

    const TABLE_ESCANDALLOS = 'tpv_escandallos';
    const TABLE_MOVIMIENTOS = 'tpv_movimientos_stock';
    const TABLES = [self::TABLE_ESCANDALLOS, self::TABLE_MOVIMIENTOS];

    /**
     * Sentencia CREATE TABLE IF NOT EXISTS de la tabla indicada, idéntica a la de la app.
     */
    public static function createSql(string $table, string $charset = self::DEFAULT_CHARSET, string $collation = self::DEFAULT_COLLATION): string
    {
        $refType = 'VARCHAR(30) CHARACTER SET ' . $charset . ' COLLATE ' . $collation;
        $options = 'ENGINE=InnoDB DEFAULT CHARSET=' . $charset . ' COLLATE=' . $collation;

        switch ($table) {
            case self::TABLE_ESCANDALLOS:
                return "CREATE TABLE IF NOT EXISTS tpv_escandallos (\n"
                    . "  id INT NOT NULL AUTO_INCREMENT,\n"
                    . "  ref_plato " . $refType . " NOT NULL,\n"
                    . "  ref_ingrediente " . $refType . " NOT NULL,\n"
                    . "  cantidad DOUBLE NOT NULL,\n"
                    . "  merma DOUBLE NOT NULL DEFAULT 0,\n"
                    . "  observaciones VARCHAR(255) NULL,\n"
                    . "  creado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,\n"
                    . "  actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,\n"
                    . "  PRIMARY KEY (id),\n"
                    . "  UNIQUE KEY tpv_uniq_escandallos_plato_ingrediente (ref_plato, ref_ingrediente),\n"
                    . "  KEY tpv_idx_escandallos_ingrediente (ref_ingrediente),\n"
                    . "  CONSTRAINT tpv_chk_escandallos_cantidad CHECK (cantidad > 0),\n"
                    . "  CONSTRAINT tpv_chk_escandallos_merma CHECK (merma >= 0 AND merma < 100),\n"
                    . "  CONSTRAINT tpv_fk_escandallos_plato FOREIGN KEY (ref_plato)\n"
                    . "    REFERENCES variantes (referencia) ON DELETE CASCADE ON UPDATE CASCADE,\n"
                    . "  CONSTRAINT tpv_fk_escandallos_ingrediente FOREIGN KEY (ref_ingrediente)\n"
                    . "    REFERENCES variantes (referencia) ON DELETE RESTRICT ON UPDATE CASCADE\n"
                    . ") " . $options . ";";

            case self::TABLE_MOVIMIENTOS:
                return "CREATE TABLE IF NOT EXISTS tpv_movimientos_stock (\n"
                    . "  id BIGINT NOT NULL AUTO_INCREMENT,\n"
                    . "  operacion VARCHAR(64) NOT NULL,\n"
                    . "  referencia " . $refType . " NOT NULL,\n"
                    . "  codalmacen VARCHAR(4) NOT NULL,\n"
                    . "  cantidad DOUBLE NOT NULL,\n"
                    . "  motivo VARCHAR(20) NOT NULL,\n"
                    . "  origen VARCHAR(100) NULL,\n"
                    . "  creado DATETIME NOT NULL,\n"
                    . "  PRIMARY KEY (id),\n"
                    . "  UNIQUE KEY tpv_uniq_movimientos_operacion (operacion, referencia, codalmacen),\n"
                    . "  KEY tpv_idx_movimientos_referencia (referencia, codalmacen, creado)\n"
                    . ") " . $options . ";";
        }

        return '';
    }

    /**
     * Crea (si faltan) las dos tablas tpv_*. Idempotente.
     */
    public static function ensureAll(): bool
    {
        $ok = true;
        foreach (self::TABLES as $table) {
            $ok = self::ensureTable($table) && $ok;
        }

        return $ok;
    }

    /**
     * Crea la tabla con el DDL canónico si no existe. Devuelve true si la tabla existe al terminar.
     * En PostgreSQL (no soportado por la app) no hace nada y deja actuar al DbUpdater.
     */
    public static function ensureTable(string $table): bool
    {
        if (false === in_array($table, self::TABLES, true)) {
            return false;
        }

        $db = new DataBase();
        $db->connect();
        if ($db->tableExists($table)) {
            return true;
        }

        if ('mysql' !== strtolower($db->type())) {
            return false;
        }

        // CREATE TABLE hace COMMIT implícito en MySQL: nunca dentro de una transacción ajena
        if ($db->inTransaction()) {
            return false;
        }

        // las columnas de referencia copian charset y collation de variantes.referencia
        if (false === $db->tableExists('variantes')) {
            new Variante();
        }
        [$charset, $collation] = self::referenciaCharset($db);

        if ($table === self::TABLE_ESCANDALLOS && false === self::referenciaIsUnique($db)) {
            Tools::log()->error('tpv-referencia-not-unique');
            return false;
        }

        if (false === $db->exec(self::createSql($table, $charset, $collation))) {
            Tools::log()->error('tpv-table-create-error', ['%table%' => $table]);
            return false;
        }

        Tools::log()->notice('tpv-table-created', ['%table%' => $table]);
        return true;
    }

    /**
     * Charset y collation de variantes.referencia (los de la app por defecto si no se pueden leer).
     *
     * @return string[] [charset, collation]
     */
    public static function referenciaCharset(?DataBase $db = null): array
    {
        if (null === $db) {
            $db = new DataBase();
            $db->connect();
        }

        $sql = "SELECT CHARACTER_SET_NAME AS cs, COLLATION_NAME AS co FROM information_schema.COLUMNS"
            . " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variantes' AND COLUMN_NAME = 'referencia';";
        foreach ($db->select($sql) as $row) {
            $charset = (string)($row['cs'] ?? '');
            $collation = (string)($row['co'] ?? '');
            if (self::validName($charset) && self::validName($collation)) {
                return [$charset, $collation];
            }
        }

        return [self::DEFAULT_CHARSET, self::DEFAULT_COLLATION];
    }

    private static function referenciaIsUnique(DataBase $db): bool
    {
        $sql = "SELECT COUNT(*) AS n FROM information_schema.STATISTICS"
            . " WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'variantes'"
            . " AND COLUMN_NAME = 'referencia' AND NON_UNIQUE = 0 AND SEQ_IN_INDEX = 1;";
        foreach ($db->select($sql) as $row) {
            return (int)($row['n'] ?? 0) > 0;
        }

        return false;
    }

    private static function validName(string $name): bool
    {
        return 1 === preg_match('/^[a-z0-9_]{1,64}$/i', $name);
    }
}
