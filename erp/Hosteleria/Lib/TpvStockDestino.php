<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;

/**
 * Reparto del stock entre cocina y barra (Hostelería › Stock y su comprobación en el asistente).
 *
 * FacturaScripts lleva un solo stock por referencia y almacén (tabla stocks): no hay un stock de
 * cocina y otro de barra. Cada referencia con stock es de cocina o de barra:
 *  1. por el destino TPV de la familia de su producto (familias.tpv_destino, propio o heredado de
 *     la madre, con la misma regla que Extension/Model/Familia::tpvDestinoEfectivo), p. ej. las
 *     bebidas o las subfamilias de materias primas con destino; si no lo tiene,
 *  2. por los platos que se venden (sevende y no bloqueados, como en el TPV) y la usan a cualquier
 *     nivel de receta, según el destino de la familia de cada plato. Si la usan platos de los dos
 *     destinos es de los dos («compartida»).
 * Las reglas de enrutamiento propias del TPV y su destino por defecto no cuentan: solo el destino
 * que define el ERP (los platos sin destino se informan aparte).
 */
final class TpvStockDestino
{
    const BARRA = 'barra';
    const COCINA = 'cocina';

    /** Destinos, en el orden en que se muestran. */
    const DESTINOS = [self::COCINA, self::BARRA];

    /**
     * Destino de cada referencia con fila en stocks, indexado por TpvCatalogo::clave(referencia):
     *  - referencia: tal cual está en stocks;
     *  - destinos: los de su pestaña (vacío = ninguna; los dos = compartida);
     *  - por_familia: true si lo decide la familia del producto;
     *  - usos: destino => platos a la venta de ese destino que la usan (aunque mande la familia);
     *  - platos_sin_destino: platos a la venta sin destino en el ERP que la usan.
     * Vacío si falta familias.tpv_destino.
     *
     * @return array<string, array{referencia: string, destinos: string[], por_familia: bool, usos: array<string, string[]>, platos_sin_destino: string[]}>
     */
    public static function clasificar(): array
    {
        $db = new DataBase();
        $db->connect();
        if (false === $db->tableExists('stocks') || false === $db->tableExists('familias')
            || false === array_key_exists('tpv_destino', $db->getColumns('familias'))) {
            return [];
        }

        $destinosFamilia = self::destinosFamilias($db);
        [$usos, $sinDestino] = self::usosPorDestino($destinosFamilia);

        $out = [];
        $sql = 'SELECT DISTINCT s.referencia, p.codfamilia FROM stocks s'
            . ' LEFT JOIN variantes v ON v.referencia = s.referencia'
            . ' LEFT JOIN productos p ON p.idproducto = v.idproducto';
        foreach ($db->select($sql) as $row) {
            $referencia = (string)$row['referencia'];
            $clave = TpvCatalogo::clave($referencia);
            if (isset($out[$clave])) {
                continue;
            }

            $familia = $destinosFamilia[(string)$row['codfamilia']] ?? null;
            $usosRef = [];
            foreach (self::DESTINOS as $destino) {
                if (!empty($usos[$clave][$destino])) {
                    $usosRef[$destino] = array_map('strval', array_keys($usos[$clave][$destino]));
                }
            }
            $out[$clave] = [
                'referencia' => $referencia,
                'destinos' => null !== $familia ? [$familia] : array_keys($usosRef),
                'por_familia' => null !== $familia,
                'usos' => $usosRef,
                'platos_sin_destino' => array_map('strval', array_keys($sinDestino[$clave] ?? [])),
            ];
        }

        return $out;
    }

    /**
     * Referencias con stock de un destino.
     *
     * @param array|null $clasificacion resultado de clasificar() (se calcula si es null)
     *
     * @return string[]
     */
    public static function referencias(string $destino, ?array $clasificacion = null): array
    {
        $referencias = [];
        foreach ($clasificacion ?? self::clasificar() as $item) {
            if (in_array($destino, $item['destinos'], true)) {
                $referencias[] = $item['referencia'];
            }
        }

        return $referencias;
    }

    /**
     * Destino efectivo de cada familia que lo tiene (propio o heredado): codfamilia => destino.
     */
    private static function destinosFamilias(DataBase $db): array
    {
        $familias = [];
        foreach ($db->select('SELECT codfamilia, madre, tpv_destino FROM familias') as $row) {
            $familias[(string)$row['codfamilia']] = $row;
        }

        $destinos = [];
        foreach (array_keys($familias) as $codfamilia) {
            $destino = self::destinoEfectivo((string)$codfamilia, $familias);
            if (null !== $destino) {
                $destinos[(string)$codfamilia] = $destino;
            }
        }

        return $destinos;
    }

    /**
     * El destino propio o el de la primera madre que lo defina, recorriendo la jerarquía por la
     * clave EXACTA de la madre (como el TPV). null si nadie lo define.
     */
    private static function destinoEfectivo(string $codfamilia, array $familias): ?string
    {
        $visitadas = [];
        $familia = $familias[$codfamilia] ?? null;
        while ($familia && false === isset($visitadas[(string)$familia['codfamilia']])) {
            $destino = mb_strtolower(trim((string)$familia['tpv_destino']));
            if (in_array($destino, self::DESTINOS, true)) {
                return $destino;
            }

            $visitadas[(string)$familia['codfamilia']] = true;
            $madre = (string)$familia['madre'];
            $familia = $madre === '' ? null : ($familias[$madre] ?? null);
        }

        return null;
    }

    /**
     * Platos a la venta que usan cada referencia, a cualquier nivel de receta, según el destino de
     * su familia: [clave => [destino => [plato => true]], clave => [plato sin destino => true]].
     * Los platos que el TPV no vende (sevende = 0, bloqueados o sin variante) no cuentan: sus
     * subrecetas se alcanzan desde los platos que se venden.
     */
    private static function usosPorDestino(array $destinosFamilia): array
    {
        $grafo = TpvGrafoRecetas::cargar();
        $platos = $grafo->platos();
        $catalogo = TpvCatalogo::variantes($platos);

        $usos = [];
        $sinDestino = [];
        foreach ($platos as $plato) {
            $fila = TpvCatalogo::fila($catalogo, $plato);
            if (null === $fila || false === $fila['sevende'] || $fila['bloqueado']) {
                continue;
            }

            $destino = $destinosFamilia[(string)$fila['codfamilia']] ?? null;
            foreach (self::ingredientes($grafo, $plato) as $ingrediente) {
                if (null === $destino) {
                    $sinDestino[TpvCatalogo::clave($ingrediente)][$plato] = true;
                } else {
                    $usos[TpvCatalogo::clave($ingrediente)][$destino][$plato] = true;
                }
            }
        }

        return [$usos, $sinDestino];
    }

    /**
     * Ingredientes de un plato a cualquier nivel (los de sus subrecetas también), sin repetir y
     * sin colgarse si el grafo tiene un ciclo.
     *
     * @return string[]
     */
    private static function ingredientes(TpvGrafoRecetas $grafo, string $plato): array
    {
        $vistos = [];
        $pendientes = [$plato];
        while (!empty($pendientes)) {
            foreach (array_keys($grafo->lineas(array_pop($pendientes))) as $ingrediente) {
                $ingrediente = (string)$ingrediente;
                if (false === isset($vistos[$ingrediente])) {
                    $vistos[$ingrediente] = true;
                    $pendientes[] = $ingrediente;
                }
            }
        }

        return array_map('strval', array_keys($vistos));
    }
}
