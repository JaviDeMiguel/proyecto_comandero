<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\EditController;
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

        if ($viewName === $this->getMainViewName() && $view->model->exists()) {
            (new TpvCosteEscandallo())->decorar([$view->model]);

            // enlace a la ficha del producto del plato
            $plato = $view->model->getPlato();
            if ($plato) {
                $view->addButton([
                    'action' => $plato->url() . '&activetab=EditTpvEscandalloProducto',
                    'icon' => 'fa-solid fa-utensils',
                    'label' => 'tpv-recipe',
                    'type' => 'link',
                ]);
            }
        }
    }
}
