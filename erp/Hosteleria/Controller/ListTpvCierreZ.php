<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Core\Where;

/**
 * Ventas diarias y cierres Z del TPV.
 *  - Ventas diarias: tickets e importe por día y forma de pago, sumados de los recibos (con el
 *    cobro mixto repartido), para cuadrar caja y banco.
 *  - Asientos de cierre Z: asientos cuyo documento (clave idempotente de la app) empieza por "Z-".
 *    En el modo por defecto de la app («solo descuadre») solo hay asiento cuando la caja no
 *    cuadra, y su importe es ese descuadre: los días cuadrados no aparecen.
 */
class ListTpvCierreZ extends ListController
{
    /** Prefijo de asientos.documento de los cierres Z (CierreZEngine en la app). */
    const PREFIJO = 'Z-';

    const VIEW_CIERRES = 'ListTpvCierreZ';
    const VIEW_VENTAS = 'ListTpvVentaDiaria';

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
        $this->createViewsVentas();
        $this->createViewsCierres();
    }

    protected function createViewsCierres(string $viewName = self::VIEW_CIERRES): void
    {
        // título corto: FS corta a 15 caracteres el de las pestañas
        $this->addView($viewName, 'Asiento', 'tpv-tab-z-entries', 'fa-solid fa-cash-register')
            ->addSearchFields(['documento', 'concepto', 'CAST(numero AS char(255))'])
            ->addOrderBy(['fecha', 'numero'], 'date', 2)
            ->addOrderBy(['numero'], 'number')
            ->addOrderBy(['importe'], 'amount')
            ->addFilterPeriod('fecha', 'period', 'fecha')
            ->addFilterSelect('codejercicio', 'exercise', 'codejercicio', $this->selectValues('ejercicios', 'codejercicio', 'nombre'))
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            // sin acceso a la ficha del asiento (p. ej. solo con el rol Hosteleria) la fila no enlaza
            ->setSettings('clickable', $this->user->can('EditAsiento'));
    }

    protected function createViewsVentas(string $viewName = self::VIEW_VENTAS): void
    {
        $this->addView($viewName, 'Join\TpvVentaDiaria', 'tpv-daily-sales', 'fa-solid fa-calendar-day')
            ->addOrderBy(['facturascli.fecha', 'recibospagoscli.codpago'], 'date', 2)
            ->addOrderBy(['importe'], 'amount')
            ->addFilterPeriod('fecha', 'period', 'facturascli.fecha')
            ->addFilterSelect('codpago', 'payment-method', 'recibospagoscli.codpago', $this->selectValues('formaspago', 'codpago', 'descripcion'))
            ->addFilterSelect('codalmacen', 'warehouse', 'facturascli.codalmacen', $this->selectValues('almacenes', 'codalmacen', 'nombre'))
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            ->setSettings('clickable', false);
    }

    protected function loadData($viewName, $view)
    {
        if ($viewName === self::VIEW_VENTAS) {
            $where = [
                Where::like('facturascli.numero2', ListTpvTicket::PREFIJO . '%'),
                Where::isNull('facturascli.idfacturarect'),
            ];
            // «solo datos propios»: misma regla que ListController::getOwnerFilter, sobre la factura
            if ($this->permissions->onlyOwnerData) {
                $propios = [];
                if (false === empty($this->user->codagente)) {
                    $propios[] = Where::eq('facturascli.codagente', $this->user->codagente);
                }
                $propios[] = empty($propios) ?
                    Where::eq('facturascli.nick', $this->user->nick) :
                    Where::orEq('facturascli.nick', $this->user->nick);
                $where[] = Where::sub($propios);
            }
            $view->loadData('', $where);
            return;
        }

        $where = $this->permissions->onlyOwnerData ? $this->getOwnerFilter($view->model) : [];
        $where[] = Where::like('documento', self::PREFIJO . '%');
        $view->loadData('', $where);
    }

    private function selectValues(string $table, string $code, string $description): array
    {
        $values = [['code' => '', 'description' => '------']];
        foreach ($this->codeModel->all($table, $code, $description, false) as $item) {
            $values[] = ['code' => $item->code, 'description' => $item->description];
        }

        return $values;
    }
}
