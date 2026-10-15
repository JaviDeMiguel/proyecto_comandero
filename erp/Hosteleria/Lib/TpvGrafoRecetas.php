<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use RuntimeException;

/**
 * Grafo de recetas (tpv_escandallos) en memoria, con las MISMAS reglas que el motor de
 * escandallos de la app (proyecto_comandero, lib/core/isolates/escandallos/escandallo_engine.dart):
 *  - un ingrediente con receta propia (semielaborado) se expande SIEMPRE a sus hojas; solo las
 *    hojas se descuentan del almacén y solo su coste cuenta para el coste teórico;
 *  - las claves son EXACTAS: el motor distingue mayúsculas, así que el plugin guarda cada
 *    referencia tal como está en variantes;
 *  - un ciclo o una cadena de más de MAX_PROFUNDIDAD platos con receta invalidan el grafo
 *    COMPLETO: la app no descuenta stock de ninguna venta hasta que se corrige.
 */
final class TpvGrafoRecetas
{
    /** EscandalloRequest.maxProfundidad de la app (niveles de platos con receta en una cadena). */
    const MAX_PROFUNDIDAD = 20;

    /** @var array<string, int> */
    private $memoAltura = [];

    /** @var array<string, int> */
    private $memoArriba = [];

    /** @var array<string, array<string, float>> hojas por unidad ya resueltas */
    private $memoHojas = [];

    /** @var array<string, int> altura de cada plato resuelto por resolver() */
    private $memoNiveles = [];

    /** @var array<string, array<string, array{cantidad: float, merma: float}>> plato => ingrediente => línea */
    private $recetas = [];

    /** @var array<string, string[]>|null ingrediente => platos que lo usan */
    private $usos = null;

    /**
     * Grafo con todas las líneas de tpv_escandallos (una sola consulta).
     */
    public static function cargar(): self
    {
        $grafo = new self();
        $db = new DataBase();
        if (false === $db->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $grafo;
        }

        $sql = 'SELECT ref_plato, ref_ingrediente, cantidad, merma FROM ' . TpvSchema::TABLE_ESCANDALLOS;
        foreach ($db->select($sql) as $row) {
            $grafo->poner((string)$row['ref_plato'], (string)$row['ref_ingrediente'], (float)$row['cantidad'], (float)$row['merma']);
        }

        return $grafo;
    }

    /**
     * Cantidad bruta = neta / (1 - merma / 100), como el motor de la app.
     */
    public static function bruta(float $neta, float $merma): float
    {
        if ($merma < 0 || $merma >= 100) {
            return $neta;
        }

        return $neta / (1 - $merma / 100);
    }

    /**
     * Platos con receta en la cadena más larga que termina en $plato, contándolo a él (1 si
     * ninguna receta lo usa). Ignora los ciclos (los detecta camino()).
     */
    public function alturaArriba(string $plato): int
    {
        return $this->arriba($plato, []);
    }

    /**
     * Niveles de subreceta por debajo de una referencia, contándola si tiene receta: 0 si es una
     * hoja, 1 si todos sus ingredientes son hojas, etc. (la «altura» del motor de la app).
     * Ignora los ciclos (los detecta camino()).
     */
    public function altura(string $referencia): int
    {
        return $this->abajo($referencia, []);
    }

    /**
     * Camino de recetas desde $desde hasta $hasta (plato -> ingrediente -> ...), o null si no
     * existe. Añadir la línea plato -> ingrediente crea un ciclo si el plato se alcanza desde el
     * ingrediente. Sin límite de nodos: el conjunto de visitados garantiza que termina.
     *
     * @return string[]|null
     */
    public function camino(string $desde, string $hasta): ?array
    {
        if ($desde === $hasta) {
            return [$desde];
        }

        $padre = [$desde => null];
        $pendientes = [$desde];
        while (!empty($pendientes)) {
            $actual = array_shift($pendientes);
            foreach (array_keys($this->recetas[$actual] ?? []) as $siguiente) {
                $siguiente = (string)$siguiente;
                if (array_key_exists($siguiente, $padre)) {
                    continue;
                }

                $padre[$siguiente] = $actual;
                if ($siguiente === $hasta) {
                    $camino = [$siguiente];
                    while (null !== $padre[$camino[0]]) {
                        array_unshift($camino, $padre[$camino[0]]);
                    }
                    return $camino;
                }

                $pendientes[] = $siguiente;
            }
        }

        return null;
    }

    /**
     * Errores del grafo completo tal como los encontraría la app al resolver: ciclos y cadenas de
     * más de MAX_PROFUNDIDAD platos con receta. Cada error: tipo ('ciclo' | 'profundidad') y
     * camino (referencias).
     *
     * @return array[]
     */
    public function errores(int $limite = 20): array
    {
        $errores = [];
        $vistos = [];
        foreach ($this->platos() as $plato) {
            if (count($errores) >= $limite) {
                break;
            }

            try {
                $pila = [];
                $this->resolver($plato, $pila);
            } catch (RuntimeException $e) {
                $error = json_decode($e->getMessage(), true);
                $firma = $error['tipo'] . ':' . implode('|', self::ordenarCiclo($error['camino'], $error['tipo']));
                if (false === isset($vistos[$firma])) {
                    $vistos[$firma] = true;
                    $errores[] = $error;
                }
            }
        }

        return $errores;
    }

    /**
     * Hojas (materias primas) y cantidad bruta por UNA unidad de la referencia, como
     * _Resolutor.hojasPorUnidad de la app. Una hoja se devuelve a sí misma con cantidad 1.
     * Null si su receta es cíclica o demasiado profunda.
     *
     * @return array<string, float>|null
     */
    public function hojasPorUnidad(string $referencia): ?array
    {
        if (false === $this->tieneReceta($referencia)) {
            return [$referencia => 1.0];
        }

        try {
            $pila = [];
            return $this->resolver($referencia, $pila);
        } catch (RuntimeException) {
            return null;
        }
    }

    /**
     * Líneas de la receta de un plato: ingrediente => [cantidad, merma].
     *
     * @return array<string, array{cantidad: float, merma: float}>
     */
    public function lineas(string $plato): array
    {
        return $this->recetas[$plato] ?? [];
    }

    /**
     * Platos con receta, en orden.
     *
     * @return string[]
     */
    public function platos(): array
    {
        $platos = array_map('strval', array_keys($this->recetas));
        sort($platos, SORT_STRING);
        return $platos;
    }

    public function poner(string $plato, string $ingrediente, float $cantidad = 1.0, float $merma = 0.0): void
    {
        $this->recetas[$plato][$ingrediente] = ['cantidad' => $cantidad, 'merma' => $merma];
        $this->reiniciar();
    }

    public function quitar(string $plato, string $ingrediente): void
    {
        unset($this->recetas[$plato][$ingrediente]);
        if (empty($this->recetas[$plato])) {
            unset($this->recetas[$plato]);
        }
        $this->reiniciar();
    }

    public function tieneReceta(string $referencia): bool
    {
        return !empty($this->recetas[$referencia]);
    }

    /**
     * Platos cuya receta usa directamente la referencia.
     *
     * @return string[]
     */
    public function usosDe(string $referencia): array
    {
        if (null === $this->usos) {
            $this->usos = [];
            foreach ($this->recetas as $plato => $lineas) {
                foreach (array_keys($lineas) as $ingrediente) {
                    $this->usos[(string)$ingrediente][] = (string)$plato;
                }
            }
        }

        return $this->usos[$referencia] ?? [];
    }

    private function abajo(string $referencia, array $visitando): int
    {
        if (false === $this->tieneReceta($referencia)) {
            return 0;
        }
        if (isset($this->memoAltura[$referencia])) {
            return $this->memoAltura[$referencia];
        }

        $visitando[$referencia] = true;
        $maximo = 0;
        foreach (array_keys($this->recetas[$referencia]) as $ingrediente) {
            $ingrediente = (string)$ingrediente;
            if (isset($visitando[$ingrediente])) {
                continue;
            }
            $maximo = max($maximo, $this->abajo($ingrediente, $visitando));
        }

        return $this->memoAltura[$referencia] = $maximo + 1;
    }

    private function arriba(string $plato, array $visitando): int
    {
        if (isset($this->memoArriba[$plato])) {
            return $this->memoArriba[$plato];
        }

        $visitando[$plato] = true;
        $maximo = 0;
        foreach ($this->usosDe($plato) as $usuario) {
            if (isset($visitando[$usuario])) {
                continue;
            }
            $maximo = max($maximo, $this->arriba($usuario, $visitando));
        }

        return $this->memoArriba[$plato] = $maximo + 1;
    }

    /**
     * Rota un ciclo para que empiece por su referencia menor (dos raíces que encuentran el mismo
     * ciclo dan la misma firma).
     */
    private static function ordenarCiclo(array $camino, string $tipo): array
    {
        if ($tipo !== 'ciclo' || count($camino) < 2) {
            return $camino;
        }

        $nodos = array_slice($camino, 0, -1);
        $menor = array_keys($nodos, min($nodos))[0];
        return array_merge(array_slice($nodos, $menor), array_slice($nodos, 0, $menor));
    }

    private function reiniciar(): void
    {
        $this->memoAltura = [];
        $this->memoArriba = [];
        $this->memoHojas = [];
        $this->memoNiveles = [];
        $this->usos = null;
    }

    /**
     * _Resolutor.hojasPorUnidad de la app: memoiza por plato, detecta ciclos con la pila del
     * recorrido y limita la profundidad por la pila y por la altura de cada plato.
     *
     * @return array<string, float>
     * @throws RuntimeException con el error en JSON (tipo y camino)
     */
    private function resolver(string $plato, array &$pila): array
    {
        if (isset($this->memoHojas[$plato])) {
            return $this->memoHojas[$plato];
        }

        $posicion = array_search($plato, $pila, true);
        if (false !== $posicion) {
            throw new RuntimeException(json_encode([
                'tipo' => 'ciclo',
                'camino' => array_merge(array_slice($pila, $posicion), [$plato]),
            ]));
        }

        $pila[] = $plato;
        if (count($pila) > self::MAX_PROFUNDIDAD) {
            throw new RuntimeException(json_encode(['tipo' => 'profundidad', 'camino' => $pila]));
        }

        // mismo orden que la app (la suma en coma flotante no es asociativa)
        $lineas = $this->recetas[$plato];
        ksort($lineas, SORT_STRING);

        $hojas = [];
        $altura = 1;
        foreach ($lineas as $ingrediente => $linea) {
            $ingrediente = (string)$ingrediente;
            $bruta = self::bruta($linea['cantidad'], $linea['merma']);
            if ($this->tieneReceta($ingrediente)) {
                $sub = $this->resolver($ingrediente, $pila);
                $altura = max($altura, $this->memoNiveles[$ingrediente] + 1);
                foreach ($sub as $hoja => $cantidad) {
                    $hojas[$hoja] = ($hojas[$hoja] ?? 0.0) + $bruta * $cantidad;
                }
                continue;
            }

            $hojas[$ingrediente] = ($hojas[$ingrediente] ?? 0.0) + $bruta;
        }

        array_pop($pila);
        if ($altura > self::MAX_PROFUNDIDAD) {
            throw new RuntimeException(json_encode(['tipo' => 'profundidad', 'camino' => [$plato]]));
        }

        $this->memoNiveles[$plato] = $altura;
        return $this->memoHojas[$plato] = $hojas;
    }
}
