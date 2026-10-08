<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Extension\Model;

use Closure;
use FacturaScripts\Core\Tools;

/**
 * Validación de familias.tpv_destino: 'cocina' | 'barra' | null (null = heredar).
 *
 * @property string|null $tpv_destino
 */
class Familia
{
    /**
     * Destino efectivo de la familia: el propio o, si es null, el de la primera familia madre
     * que lo defina. null si nadie lo define (la app aplica su destino por defecto).
     */
    public function tpvDestinoEfectivo(): Closure
    {
        return function (): ?string {
            $visitadas = [];
            $familia = $this;
            while ($familia && false === in_array($familia->codfamilia, $visitadas, true)) {
                if (!empty($familia->tpv_destino)) {
                    return $familia->tpv_destino;
                }
                $visitadas[] = $familia->codfamilia;
                if (empty($familia->madre)) {
                    return null;
                }

                $madre = new static();
                $familia = $madre->load($familia->madre) ? $madre : null;
            }

            return null;
        };
    }

    public function test(): Closure
    {
        return function (): bool {
            $valor = $this->tpv_destino ?? null;
            if (null === $valor || '' === trim((string)$valor)) {
                $this->tpv_destino = null;
                return true;
            }

            $valor = mb_strtolower(trim((string)$valor));
            if (false === in_array($valor, ['cocina', 'barra'], true)) {
                Tools::log()->warning('tpv-invalid-destination', ['%value%' => $valor]);
                return false;
            }

            $this->tpv_destino = $valor;
            return true;
        };
    }
}
