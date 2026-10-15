<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Core\Tools;
use FacturaScripts\Dinamic\Model\TpvMovimientoStock;

/**
 * Diario de movimientos de stock del TPV (solo lectura) y consumo por materia prima.
 *
 * cantidad es la variación que el TPV ha sumado a stocks.cantidad: negativa = consumo de una
 * comanda, positiva = devolución de una anulación.
 */
class ListTpvMovimientoStock extends ListController
{
    const VIEW_CONSUMO = 'ListTpvConsumo';
    const VIEW_MOVIMIENTOS = 'ListTpvMovimientoStock';

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
        $this->createViewsConsumo();
    }

    /**
     * Consumo agregado por referencia y almacén (Join\TpvConsumo), filtrable por periodo.
     */
    protected function createViewsConsumo(string $viewName = self::VIEW_CONSUMO): void
    {
        // títulos cortos: FS corta a 15 caracteres el de las pestañas
        $this->addView($viewName, 'Join\TpvConsumo', 'tpv-tab-consumption', 'fa-solid fa-chart-column')
            ->addSearchFields(['tpv_movimientos_stock.referencia', 'productos.descripcion'])
            ->addOrderBy(['valor'], 'tpv-consumption-value', 2)
            ->addOrderBy(['consumo'], 'tpv-consumed')
            ->addOrderBy(['tpv_movimientos_stock.referencia'], 'reference')
            ->addFilterPeriod('creado', 'period', 'tpv_movimientos_stock.creado', true)
            ->addFilterSelect('codalmacen', 'warehouse', 'tpv_movimientos_stock.codalmacen', $this->almacenes())
            ->addFilterSelect('codfamilia', 'family', 'productos.codfamilia', $this->familias())
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            ->setSettings('clickable', false);
    }

    protected function createViewsMovimientos(string $viewName = self::VIEW_MOVIMIENTOS): void
    {
        // el orden por id sigue el de inserción y usa la clave primaria (el diario no tiene índice por fecha)
        $this->addView($viewName, 'TpvMovimientoStock', 'tpv-tab-movements', 'fa-solid fa-dolly')
            ->addSearchFields(['operacion', 'referencia', 'origen'])
            ->addOrderBy(['id'], 'date', 2)
            ->addOrderBy(['referencia', 'id'], 'reference')
            ->addOrderBy(['cantidad'], 'quantity')
            ->addFilterPeriod('creado', 'period', 'creado', true)
            ->addFilterAutocomplete('referencia', 'reference', 'referencia', 'Variante', 'referencia', 'referencia')
            ->addFilterSelect('codalmacen', 'warehouse', 'codalmacen', $this->almacenes())
            ->addFilterSelect('motivo', 'reason', 'motivo', $this->motivos())
            ->addFilterCheckbox('consumos', 'tpv-only-consumption', 'cantidad', '<', 0)
            ->addFilterCheckbox('devoluciones', 'tpv-only-returns', 'cantidad', '>', 0)
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            ->setSettings('clickable', false);
    }

    protected function loadData($viewName, $view)
    {
        parent::loadData($viewName, $view);

        // sin acceso a la ficha de producto (p. ej. solo con el rol Hosteleria), sin enlaces a ella
        $column = $view->columnForName('description');
        if ($column && false === $this->user->can('EditProducto')) {
            $column->widget->onclick = '';
        }

        // descripción e idproducto de las referencias de la página en una sola consulta (son
        // atributos perezosos del modelo; una referencia borrada se queda sin ellos)
        if ($viewName === self::VIEW_MOVIMIENTOS && !empty($view->cursor)) {
            TpvMovimientoStock::precargar($view->cursor);
        }
    }

    private function almacenes(): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ($this->codeModel->all('almacenes', 'codalmacen', 'nombre', false) as $item) {
            $values[] = ['code' => $item->code, 'description' => $item->description];
        }

        return $values;
    }

    private function familias(): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ($this->codeModel->all('familias', 'codfamilia', 'descripcion', false) as $item) {
            $values[] = ['code' => $item->code, 'description' => $item->description];
        }

        return $values;
    }

    /**
     * Motivos que escribe la app (no se consulta la tabla: un GROUP BY recorrería todo el diario).
     */
    private function motivos(): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ([TpvMovimientoStock::MOTIVO_COMANDA, TpvMovimientoStock::MOTIVO_ANULACION] as $motivo) {
            $values[] = ['code' => $motivo, 'description' => Tools::trans('tpv-reason-' . $motivo)];
        }

        return $values;
    }
}
