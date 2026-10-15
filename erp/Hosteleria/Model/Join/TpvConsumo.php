<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model\Join;

use FacturaScripts\Plugins\Hosteleria\Lib\TpvJoinAgrupado;

/**
 * Consumo de materias primas por referencia y almacén, sumado del diario de stock del TPV.
 *
 * El diario guarda la variación aplicada a stocks.cantidad (negativa = consumo, positiva =
 * devolución), así que consumo = -cantidad. Las referencias «no controlar stock» aparecen
 * (el TPV las apunta) aunque no se hayan descontado. El valor usa el coste actual de la variante.
 *
 * @property string $referencia
 * @property string $codalmacen
 * @property string $descripcion
 * @property int $idproducto
 * @property bool $nostock
 * @property float $coste
 * @property float $consumo
 * @property float $devuelto
 * @property float $neto
 * @property float $valor
 * @property int $movimientos
 */
class TpvConsumo extends TpvJoinAgrupado
{
    const MAIN_TABLE = 'tpv_movimientos_stock';

    public function url(string $type = 'auto', string $list = 'List'): string
    {
        return 'ListTpvMovimientoStock';
    }

    protected function camposNumericos(): array
    {
        return [
            'consumo' => 'double',
            'coste' => 'double',
            'devuelto' => 'double',
            'idproducto' => 'integer',
            'movimientos' => 'integer',
            'neto' => 'double',
            'valor' => 'double',
        ];
    }

    protected function getFields(): array
    {
        // ROUND: las sumas de DOUBLE arrastran ruido de coma flotante (0,30000000000000004)
        $cantidad = static::MAIN_TABLE . '.cantidad';
        return [
            'codalmacen' => static::MAIN_TABLE . '.codalmacen',
            'consumo' => 'ROUND(SUM(CASE WHEN ' . $cantidad . ' < 0 THEN -' . $cantidad . ' ELSE 0 END), 3)',
            'coste' => 'variantes.coste',
            'descripcion' => 'productos.descripcion',
            'devuelto' => 'ROUND(SUM(CASE WHEN ' . $cantidad . ' > 0 THEN ' . $cantidad . ' ELSE 0 END), 3)',
            'idproducto' => 'variantes.idproducto',
            'movimientos' => 'COUNT(*)',
            'neto' => 'ROUND(SUM(-' . $cantidad . '), 3)',
            'nostock' => 'productos.nostock',
            'referencia' => static::MAIN_TABLE . '.referencia',
            'valor' => 'ROUND(SUM(-' . $cantidad . ' * COALESCE(variantes.coste, 0)), 5)',
        ];
    }

    protected function getGroupFields(): string
    {
        return static::MAIN_TABLE . '.referencia, ' . static::MAIN_TABLE . '.codalmacen, variantes.idproducto, '
            . 'variantes.coste, productos.descripcion, productos.nostock';
    }

    protected function getSQLFrom(): string
    {
        return static::MAIN_TABLE
            . ' LEFT JOIN variantes ON variantes.referencia = ' . static::MAIN_TABLE . '.referencia'
            . ' LEFT JOIN productos ON productos.idproducto = variantes.idproducto';
    }

    protected function getTables(): array
    {
        return [static::MAIN_TABLE, 'variantes', 'productos'];
    }
}
