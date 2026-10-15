<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Controller;

use Closure;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;

/**
 * Filtro por "Destino TPV" en el listado de familias: cocina, barra o heredar (sin destino propio).
 *
 * Los closures se ejecutan como el controlador ListFamilia del núcleo ($this):
 *
 * @property \FacturaScripts\Core\Lib\ExtendedController\BaseView[] $views
 * @method \FacturaScripts\Core\Lib\ExtendedController\ListView listView(string $viewName)
 */
class ListFamilia
{
    public function createViews(): Closure
    {
        return function () {
            if (false === isset($this->views['ListFamilia'])) {
                return;
            }

            $this->listView('ListFamilia')->addFilterSelectWhere('tpv_destino', [
                ['label' => Tools::trans('tpv-destination') . ': ' . Tools::trans('all'), 'where' => []],
                ['label' => Tools::trans('tpv-kitchen'), 'where' => [Where::eq('tpv_destino', 'cocina')]],
                ['label' => Tools::trans('tpv-bar'), 'where' => [Where::eq('tpv_destino', 'barra')]],
                ['label' => Tools::trans('tpv-inherit'), 'where' => [Where::isNull('tpv_destino')]],
            ]);
        };
    }
}
