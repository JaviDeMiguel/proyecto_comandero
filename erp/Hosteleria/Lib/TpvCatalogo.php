<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Where;

/**
 * Lectura en lote de variantes y productos por referencia (evita una consulta por fila en los
 * listados de escandallos, del diario y en el cálculo de costes).
 */
final class TpvCatalogo
{
    /** Referencias por consulta (cláusula IN). */
    const LOTE = 200;

    /**
     * Datos de cada referencia que exista en variantes, indexados por clave(referencia):
     * referencia (tal cual está en variantes), idproducto, descripcion, codfamilia, coste, margen,
     * precio, nostock, sevende, bloqueado.
     *
     * @param string[] $referencias
     *
     * @return array<string, array>
     */
    public static function variantes(array $referencias): array
    {
        $pendientes = [];
        foreach ($referencias as $referencia) {
            $referencia = (string)$referencia;
            if ('' !== $referencia) {
                $pendientes[self::clave($referencia)] = $referencia;
            }
        }

        $out = [];
        if (empty($pendientes)) {
            return $out;
        }

        $db = new DataBase();
        foreach (array_chunk(array_values($pendientes), self::LOTE) as $lote) {
            $sql = 'SELECT v.referencia, v.idproducto, v.coste, v.margen, v.precio, p.descripcion, p.codfamilia, p.nostock, p.sevende, p.bloqueado'
                . ' FROM variantes v LEFT JOIN productos p ON p.idproducto = v.idproducto'
                . Where::multiSqlLegacy([Where::in('v.referencia', $lote)]);
            foreach ($db->select($sql) as $row) {
                $out[self::clave((string)$row['referencia'])] = [
                    'referencia' => (string)$row['referencia'],
                    'idproducto' => (int)$row['idproducto'],
                    'descripcion' => (string)($row['descripcion'] ?? ''),
                    'codfamilia' => (string)($row['codfamilia'] ?? ''),
                    'coste' => (float)($row['coste'] ?? 0),
                    'margen' => (float)($row['margen'] ?? 0),
                    'precio' => (float)($row['precio'] ?? 0),
                    'nostock' => (bool)($row['nostock'] ?? false),
                    'sevende' => (bool)($row['sevende'] ?? true),
                    'bloqueado' => (bool)($row['bloqueado'] ?? false),
                ];
            }
        }

        return $out;
    }

    /**
     * Clave de búsqueda de una referencia (la collation de variantes.referencia no distingue
     * mayúsculas).
     */
    public static function clave(string $referencia): string
    {
        return mb_strtolower($referencia);
    }

    /**
     * Fila de variantes() para una referencia, o null si no existe.
     */
    public static function fila(array $datos, string $referencia): ?array
    {
        return $datos[self::clave($referencia)] ?? null;
    }
}
