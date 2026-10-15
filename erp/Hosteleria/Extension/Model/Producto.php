<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Model;

use Closure;
use FacturaScripts\Core\Tools;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvRecetas;

/**
 * Un producto con alguna variante que es ingrediente de una receta no se borra (la clave ajena
 * ON DELETE RESTRICT de tpv_escandallos lo impediría con un error técnico): se avisa de qué platos
 * lo usan. La ficha de producto ya oculta el botón de borrar en ese caso (el núcleo borra las
 * imágenes del producto antes de llegar aquí).
 *
 * @property int $idproducto
 * @property string $referencia
 */
class Producto
{
    public function deleteBefore(): Closure
    {
        return function () {
            $platos = TpvRecetas::platosQueUsan(TpvRecetas::referenciasProducto((int)$this->idproducto), 11);
            if (empty($platos)) {
                return true;
            }

            Tools::log()->warning('tpv-cant-delete-ingredient', [
                '%ref%' => $this->referencia,
                '%dishes%' => implode(', ', array_slice($platos, 0, 10)) . (count($platos) > 10 ? '…' : ''),
            ]);
            return false;
        };
    }
}
