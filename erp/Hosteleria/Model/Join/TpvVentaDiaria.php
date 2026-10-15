<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model\Join;

use FacturaScripts\Plugins\Hosteleria\Lib\TpvJoinAgrupado;

/**
 * Ventas del TPV por día y forma de pago, sumadas de los recibos de sus tickets (facturas con
 * numero2 'TPV-...'; el controlador añade ese filtro y excluye las rectificativas). Se agrupa por
 * recibo y no por la forma de pago de la factura: un cobro mixto tiene un recibo por forma de pago
 * (efectivo y tarjeta), igual que el cierre Z de la app.
 *
 * @property string $fecha
 * @property string $codpago
 * @property int $tickets
 * @property float $importe
 * @property float $pendiente
 */
class TpvVentaDiaria extends TpvJoinAgrupado
{
    public function url(string $type = 'auto', string $list = 'List'): string
    {
        return 'ListTpvCierreZ';
    }

    protected function camposNumericos(): array
    {
        return [
            'importe' => 'double',
            'pendiente' => 'double',
            'tickets' => 'integer',
        ];
    }

    protected function getFields(): array
    {
        return [
            'codpago' => 'recibospagoscli.codpago',
            'fecha' => 'facturascli.fecha',
            'importe' => 'ROUND(SUM(recibospagoscli.importe), 2)',
            'pendiente' => 'ROUND(SUM(CASE WHEN recibospagoscli.pagado = 1 THEN 0 ELSE recibospagoscli.importe END), 2)',
            'tickets' => 'COUNT(DISTINCT facturascli.idfactura)',
        ];
    }

    protected function getGroupFields(): string
    {
        return 'facturascli.fecha, recibospagoscli.codpago';
    }

    protected function getSQLFrom(): string
    {
        return 'recibospagoscli JOIN facturascli ON facturascli.idfactura = recibospagoscli.idfactura';
    }

    protected function getTables(): array
    {
        return ['recibospagoscli', 'facturascli'];
    }
}
