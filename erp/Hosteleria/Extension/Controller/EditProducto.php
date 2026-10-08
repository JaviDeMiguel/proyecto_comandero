<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Controller;

use Closure;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Variante;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCosteEscandallo;

/**
 * Pestaña "Escandallo" en la ficha de producto: líneas de receta de sus variantes
 * (ingrediente, cantidad neta, merma, cantidad bruta) con el coste teórico y el margen.
 *
 * @method addEditListView(string $viewName, string $modelName, string $viewTitle, string $viewIcon = 'fa-solid fa-bars')
 */
class EditProducto
{
    const VIEW_NAME = 'EditTpvEscandalloProducto';

    public function createViews(): Closure
    {
        return function () {
            $this->addEditListView(
                'EditTpvEscandalloProducto',
                'TpvEscandallo',
                'tpv-recipe',
                'fa-solid fa-utensils'
            )->setInLine(true);
        };
    }

    public function loadData(): Closure
    {
        return function ($viewName, $view) {
            if ($viewName !== 'EditTpvEscandalloProducto') {
                return;
            }

            // referencias (variantes) del producto
            $idproducto = $this->tabModelValue($this->getMainViewName(), 'idproducto');
            $referencias = [];
            if (!empty($idproducto)) {
                $variantes = Variante::all([Where::eq('idproducto', $idproducto)], ['referencia' => 'ASC'], 0, 0);
                foreach ($variantes as $variante) {
                    $referencias[] = $variante->referencia;
                }
            }
            if (empty($referencias)) {
                $this->setSettings($viewName, 'active', false);
                return;
            }

            $where = count($referencias) === 1 ?
                [Where::eq('ref_plato', $referencias[0])] :
                [Where::in('ref_plato', $referencias)];
            $view->loadData('', $where, ['ref_plato' => 'ASC', 'ref_ingrediente' => 'ASC'], 0, 0);

            // plato de la línea nueva: la referencia principal del producto
            $principal = $this->tabModelValue($this->getMainViewName(), 'referencia');
            $view->model->ref_plato = in_array($principal, $referencias, true) ? $principal : $referencias[0];

            // selector de plato: solo las referencias de este producto
            $column = $view->columnForName('dish');
            if ($column && $column->widget->getType() === 'select') {
                $values = [];
                foreach ($referencias as $ref) {
                    $values[] = ['value' => $ref, 'title' => $ref];
                }
                $column->widget->setValuesFromArray($values, false, false);
            }
            if (count($referencias) === 1) {
                $view->disableColumn('dish');
            }

            // coste teórico y margen
            $coste = new TpvCosteEscandallo();
            $resumen = $coste->decorar($view->cursor);
            foreach ($referencias as $ref) {
                if (false === isset($resumen[$ref])) {
                    $resumen[$ref] = $coste->resumenPlato($ref);
                }
            }
            ksort($resumen);
            $view->setSettings('tpvCoste', array_values($resumen));
        };
    }
}
