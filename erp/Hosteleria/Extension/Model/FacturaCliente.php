<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Model;

use Closure;

/**
 * Rectificativas de los tickets del TPV.
 *
 * La app identifica cada ticket por numero2 = 'TPV-<id>' (clave idempotente: antes de reenviar un
 * ticket busca la factura con ese numero2 y, si encuentra más de una, se detiene). FacturaScripts
 * copia numero2 al crear una rectificativa (EditFacturaCliente y la API
 * crearFacturaRectificativaCliente), así que la rectificativa nace con la misma clave que el ticket.
 * Se le antepone una «R» para que la clave del ticket siga siendo única (y la rectificativa no se
 * cuente como un ticket más).
 *
 * Los closures se ejecutan como el modelo FacturaCliente ($this):
 *
 * @property int|null $idfacturarect
 * @property string|null $numero2
 * @method bool exists()
 */
class FacturaCliente
{
    /** Prefijo de numero2 de las facturas que crea el TPV (Ticket.claveFactura en la app). */
    const PREFIJO_TICKET = 'TPV-';

    /** Longitud de facturascli.numero2. */
    const MAX_NUMERO2 = 50;

    public function saveBefore(): Closure
    {
        return function () {
            $numero2 = (string)$this->numero2;
            if ($this->exists() || empty($this->idfacturarect)
                || 0 !== strpos($numero2, FacturaCliente::PREFIJO_TICKET)) {
                return true;
            }

            $this->numero2 = mb_substr('R' . $numero2, 0, FacturaCliente::MAX_NUMERO2);
            return true;
        };
    }
}
