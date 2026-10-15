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
 * Misma regla que la app (FamiliaCatalogo.normalizarDestino y EnrutamientoComandas): un valor que
 * no sea cocina o barra (con espacios o mayúsculas aparte) cuenta como heredar, y la jerarquía se
 * recorre por la clave EXACTA de la madre (por eso se guarda la madre tal como está escrita su
 * familia: la collation de MySQL no distingue mayúsculas, el TPV sí).
 *
 * Los closures se ejecutan como el modelo Familia ($this, y new static() crea otra familia):
 *
 * @property string|null $codfamilia
 * @property string|null $madre
 * @property string|null $tpv_destino
 * @method bool load($code)
 */
class Familia
{
    /**
     * Destino efectivo en el ERP: el propio o, si no tiene, el de la primera familia madre que lo
     * defina. null si nadie lo define (la app aplica su destino por defecto). Las reglas de
     * enrutamiento del TPV tienen prioridad sobre él en cada nivel.
     */
    public function tpvDestinoEfectivo(): Closure
    {
        return function (): ?string {
            $visitadas = [];
            $familia = $this;
            while ($familia && false === in_array($familia->codfamilia, $visitadas, true)) {
                $destino = mb_strtolower(trim((string)$familia->tpv_destino));
                if (in_array($destino, ['cocina', 'barra'], true)) {
                    return $destino;
                }
                $visitadas[] = $familia->codfamilia;
                if (empty($familia->madre)) {
                    return null;
                }

                $madre = new static();
                $familia = $madre->load($familia->madre) && $madre->codfamilia === $familia->madre ? $madre : null;
            }

            return null;
        };
    }

    public function test(): Closure
    {
        return function (): bool {
            // la madre, tal como está escrita su familia (el TPV la busca por clave exacta)
            if (!empty($this->madre)) {
                $madre = new static();
                if ($madre->load($this->madre) && $madre->codfamilia !== $this->madre) {
                    $this->madre = $madre->codfamilia;
                }
            }

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
