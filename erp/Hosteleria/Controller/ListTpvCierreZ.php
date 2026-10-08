<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Core\Where;

/**
 * Cierres Z del TPV: asientos cuyo campo documento (clave idempotente de la app) empieza por
 * "Z-". Cada fila abre la ficha estándar del asiento (EditAsiento).
 */
class ListTpvCierreZ extends ListController
{
    /** Prefijo de asientos.documento de los cierres Z (CierreZEngine en la app). */
    const PREFIJO = 'Z-';

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-z-closures';
        $data['icon'] = 'fa-solid fa-cash-register';
        return $data;
    }

    protected function createViews()
    {
        $this->createViewsCierres();
    }

    protected function createViewsCierres(string $viewName = 'ListTpvCierreZ'): void
    {
        $this->addView($viewName, 'Asiento', 'tpv-z-closures', 'fa-solid fa-cash-register')
            ->addSearchFields(['documento', 'concepto', 'CAST(numero AS char(255))'])
            ->addOrderBy(['fecha', 'numero'], 'date', 2)
            ->addOrderBy(['numero'], 'number')
            ->addOrderBy(['importe'], 'amount')
            ->addFilterPeriod('fecha', 'period', 'fecha')
            ->addFilterSelect('codejercicio', 'exercise', 'codejercicio', $this->ejercicios())
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false);
    }

    protected function loadData($viewName, $view)
    {
        $where = $this->permissions->onlyOwnerData ? $this->getOwnerFilter($view->model) : [];
        $where[] = Where::like('documento', self::PREFIJO . '%');
        $view->loadData('', $where);
    }

    private function ejercicios(): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ($this->codeModel->all('ejercicios', 'codejercicio', 'nombre', false) as $item) {
            $values[] = ['code' => $item->code, 'description' => $item->description];
        }

        return $values;
    }
}
