<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model\Join;

use FacturaScripts\Dinamic\Model\Join\StockProducto;

/**
 * Join\StockProducto del núcleo para Hostelería › Stock: las filas siguen enlazando a la ficha del
 * producto, pero el listado es ListTpvStock (el «Atrás» de Opciones de la pestaña vuelve aquí y no
 * a Almacén › Productos).
 */
class TpvStockProducto extends StockProducto
{
    public function url(string $type = 'auto', string $list = 'List'): string
    {
        if ($type === 'list' || ($type === 'auto' && empty($this->id()))) {
            return 'ListTpvStock';
        }

        return parent::url($type, $list);
    }
}
