<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Variante;

/**
 * Operaciones sobre las recetas que comparten la ficha de producto, los modelos y el asistente.
 */
final class TpvRecetas
{
    /** Diferencia (en €) a partir de la cual el coste de la ficha se considera distinto del teórico. */
    const TOLERANCIA_COSTE = 0.005;

    /**
     * Copia el coste teórico completo de cada referencia con receta a variantes.coste (FS lo usa
     * como coste de las líneas de venta: beneficio de las facturas e informes).
     * Se omiten, con aviso, las recetas con coste incompleto o inválido y las variantes con margen
     * (FS recalcularía su precio de venta a partir del coste).
     *
     * @param string[] $referencias
     *
     * @return int variantes actualizadas
     */
    public static function copiarCosteTeorico(array $referencias): int
    {
        if (empty($referencias)) {
            return 0;
        }

        $costes = new TpvCosteEscandallo();
        $grafo = $costes->grafo();
        $actualizadas = 0;
        foreach ($referencias as $referencia) {
            if (false === $grafo->tieneReceta($referencia)) {
                continue;
            }

            $teorico = $costes->costeUnitario($referencia);
            if ($teorico['origen'] !== TpvCosteEscandallo::ORIGEN_RECETA) {
                Tools::log()->warning('tpv-copy-cost-incomplete', ['%ref%' => $referencia]);
                continue;
            }

            $variante = new Variante();
            if (false === $variante->loadWhereEq('referencia', $referencia)) {
                continue;
            }
            if (abs((float)$variante->coste - $teorico['coste']) <= self::TOLERANCIA_COSTE) {
                continue;
            }
            if ((float)$variante->margen > 0) {
                Tools::log()->warning('tpv-copy-cost-margin', ['%ref%' => $referencia, '%margin%' => Tools::number((float)$variante->margen)]);
                continue;
            }

            $variante->coste = round($teorico['coste'], 5);
            if (false === $variante->save()) {
                Tools::log()->error('record-save-error');
                continue;
            }
            $actualizadas++;
        }

        if ($actualizadas > 0) {
            Tools::log()->notice('tpv-copy-cost-done', ['%count%' => $actualizadas]);
        }
        return $actualizadas;
    }

    /**
     * true si alguna de las referencias es ingrediente de alguna receta.
     *
     * @param string[] $referencias
     */
    public static function esIngrediente(array $referencias): bool
    {
        return !empty(self::platosQueUsan($referencias, 1));
    }

    /**
     * true si en el resumen de TpvCosteEscandallo::decorar() hay algún plato con coste teórico
     * completo distinto del de su ficha que se pueda copiar (sin margen en la variante).
     */
    public static function hayCosteQueCopiar(array $resumen): bool
    {
        foreach ($resumen as $item) {
            if ($item['lineas'] > 0 && $item['completo'] && $item['coste'] > 0
                && ($item['margen_ficha'] ?? 0) <= 0
                && abs($item['coste'] - $item['coste_ficha']) > self::TOLERANCIA_COSTE) {
                return true;
            }
        }

        return false;
    }

    /**
     * Platos (ref_plato) cuyas recetas usan como ingrediente alguna de las referencias.
     *
     * @param string[] $referencias
     *
     * @return string[]
     */
    public static function platosQueUsan(array $referencias, int $limite = 0): array
    {
        $referencias = array_values(array_filter(array_map('strval', $referencias), 'strlen'));
        $db = new DataBase();
        if (empty($referencias) || false === $db->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return [];
        }

        $sql = 'SELECT DISTINCT ref_plato FROM ' . TpvSchema::TABLE_ESCANDALLOS
            . Where::multiSqlLegacy([Where::in('ref_ingrediente', $referencias)])
            . ' ORDER BY ref_plato';
        $platos = [];
        $rows = $limite > 0 ? $db->selectLimit($sql, $limite) : $db->select($sql);
        foreach ($rows as $row) {
            $platos[] = (string)$row['ref_plato'];
        }

        return $platos;
    }

    /**
     * Referencias (variantes) de un producto.
     *
     * @return string[]
     */
    public static function referenciasProducto(int $idproducto): array
    {
        if ($idproducto <= 0) {
            return [];
        }

        $referencias = [];
        foreach (Variante::all([Where::eq('idproducto', $idproducto)], ['referencia' => 'ASC'], 0, 0) as $variante) {
            $referencias[] = (string)$variante->referencia;
        }

        return $referencias;
    }
}
