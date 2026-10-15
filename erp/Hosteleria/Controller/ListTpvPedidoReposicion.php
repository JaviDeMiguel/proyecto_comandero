<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Controller\ListPedidoProveedor;

/**
 * Pedidos de reposición que crea el TPV (numproveedor = 'TPV-REPO-<fecha>-<proveedor>',
 * ReposicionService en la app), con las acciones del listado de pedidos del núcleo (aprobar y
 * agrupar) para quien puede gestionar pedidos. Mientras un pedido sigue sin recibir, su cantidad
 * pendiente frena las reposiciones siguientes de esas referencias.
 */
class ListTpvPedidoReposicion extends ListPedidoProveedor
{
    /** Prefijo de numproveedor de los pedidos de reposición del TPV. */
    const PREFIJO = 'TPV-REPO-';

    /** Reutiliza XMLView/ListPedidoProveedor.xml del núcleo (el sufijo tras el guion se ignora). */
    const VIEW_NAME = 'ListPedidoProveedor-tpv';

    /** Acciones de ListBusinessDocument que modifican documentos. */
    const ACCIONES_DE_DOCUMENTO = [
        'approve-document',
        'approve-document-same-date',
        'generate-accounting-entries',
        'group-document',
        'lock-invoice',
        'pay-invoice',
        'pay-receipt',
    ];

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-restock-orders';
        $data['icon'] = 'fa-solid fa-truck';
        return $data;
    }

    protected function createViews()
    {
        $this->createViewPurchases(self::VIEW_NAME, 'PedidoProveedor', 'orders');

        // aprobar (genera el albarán) y agrupar solo para quien gestiona pedidos de proveedor; el rol
        // Hosteleria por sí solo consulta el listado sin enlaces a fichas que no puede abrir
        $gestiona = $this->user->can('EditPedidoProveedor');
        if ($gestiona) {
            $this->tab(self::VIEW_NAME)->addButtonGroup([
                'name' => 'doc-actions',
                'icon' => 'fa-solid fa-circle-check',
                'label' => 'actions',
            ]);
            $this->addButtonApproveDocument(self::VIEW_NAME, 'doc-actions');
            if ($this->user->can('DocumentStitcher')) {
                $this->addButtonGroupDocument(self::VIEW_NAME, 'doc-actions');
            }
        }

        $this->setSettings(self::VIEW_NAME, 'btnNew', false);
        $this->setSettings(self::VIEW_NAME, 'btnDelete', false);
        $this->setSettings(self::VIEW_NAME, 'clickable', $gestiona);
    }

    protected function execPreviousAction($action)
    {
        // ListBusinessDocument solo mira el permiso de modificar de esta página, que el rol
        // Hosteleria concede: aprobar o agrupar exige además poder gestionar pedidos de proveedor
        if (in_array($action, self::ACCIONES_DE_DOCUMENTO, true) && false === $this->user->can('EditPedidoProveedor')) {
            Tools::log()->warning('not-allowed-modify');
            return true;
        }

        return parent::execPreviousAction($action);
    }

    protected function loadData($viewName, $view)
    {
        $where = $this->permissions->onlyOwnerData ? $this->getOwnerFilter($view->model) : [];
        $where[] = Where::like('numproveedor', self::PREFIJO . '%');
        $view->loadData('', $where);
    }
}
