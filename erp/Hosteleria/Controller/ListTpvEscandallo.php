<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Lib\ExtendedController\ListController;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCosteEscandallo;

/**
 * Listado general de escandallos (todas las líneas de receta de todos los platos).
 */
class ListTpvEscandallo extends ListController
{
    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-recipes';
        $data['icon'] = 'fa-solid fa-utensils';
        return $data;
    }

    protected function createViews()
    {
        $this->createViewsEscandallos();
    }

    protected function createViewsEscandallos(string $viewName = 'ListTpvEscandallo'): void
    {
        $this->addView($viewName, 'TpvEscandallo', 'tpv-recipes', 'fa-solid fa-utensils')
            ->addSearchFields(['ref_plato', 'ref_ingrediente', 'observaciones'])
            ->addOrderBy(['ref_plato', 'ref_ingrediente'], 'tpv-dish', 1)
            ->addOrderBy(['ref_ingrediente', 'ref_plato'], 'tpv-ingredient')
            ->addOrderBy(['cantidad'], 'tpv-net-quantity')
            ->addOrderBy(['merma'], 'tpv-waste-pct')
            ->addOrderBy(['actualizado'], 'tpv-updated')
            ->addFilterAutocomplete('ref_plato', 'tpv-dish', 'ref_plato', 'variantes', 'referencia', 'referencia')
            ->addFilterAutocomplete('ref_ingrediente', 'tpv-ingredient', 'ref_ingrediente', 'variantes', 'referencia', 'referencia')
            ->addFilterNumber('merma-gte', 'tpv-waste-pct', 'merma', '>=')
            ->addFilterCheckbox('con-merma', 'tpv-with-waste', 'merma', '>', 0);
    }

    protected function loadData($viewName, $view)
    {
        parent::loadData($viewName, $view);

        if ($viewName === 'ListTpvEscandallo' && !empty($view->cursor)) {
            (new TpvCosteEscandallo())->decorar($view->cursor);
        }
    }
}
