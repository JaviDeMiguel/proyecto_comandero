<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\TpvEscandallo;

/**
 * Coste teórico de un plato a partir de su escandallo, con la MISMA regla que el motor de
 * escandallos de la app (TpvGrafoRecetas):
 *  - cantidad bruta de una línea = neta / (1 - merma / 100);
 *  - un ingrediente con receta propia (semielaborado) se expande siempre hasta sus hojas: su
 *    coste es el de su receta y el coste de su ficha se ignora (el TPV descuenta las hojas);
 *  - una hoja cuesta lo que diga su ficha (variantes.coste > 0); si no tiene coste, el coste del
 *    plato queda incompleto (cota inferior) y se lista en sin_coste;
 *  - una receta cíclica o de más de TpvGrafoRecetas::MAX_PROFUNDIDAD niveles no tiene coste.
 * El margen se calcula frente al precio de venta SIN impuestos de la variante del plato.
 */
final class TpvCosteEscandallo
{
    const ORIGEN_FICHA = 'ficha';
    const ORIGEN_RECETA = 'receta';
    const ORIGEN_RECETA_INCOMPLETA = 'receta-incompleta';
    const ORIGEN_RECETA_INVALIDA = 'receta-invalida';
    const ORIGEN_SIN_COSTE = 'sin-coste';

    /** @var array<string, array> datos de TpvCatalogo::variantes() */
    private $datos = [];

    /** @var TpvGrafoRecetas|null */
    private $grafo = null;

    /** @var array<string, array{coste: float, origen: string, faltan: string[]}> */
    private $memo = [];

    /**
     * Calcula el coste de cada línea (añade atributos dinámicos a cada TpvEscandallo:
     * cantidad_bruta, descuento_tpv, coste_unitario, coste_linea, coste_origen,
     * ingrediente_descripcion, ingrediente_idproducto, plato_descripcion, plato_idproducto)
     * y devuelve el resumen por plato.
     *
     * @param TpvEscandallo[] $lineas
     *
     * @return array<string, array> resumen por referencia de plato
     */
    public function decorar(array $lineas): array
    {
        $this->precargar($lineas);

        $resumen = [];
        foreach ($lineas as $linea) {
            $plato = (string)$linea->ref_plato;
            $ingrediente = (string)$linea->ref_ingrediente;
            $bruta = $linea->cantidadBruta();
            $unitario = $this->costeUnitario($ingrediente);
            $costeLinea = round($bruta * $unitario['coste'], 5);

            $linea->cantidad_bruta = round($bruta, 5);
            // un semielaborado no se descuenta: el TPV descuenta sus materias primas
            $linea->descuento_tpv = $this->grafo()->tieneReceta($ingrediente) ? null : round($bruta, TpvEscandallo::DECIMALES_STOCK);
            $linea->coste_unitario = $unitario['coste'];
            $linea->coste_linea = $costeLinea;
            $linea->coste_origen = $unitario['origen'];
            $linea->ingrediente_descripcion = $this->dato($ingrediente, 'descripcion', '');
            $linea->ingrediente_idproducto = $this->dato($ingrediente, 'idproducto');
            $linea->plato_descripcion = $this->dato($plato, 'descripcion', '');
            $linea->plato_idproducto = $this->dato($plato, 'idproducto');

            if (false === isset($resumen[$plato])) {
                $resumen[$plato] = $this->cabecera($plato);
            }
            $resumen[$plato]['coste'] += $costeLinea;
            $resumen[$plato]['lineas']++;
            foreach ($unitario['faltan'] as $falta) {
                $resumen[$plato]['sin_coste'][$falta] = $falta;
            }
            if ($unitario['origen'] === self::ORIGEN_RECETA_INVALIDA) {
                $resumen[$plato]['invalida'] = true;
            }
        }

        foreach ($resumen as $ref => $item) {
            // la receta del propio plato también puede pasar del límite (exactamente un nivel más
            // que la de su ingrediente más profundo): la app no lo resolvería
            if ($this->grafo()->tieneReceta((string)$ref) && null === $this->grafo()->hojasPorUnidad((string)$ref)) {
                $item['invalida'] = true;
            }
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
        if (isset($resumen[$refPlato])) {
            return $resumen[$refPlato];
        }

        $this->precargarReferencias([$refPlato]);
        return $this->cerrar($this->cabecera($refPlato));
    }

    /**
     * Coste unitario de una referencia y de dónde sale: ficha (hoja con coste), sin-coste (hoja
     * sin coste), receta (semielaborado con todas sus hojas con coste), receta-incompleta (falta
     * el coste de alguna hoja: faltan) o receta-invalida (ciclo o demasiados niveles).
     *
     * @return array{coste: float, origen: string, faltan: string[]}
     */
    public function costeUnitario(string $referencia): array
    {
        if (isset($this->memo[$referencia])) {
            return $this->memo[$referencia];
        }

        $grafo = $this->grafo();
        if (false === $grafo->tieneReceta($referencia)) {
            $coste = (float)$this->dato($referencia, 'coste', 0.0);
            return $this->memo[$referencia] = $coste > 0 ?
                ['coste' => $coste, 'origen' => self::ORIGEN_FICHA, 'faltan' => []] :
                ['coste' => 0.0, 'origen' => self::ORIGEN_SIN_COSTE, 'faltan' => [$referencia]];
        }

        $hojas = $grafo->hojasPorUnidad($referencia);
        if (null === $hojas) {
            return $this->memo[$referencia] = ['coste' => 0.0, 'origen' => self::ORIGEN_RECETA_INVALIDA, 'faltan' => []];
        }

        $this->precargarReferencias(array_keys($hojas));
        $total = 0.0;
        $faltan = [];
        foreach ($hojas as $hoja => $cantidad) {
            $coste = (float)$this->dato((string)$hoja, 'coste', 0.0);
            if ($coste > 0) {
                $total += $cantidad * $coste;
                continue;
            }
            $faltan[] = (string)$hoja;
        }

        return $this->memo[$referencia] = [
            'coste' => round($total, 5),
            'origen' => empty($faltan) ? self::ORIGEN_RECETA : self::ORIGEN_RECETA_INCOMPLETA,
            'faltan' => $faltan,
        ];
    }

    /**
     * Grafo de recetas usado en los cálculos (se carga una vez por instancia).
     */
    public function grafo(): TpvGrafoRecetas
    {
        if (null === $this->grafo) {
            $this->grafo = TpvGrafoRecetas::cargar();
        }

        return $this->grafo;
    }

    private function cabecera(string $refPlato): array
    {
        return [
            'referencia' => $refPlato,
            'descripcion' => $this->dato($refPlato, 'descripcion', ''),
            'idproducto' => $this->dato($refPlato, 'idproducto'),
            'precio' => (float)$this->dato($refPlato, 'precio', 0.0),
            'coste_ficha' => (float)$this->dato($refPlato, 'coste', 0.0),
            // margen de la variante: con margen > 0, FS recalcula el precio a partir del coste
            'margen_ficha' => (float)$this->dato($refPlato, 'margen', 0.0),
            'coste' => 0.0,
            'lineas' => 0,
            'sin_coste' => [],
            'invalida' => false,
        ];
    }

    private function cerrar(array $item): array
    {
        $item['sin_coste'] = array_values($item['sin_coste']);
        sort($item['sin_coste'], SORT_STRING);
        $item['coste'] = round($item['coste'], 5);
        $item['completo'] = empty($item['sin_coste']) && false === $item['invalida'];

        // sin precio de venta (semielaborados, materias primas) no hay margen que calcular
        $conPrecio = $item['precio'] > 0;
        $item['margen'] = $conPrecio ? round($item['precio'] - $item['coste'], 5) : null;
        $item['margen_pct'] = $conPrecio ? round(100 * $item['margen'] / $item['precio'], 2) : null;
        $item['coste_pct'] = $conPrecio ? round(100 * $item['coste'] / $item['precio'], 2) : null;
        return $item;
    }

    /**
     * Valor de un campo de la variante (y su producto) de una referencia.
     */
    private function dato(string $referencia, string $campo, $defecto = null)
    {
        $this->precargarReferencias([$referencia]);
        $fila = TpvCatalogo::fila($this->datos, $referencia);
        return $fila[$campo] ?? $defecto;
    }

    /**
     * Carga en una consulta los datos de todas las referencias de las líneas y de las hojas de
     * sus subrecetas.
     *
     * @param TpvEscandallo[] $lineas
     */
    private function precargar(array $lineas): void
    {
        $referencias = [];
        foreach ($lineas as $linea) {
            $referencias[] = (string)$linea->ref_plato;
            $referencias[] = (string)$linea->ref_ingrediente;
            $hojas = $this->grafo()->hojasPorUnidad((string)$linea->ref_ingrediente) ?? [];
            foreach (array_keys($hojas) as $hoja) {
                $referencias[] = (string)$hoja;
            }
        }

        $this->precargarReferencias($referencias);
    }

    private function precargarReferencias(array $referencias): void
    {
        $faltan = [];
        foreach ($referencias as $referencia) {
            $clave = TpvCatalogo::clave((string)$referencia);
            if ($clave !== '' && false === array_key_exists($clave, $this->datos)) {
                $faltan[] = (string)$referencia;
                // las que no existan en variantes quedan registradas como inexistentes
                $this->datos[$clave] = null;
            }
        }

        if (empty($faltan)) {
            return;
        }

        foreach (TpvCatalogo::variantes($faltan) as $clave => $fila) {
            $this->datos[$clave] = $fila;
        }
    }
}
