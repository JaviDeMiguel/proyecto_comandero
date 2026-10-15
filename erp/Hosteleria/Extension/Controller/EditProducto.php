<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Controller;

use Closure;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCosteEscandallo;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvRecetas;

/**
 * Ficha de producto:
 *  - pestaña «Escandallo»: líneas de receta de sus variantes (ingrediente, cantidad neta, merma,
 *    cantidad bruta) con el coste teórico, el margen y el botón para copiar el coste a la ficha;
 *  - pestaña «Usado en»: recetas en las que el producto es ingrediente (solo si las hay);
 *  - un producto que es ingrediente de alguna receta no se puede borrar (la clave ajena
 *    ON DELETE RESTRICT lo impediría con un error técnico, y el núcleo borra antes las imágenes).
 *
 * Los closures se ejecutan como el controlador EditProducto del núcleo ($this):
 *
 * @property \FacturaScripts\Core\Base\ControllerPermissions $permissions
 * @property \FacturaScripts\Core\Request $request
 * @property \FacturaScripts\Core\Model\User $user
 * @method \FacturaScripts\Core\Lib\ExtendedController\EditListView addEditListView(string $viewName, string $modelName, string $viewTitle, string $viewIcon = 'fa-solid fa-bars')
 * @method \FacturaScripts\Core\Lib\ExtendedController\ListView addListView(string $viewName, string $modelName, string $viewTitle, string $viewIcon = 'fa-solid fa-list')
 * @method string mainTabName()
 * @method mixed mainTabModelValue(string $fieldName)
 * @method \FacturaScripts\Core\Lib\ExtendedController\BaseView setSettings(string $viewName, string $property, $value)
 * @method bool validateFormToken()
 */
class EditProducto
{
    const ACTION_COPY_COST = 'tpv-copy-cost';
    const VIEW_NAME = 'EditTpvEscandalloProducto';
    const VIEW_USOS = 'ListTpvEscandallo-usos';

    public function createViews(): Closure
    {
        return function () {
            $this->addEditListView(EditProducto::VIEW_NAME, 'TpvEscandallo', 'tpv-recipe', 'fa-solid fa-utensils')
                ->setInLine(true);

            $this->addListView(EditProducto::VIEW_USOS, 'TpvEscandallo', 'tpv-used-in', 'fa-solid fa-sitemap')
                ->addSearchFields(['ref_plato', 'observaciones'])
                ->addOrderBy(['ref_plato'], 'tpv-dish', 1)
                ->setSettings('btnNew', false)
                ->setSettings('btnDelete', false)
                ->setSettings('checkBoxes', false)
                ->setSettings('clickable', $this->user->can('EditTpvEscandallo'));

            // un ingrediente de receta no se borra (antes de que el núcleo ejecute la acción). El
            // producto sale de la URL, como en el núcleo: los formularios de las pestañas envían
            // como code la clave de su fila (idvariante, idstock...)
            $idproducto = (int)$this->request->query('code', $this->request->input('idproducto', 0));
            if ($idproducto > 0 && TpvRecetas::esIngrediente(TpvRecetas::referenciasProducto($idproducto))) {
                $this->setSettings($this->mainTabName(), 'btnDelete', false);
                $this->setSettings('EditVariante', 'btnDelete', false);
            }
        };
    }

    public function execPreviousAction(): Closure
    {
        return function ($action) {
            if ($action !== EditProducto::ACTION_COPY_COST) {
                return true;
            }

            if (false === $this->permissions->allowUpdate) {
                Tools::log()->warning('not-allowed-modify');
                return true;
            }
            if (false === $this->validateFormToken()) {
                return true;
            }

            $idproducto = (int)$this->request->query('code', 0);
            TpvRecetas::copiarCosteTeorico(TpvRecetas::referenciasProducto($idproducto));
            return true;
        };
    }

    public function loadData(): Closure
    {
        return function ($viewName, $view) {
            if ($viewName === EditProducto::VIEW_USOS) {
                $referencias = TpvRecetas::referenciasProducto((int)$this->mainTabModelValue('idproducto'));
                if (empty($referencias)) {
                    $this->setSettings($viewName, 'active', false);
                    return;
                }

                $view->loadData('', [Where::in('ref_ingrediente', $referencias)], ['ref_plato' => 'ASC'], 0, 0);
                if ($view->count === 0) {
                    $this->setSettings($viewName, 'active', false);
                    return;
                }
                (new TpvCosteEscandallo())->decorar($view->cursor);
                return;
            }

            if ($viewName !== EditProducto::VIEW_NAME) {
                return;
            }

            // referencias (variantes) del producto
            $referencias = TpvRecetas::referenciasProducto((int)$this->mainTabModelValue('idproducto'));
            if (empty($referencias)) {
                $this->setSettings($viewName, 'active', false);
                return;
            }

            $view->loadData('', [Where::in('ref_plato', $referencias)], ['ref_plato' => 'ASC', 'ref_ingrediente' => 'ASC'], 0, 0);

            // plato de la línea nueva: la referencia principal del producto
            $principal = $this->mainTabModelValue('referencia');
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

            // coste teórico y margen de las referencias que tienen receta (los costes, con 4 decimales)
            $resumen = (new TpvCosteEscandallo())->decorar($view->cursor);
            ksort($resumen, SORT_STRING);
            $filas = [];
            foreach ($resumen as $item) {
                $item['coste_txt'] = Tools::money($item['coste'], '', 4);
                $item['coste_ficha_txt'] = Tools::money($item['coste_ficha'], '', 4);
                $filas[] = $item;
            }
            $view->setSettings('tpvCoste', $filas);

            // botón «copiar el coste teórico a la ficha» en el bloque del resumen (un addButton
            // saldría repetido en cada línea de la vista en línea)
            $view->setSettings('tpvCopiarCoste', $this->permissions->allowUpdate && TpvRecetas::hayCosteQueCopiar($resumen));
        };
    }
}
