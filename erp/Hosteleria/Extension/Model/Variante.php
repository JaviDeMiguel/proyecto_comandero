<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Model;

use Closure;
use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Tools;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvRecetas;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

/**
 * Variantes que usa el TPV:
 *  - una variante que es ingrediente de alguna receta no se borra (la clave ajena ON DELETE
 *    RESTRICT de tpv_escandallos lo impediría con un error técnico): se avisa de qué platos la usan;
 *  - si se renombra la referencia, el diario de stock del TPV (sin clave ajena) la sigue, como
 *    hacen tpv_escandallos y stocks con su ON UPDATE CASCADE: sin ello, la anulación de una
 *    comanda anterior no encontraría la referencia y fallaría para siempre en la app.
 *
 * Los closures se ejecutan como el modelo Variante ($this):
 *
 * @property string $referencia
 * @method mixed getOriginal(?string $key = null)
 */
class Variante
{
    public function deleteBefore(): Closure
    {
        return function () {
            $platos = TpvRecetas::platosQueUsan([(string)$this->referencia], 11);
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

    public function saveUpdate(): Closure
    {
        return function () {
            $anterior = (string)$this->getOriginal('referencia');
            $nueva = (string)$this->referencia;
            if ($anterior === '' || $anterior === $nueva) {
                return true;
            }

            $db = new DataBase();
            if (false === $db->tableExists(TpvSchema::TABLE_MOVIMIENTOS)) {
                return true;
            }

            // IGNORE: si el diario ya tuviera la misma operación con la referencia nueva (de una
            // variante borrada con ese nombre), esa fila conserva la antigua en lugar de fallar
            $sql = 'UPDATE IGNORE ' . TpvSchema::TABLE_MOVIMIENTOS . ' SET referencia = ' . $db->var2str($nueva)
                . ' WHERE referencia = ' . $db->var2str($anterior) . ';';
            if (false === $db->exec($sql)) {
                Tools::log()->warning('tpv-journal-rename-error', ['%old%' => $anterior, '%new%' => $nueva]);
            }

            // el renombrado de la variante ya está hecho: nunca se deshace por el diario
            return true;
        };
    }
}
