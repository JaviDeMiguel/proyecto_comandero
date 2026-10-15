<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Controller;

use Closure;
use FacturaScripts\Core\Tools;

/**
 * Campo "Destino TPV" de la ficha de familia: Heredar / Cocina / Barra, y destino efectivo en el
 * ERP (propio o heredado). Las reglas de enrutamiento del TPV tienen prioridad en cada nivel.
 *
 * Los closures se ejecutan como el controlador EditFamilia del núcleo ($this):
 *
 * @method string mainTabName()
 */
class EditFamilia
{
    public function loadData(): Closure
    {
        return function ($viewName, $view) {
            if ($viewName !== $this->mainTabName()) {
                return;
            }

            // opción vacía con texto "Heredar" (el XML por defecto muestra "------")
            $column = $view->columnForName('tpv-destination');
            if ($column && $column->widget->getType() === 'select') {
                $column->widget->setValuesFromArray([
                    ['value' => '', 'title' => 'tpv-inherit'],
                    ['value' => 'cocina', 'title' => 'tpv-kitchen'],
                    ['value' => 'barra', 'title' => 'tpv-bar'],
                ], true, false);
            }

            // destino efectivo (propio o heredado de la familia madre)
            if ($view->model->exists()) {
                $efectivo = $view->model->tpvDestinoEfectivo();
                $texto = null === $efectivo ? Tools::trans('tpv-app-default') : Tools::trans($efectivo === 'barra' ? 'tpv-bar' : 'tpv-kitchen');
                if (empty($view->model->tpv_destino) && null !== $efectivo) {
                    $texto .= ' (' . Tools::trans('tpv-inherited') . ')';
                }
                $view->model->tpv_destino_efectivo = $texto;
            }
        };
    }
}
