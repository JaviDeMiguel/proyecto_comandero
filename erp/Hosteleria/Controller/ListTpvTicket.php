<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Core\Where;

/**
 * Tickets del TPV: facturas de cliente cuyo numero2 (clave idempotente de la app) empieza
 * por "TPV-". Cada fila abre la ficha estándar de la factura (EditFacturaCliente).
 */
class ListTpvTicket extends ListController
{
    /** Prefijo de numero2 de las facturas que crea el TPV (Ticket.claveFactura en la app). */
    const PREFIJO = 'TPV-';

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-tickets';
        $data['icon'] = 'fa-solid fa-receipt';
        return $data;
    }

    protected function createViews()
    {
        $this->createViewsTickets();
    }

    protected function createViewsTickets(string $viewName = 'ListTpvTicket'): void
    {
        $this->addView($viewName, 'FacturaCliente', 'tpv-tickets', 'fa-solid fa-receipt')
            ->addSearchFields(['codigo', 'numero2', 'nombrecliente', 'observaciones'])
            ->addOrderBy(['fecha', 'hora', 'idfactura'], 'date', 2)
            ->addOrderBy(['codigo'], 'code')
            ->addOrderBy(['numero2'], 'tpv-ticket')
            ->addOrderBy(['total'], 'total')
            ->addFilterPeriod('fecha', 'period', 'fecha')
            ->addFilterSelect('codpago', 'payment-method', 'codpago', $this->selectValues('formaspago', 'codpago', 'descripcion'))
            ->addFilterSelect('codserie', 'serie', 'codserie', $this->selectValues('series', 'codserie', 'descripcion'))
            ->addFilterSelect('codalmacen', 'warehouse', 'codalmacen', $this->selectValues('almacenes', 'codalmacen', 'nombre'))
            ->addFilterCheckbox('pagada', 'paid', 'pagada', '=', true)
            ->addFilterCheckbox('nopagada', 'unpaid', 'pagada', '=', false)
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false);
    }

    protected function loadData($viewName, $view)
    {
        $where = $this->permissions->onlyOwnerData ? $this->getOwnerFilter($view->model) : [];
        $where[] = Where::like('numero2', self::PREFIJO . '%');
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
