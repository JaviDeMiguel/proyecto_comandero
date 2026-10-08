<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Producto;
use FacturaScripts\Dinamic\Model\TpvEscandallo;
use FacturaScripts\Dinamic\Model\Variante;

/**
 * Coste teórico de un plato a partir de su escandallo.
 *
 * coste de línea = cantidad bruta (neta / (1 - merma / 100)) x coste unitario del ingrediente.
 * Coste unitario del ingrediente = variantes.coste; si es 0 y el ingrediente tiene receta propia
 * (semielaborado), se usa el coste teórico de esa receta (recursivo, con protección de ciclos).
 * El margen se calcula frente al precio de venta SIN impuestos de la variante del plato.
 */
final class TpvCosteEscandallo
{
    const MAX_DEPTH = 10;

    const ORIGEN_FICHA = 'ficha';
    const ORIGEN_RECETA = 'receta';
    const ORIGEN_SIN_COSTE = 'sin-coste';

    /** @var array<string, array{coste: float, origen: string}> */
    private $memo = [];

    /** @var array<string, Variante|null> */
    private $variantes = [];

    /** @var array<int, string> */
    private $descripciones = [];

    /**
     * Calcula el coste de cada línea (añade atributos dinámicos a cada TpvEscandallo:
     * cantidad_bruta, coste_unitario, coste_linea, coste_origen, ingrediente_descripcion)
     * y devuelve el resumen por plato.
     *
     * @param TpvEscandallo[] $lineas
     *
     * @return array<string, array> resumen por referencia de plato
     */
    public function decorar(array $lineas): array
    {
        $resumen = [];
        foreach ($lineas as $linea) {
            $bruta = $linea->cantidadBruta();
            $unitario = $this->costeUnitario((string)$linea->ref_ingrediente);
            $costeLinea = round($bruta * $unitario['coste'], 5);

            $linea->cantidad_bruta = round($bruta, 5);
            $linea->coste_unitario = $unitario['coste'];
            $linea->coste_linea = $costeLinea;
            $linea->coste_origen = $unitario['origen'];
            $linea->ingrediente_descripcion = $this->descripcion((string)$linea->ref_ingrediente);

            $ref = (string)$linea->ref_plato;
            if (false === isset($resumen[$ref])) {
                $resumen[$ref] = $this->cabecera($ref);
            }
            $resumen[$ref]['coste'] += $costeLinea;
            $resumen[$ref]['lineas']++;
            if ($unitario['origen'] === self::ORIGEN_SIN_COSTE) {
                $resumen[$ref]['sin_coste'][] = (string)$linea->ref_ingrediente;
            }
        }

        foreach ($resumen as $ref => $item) {
            $resumen[$ref] = $this->cerrar($item);
        }

        return $resumen;
    }

    /**
     * Resumen de coste y margen de un plato (aunque no tenga receta).
     */
    public function resumenPlato(string $refPlato): array
    {
        $lineas = TpvEscandallo::all([Where::eq('ref_plato', $refPlato)], ['ref_ingrediente' => 'ASC'], 0, 0);
        $resumen = $this->decorar($lineas);
        return $resumen[$refPlato] ?? $this->cerrar($this->cabecera($refPlato));
    }

    /**
     * Coste unitario de una referencia y de dónde sale (ficha de la variante o receta propia).
     *
     * @return array{coste: float, origen: string}
     */
    public function costeUnitario(string $referencia, array $pila = []): array
    {
        $key = mb_strtolower($referencia);
        if (isset($this->memo[$key])) {
            return $this->memo[$key];
        }

        $variante = $this->variante($referencia);
        $coste = $variante ? (float)$variante->coste : 0.0;
        if ($coste > 0) {
            return $this->memo[$key] = ['coste' => $coste, 'origen' => self::ORIGEN_FICHA];
        }

        // semielaborado sin coste en ficha: coste teórico de su propia receta
        if (count($pila) < self::MAX_DEPTH && false === in_array($key, $pila, true)) {
            $pila[] = $key;
            $lineas = TpvEscandallo::all([Where::eq('ref_plato', $referencia)], [], 0, 0);
            if (!empty($lineas)) {
                $total = 0.0;
                foreach ($lineas as $linea) {
                    $sub = $this->costeUnitario((string)$linea->ref_ingrediente, $pila);
                    $total += $linea->cantidadBruta() * $sub['coste'];
                }
                if ($total > 0) {
                    return $this->memo[$key] = ['coste' => round($total, 5), 'origen' => self::ORIGEN_RECETA];
                }
            }
        }

        return $this->memo[$key] = ['coste' => 0.0, 'origen' => self::ORIGEN_SIN_COSTE];
    }

    private function cabecera(string $refPlato): array
    {
        $variante = $this->variante($refPlato);
        return [
            'referencia' => $refPlato,
            'descripcion' => $this->descripcion($refPlato),
            'precio' => $variante ? (float)$variante->precio : 0.0,
            'coste_ficha' => $variante ? (float)$variante->coste : 0.0,
            'coste' => 0.0,
            'lineas' => 0,
            'sin_coste' => [],
        ];
    }

    private function cerrar(array $item): array
    {
        $item['coste'] = round($item['coste'], 5);
        $item['margen'] = round($item['precio'] - $item['coste'], 5);
        $item['margen_pct'] = $item['precio'] > 0 ? round(100 * $item['margen'] / $item['precio'], 2) : null;
        $item['coste_pct'] = $item['precio'] > 0 ? round(100 * $item['coste'] / $item['precio'], 2) : null;
        return $item;
    }

    private function descripcion(string $referencia): string
    {
        $variante = $this->variante($referencia);
        if (null === $variante) {
            return '';
        }

        $idproducto = (int)$variante->idproducto;
        if (false === isset($this->descripciones[$idproducto])) {
            $producto = new Producto();
            $this->descripciones[$idproducto] = $producto->load($idproducto) ? (string)$producto->descripcion : '';
        }

        return $this->descripciones[$idproducto];
    }

    private function variante(string $referencia): ?Variante
    {
        $key = mb_strtolower($referencia);
        if (false === array_key_exists($key, $this->variantes)) {
            $variante = new Variante();
            $this->variantes[$key] = $variante->loadWhereEq('referencia', $referencia) ? $variante : null;
        }

        return $this->variantes[$key];
    }
}
