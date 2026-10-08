<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Dinamic\Model\TpvMovimientoStock;

/**
 * Diario de movimientos de stock del TPV (solo lectura).
 */
class ListTpvMovimientoStock extends ListController
{
    /** Motivos que escribe la app; se completan con los que haya en la tabla. */
    const MOTIVOS = ['comanda', 'anulacion'];

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-stock-movements';
        $data['icon'] = 'fa-solid fa-dolly';
        return $data;
    }

    protected function createViews()
    {
        $this->createViewsMovimientos();
    }

    protected function createViewsMovimientos(string $viewName = 'ListTpvMovimientoStock'): void
    {
        $this->addView($viewName, 'TpvMovimientoStock', 'tpv-stock-movements', 'fa-solid fa-dolly')
            ->addSearchFields(['operacion', 'referencia', 'origen'])
            ->addOrderBy(['creado', 'id'], 'date', 2)
            ->addOrderBy(['referencia', 'creado'], 'reference')
            ->addOrderBy(['operacion', 'referencia'], 'operation')
            ->addOrderBy(['cantidad'], 'quantity')
            ->addFilterPeriod('creado', 'period', 'creado', true)
            ->addFilterAutocomplete('operacion', 'operation', 'operacion', 'tpv_movimientos_stock', 'operacion', 'operacion')
            ->addFilterAutocomplete('referencia', 'reference', 'referencia', 'variantes', 'referencia', 'referencia')
            ->addFilterSelect('codalmacen', 'warehouse', 'codalmacen', $this->almacenes())
            ->addFilterSelect('motivo', 'reason', 'motivo', $this->motivos())
            ->addFilterCheckbox('devoluciones', 'tpv-only-returns', 'cantidad', '<', 0)
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            ->setSettings('clickable', false);
    }

    private function almacenes(): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ($this->codeModel->all('almacenes', 'codalmacen', 'nombre', false) as $item) {
            $values[] = ['code' => $item->code, 'description' => $item->description];
        }

        return $values;
    }

    private function motivos(): array
    {
        $motivos = self::MOTIVOS;
        $rows = TpvMovimientoStock::table()->select('motivo')->groupBy('motivo')->orderBy('motivo')->get();
        foreach ($rows as $row) {
            if (!in_array($row['motivo'], $motivos, true)) {
                $motivos[] = $row['motivo'];
            }
        }

        $values = [['code' => '', 'description' => '------']];
        foreach ($motivos as $motivo) {
            $values[] = ['code' => $motivo, 'description' => $motivo];
        }

        return $values;
    }
}
