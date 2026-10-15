<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Template\JoinModel;
use FacturaScripts\Core\Where;

/**
 * Base de los modelos Join agrupados del plugin (consumo y ventas diarias).
 *
 * Corrige dos comportamientos de JoinModel con GROUP BY que no sirven aquí:
 *  - count() devuelve las filas del grupo cuando solo hay uno (contador y paginación falsos);
 *  - count() y totalSum() sin filtros guardan el resultado en caché una hora, y la app escribe el
 *    diario y los recibos por SQL o por la API sin pasar por los modelos que borrarían esa caché.
 * Además tipa los campos calculados (la exportación a Excel los trataría como texto) y convierte
 * sus valores a número al cargar.
 */
abstract class TpvJoinAgrupado extends JoinModel
{
    /**
     * Campos calculados y su tipo ('double' | 'integer').
     *
     * @return array<string, string>
     */
    abstract protected function camposNumericos(): array;

    /**
     * Número de grupos (filas del listado), sin caché.
     */
    public static function count(array $where = []): int
    {
        $instance = new static();
        $sql = 'SELECT COUNT(*) AS n FROM (SELECT 1 FROM ' . $instance->getSQLFrom()
            . Where::multiSqlLegacy($where) . ' GROUP BY ' . $instance->getGroupFields() . ') grupos';
        foreach (self::db()->select($sql) as $row) {
            return (int)$row['n'];
        }

        return 0;
    }

    public function getModelFields(): array
    {
        $fields = parent::getModelFields();
        foreach ($this->camposNumericos() as $field => $type) {
            if (isset($fields[$field])) {
                $fields[$field]['type'] = $type;
            }
        }

        return $fields;
    }

    /**
     * Suma total de un campo para los registros filtrados, sin caché.
     */
    public function totalSum(string $field, array $where = []): float
    {
        $fields = $this->getFields();
        $expresion = $fields[$field] ?? $field;
        $select = false !== strpos($expresion, '(') ? $expresion : 'SUM(' . $expresion . ')';
        $sql = 'SELECT ' . $select . ' AS total_sum FROM ' . $this->getSQLFrom() . Where::multiSqlLegacy($where);
        foreach (self::db()->select($sql) as $row) {
            return (float)$row['total_sum'];
        }

        return 0.0;
    }

    protected function loadFromData(array $data): void
    {
        foreach ($this->camposNumericos() as $field => $type) {
            if (isset($data[$field])) {
                $data[$field] = $type === 'integer' ? (int)$data[$field] : (float)$data[$field];
            }
        }

        parent::loadFromData($data);
    }
}
