<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\EditController;
use FacturaScripts\Dinamic\Model\TpvEscandallo;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCosteEscandallo;

/**
 * Ficha de una línea de escandallo. Las recetas completas se editan normalmente desde la
 * pestaña "Escandallo" de la ficha de producto.
 */
class EditTpvEscandallo extends EditController
{
    public function getModelClassName(): string
    {
        return 'TpvEscandallo';
    }

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-recipe-line';
        $data['icon'] = 'fa-solid fa-utensils';
        $data['showonmenu'] = false;
        return $data;
    }

    protected function loadData($viewName, $view)
    {
        parent::loadData($viewName, $view);

        // el modelo de la pestaña principal es la línea (BaseView lo declara como ModelClass genérico)
        $linea = $view->model;
        if ($viewName !== $this->mainTabName() || false === ($linea instanceof TpvEscandallo) || false === $linea->exists()) {
            return;
        }

        (new TpvCosteEscandallo())->decorar([$linea]);

        // enlace a la receta completa en la ficha del producto del plato (si el usuario puede abrirla)
        $idproducto = $linea->plato_idproducto;
        if ($idproducto && $this->user->can('EditProducto')) {
            $view->addButton([
                'action' => 'EditProducto?code=' . $idproducto . '&activetab=EditTpvEscandalloProducto',
                'icon' => 'fa-solid fa-utensils',
                'label' => 'tpv-recipe',
                'type' => 'link',
            ]);
        }
    }
}
