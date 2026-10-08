<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Controller;

use Closure;
use FacturaScripts\Core\Tools;

/**
 * Filtro por "Destino TPV" en el listado de familias.
 */
class ListFamilia
{
    public function createViews(): Closure
    {
        return function () {
            if (false === isset($this->views['ListFamilia'])) {
                return;
            }

            $this->listView('ListFamilia')->addFilterSelect('tpv_destino', 'tpv-destination', 'tpv_destino', [
                ['code' => '', 'description' => '------'],
                ['code' => 'cocina', 'description' => Tools::trans('tpv-kitchen')],
                ['code' => 'barra', 'description' => Tools::trans('tpv-bar')],
            ]);
        };
    }
}
