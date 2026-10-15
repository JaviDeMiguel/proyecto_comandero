<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Controller\ListProducto;
use FacturaScripts\Dinamic\Model\Join\TpvStockProducto;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvStockDestino;

/**
 * Stock de cocina y stock de barra: la pestaña «Stock» de Almacén › Productos (mismas columnas,
 * filtros y colores), una vez con las referencias de cocina y otra con las de barra
 * (Lib/TpvStockDestino). Solo consulta: el stock se ajusta en la ficha de cada producto.
 */
class ListTpvStock extends ListProducto
{
    /** Vistas de XMLView/ListTpvStock.xml (el sufijo tras el guion se ignora). */
    const VIEW_BARRA = 'ListTpvStock-barra';
    const VIEW_COCINA = 'ListTpvStock-cocina';

    /** @var array|null clasificación de TpvStockDestino, calculada una vez para las dos pestañas */
    private $clasificacion = null;

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'stock';
        $data['icon'] = 'fa-solid fa-boxes-stacked';
        return $data;
    }

    protected function createViews(): void
    {
        // títulos cortos: FS corta a 15 caracteres el de las pestañas
        $pestanas = [
            self::VIEW_COCINA => ['tpv-tab-kitchen-stock', 'fa-solid fa-fire-burner'],
            self::VIEW_BARRA => ['tpv-tab-bar-stock', 'fa-solid fa-martini-glass'],
        ];
        foreach ($pestanas as $viewName => [$titulo, $icono]) {
            $this->createViewStock($viewName);
            $this->tab($viewName)->title = Tools::trans($titulo);
            $this->tab($viewName)->icon = $icono;

            // mismo Join\StockProducto, pero con este listado como página de vuelta
            $this->tab($viewName)->model = new TpvStockProducto();

            // sin acceso a la ficha de producto (p. ej. solo con el rol Hosteleria), sin enlaces a ella
            $this->setSettings($viewName, 'clickable', $this->user->can('EditProducto'));
        }
    }

    protected function loadData($viewName, $view)
    {
        if (null === $this->clasificacion) {
            $this->clasificacion = TpvStockDestino::clasificar();
        }

        $destino = $viewName === self::VIEW_COCINA ? TpvStockDestino::COCINA : TpvStockDestino::BARRA;
        $referencias = TpvStockDestino::referencias($destino, $this->clasificacion);

        // sin referencias de ese destino, un filtro que no devuelve nada
        $where = empty($referencias) ?
            [Where::isNull('stocks.idstock')] :
            [Where::in('stocks.referencia', $referencias)];
        $view->loadData('', $where);
    }
}
