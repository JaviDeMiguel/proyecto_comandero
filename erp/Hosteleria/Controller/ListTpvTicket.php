<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Core\Where;

/**
 * Tickets del TPV: facturas de cliente cuyo numero2 (clave idempotente de la app) empieza por
 * "TPV-", y las rectificativas que se hayan hecho de ellos en FacturaScripts. Cada fila abre la
 * ficha estándar de la factura (EditFacturaCliente).
 *
 * observaciones lleva lo que la app anota en cada ticket: «TPV ticket N · Mesa X · Camarero Y ·
 * Precuentas nº n hh:mm importe, …» (el camarero solo si lo hay y el sufijo de precuentas solo si
 * se emitió alguna, con número, hora y total de cada una; el formato se amplía por el final).
 */
class ListTpvTicket extends ListController
{
    /** Prefijo de numero2 de las facturas que crea el TPV (Ticket.claveFactura en la app). */
    const PREFIJO = 'TPV-';

    const VIEW_RECTIFICATIVAS = 'ListTpvTicket-rect';
    const VIEW_TICKETS = 'ListTpvTicket';

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
        $this->createViewsTickets(self::VIEW_RECTIFICATIVAS, 'tpv-ticket-refunds', 'fa-solid fa-rotate-left');
    }

    protected function createViewsTickets(string $viewName = self::VIEW_TICKETS, string $title = 'tpv-tickets', string $icon = 'fa-solid fa-receipt'): void
    {
        $this->addView($viewName, 'FacturaCliente', $title, $icon)
            ->addSearchFields(['codigo', 'numero2', 'nombrecliente', 'observaciones'])
            ->addOrderBy(['fecha', 'hora', 'idfactura'], 'date', 2)
            ->addOrderBy(['codigo'], 'code')
            ->addOrderBy(['numero2'], 'tpv-ticket')
            ->addOrderBy(['total'], 'total')
            ->addFilterPeriod('fecha', 'period', 'fecha')
            ->addFilterSelect('codpago', 'payment-method', 'codpago', $this->selectValues('formaspago', 'codpago', 'descripcion'))
            ->addFilterSelect('codserie', 'serie', 'codserie', $this->selectValues('series', 'codserie', 'descripcion'))
            ->addFilterSelect('codalmacen', 'warehouse', 'codalmacen', $this->selectValues('almacenes', 'codalmacen', 'nombre'))
            ->addFilterCheckbox('nopagada', 'unpaid', 'pagada', '=', false)
            ->addFilterCheckbox('sinasiento', 'invoice-without-acc-entry', 'idasiento', 'IS', null)
            ->setSettings('btnNew', false)
            ->setSettings('btnDelete', false)
            ->setSettings('checkBoxes', false)
            // sin acceso a la ficha de la factura (p. ej. solo con el rol Hosteleria) la fila no enlaza
            ->setSettings('clickable', $this->user->can('EditFacturaCliente'));
    }

    protected function loadData($viewName, $view)
    {
        $where = $this->permissions->onlyOwnerData ? $this->getOwnerFilter($view->model) : [];
        if ($viewName === self::VIEW_RECTIFICATIVAS) {
            // rectificativas de tickets del TPV (las nuevas llevan numero2 'RTPV-...', ver
            // Extension/Model/FacturaCliente; las anteriores conservan el del ticket)
            $where[] = Where::in('idfacturarect', "SELECT idfactura FROM facturascli WHERE numero2 LIKE '" . self::PREFIJO . "%'");
        } else {
            $where[] = Where::like('numero2', self::PREFIJO . '%');
            $where[] = Where::isNull('idfacturarect');
        }

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
