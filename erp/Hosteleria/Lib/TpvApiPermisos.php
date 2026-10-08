<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

/**
 * Recursos de la API REST v3 que usa la app del TPV y los métodos que necesita en cada uno.
 *
 * Fuente: proyecto_comandero/lib/core/facturascripts (fs_resources.dart: requeridosPorElTpv,
 * y los servicios de documents/, accounting/, catalog/ y master_data/). La clave del TPV se
 * crea SIN acceso total y solo con estos permisos.
 *
 * Perfil "pruebas": las suites de integración de la app (test/integration) borran lo que crean
 * (facturas, pedidos, partidas) y crean formas de pago temporales. Esos permisos no los usa la
 * app en producción, así que solo se conceden a petición y la comprobación lo marca como aviso.
 */
final class TpvApiPermisos
{
    /** Descripción con la que se identifica la clave del TPV en api_keys. */
    const DESCRIPCION_CLAVE = 'TPV Comandero';

    /**
     * Permisos de producción: recurso => [get, post, put, delete].
     */
    const PRODUCCION = [
        // documentos de venta y compra
        'facturaclientes' => [true, false, true, false],          // releer factura; PUT de estado/pagada
        'lineafacturaclientes' => [true, false, false, false],
        'pedidoproveedores' => [true, false, false, false],        // idempotencia por numproveedor
        'lineapedidoproveedores' => [true, false, false, false],
        'reciboclientes' => [true, true, true, true],              // cobro mixto: crea, ajusta y borra recibos
        'pagoclientes' => [true, false, false, false],
        // contabilidad (asiento del cierre Z)
        'asientos' => [true, true, false, true],                   // crea y compensa (borra) si falla una partida
        'partidas' => [true, true, false, false],
        'subcuentas' => [true, false, false, false],
        'cuentas' => [true, false, false, false],
        'ejercicios' => [true, false, false, false],
        // catálogo y stock (la escritura de stock va por MySQL directo)
        'productos' => [true, false, false, false],
        'variantes' => [true, false, false, false],
        'stocks' => [true, false, false, false],
        'familias' => [true, false, false, false],
        'impuestos' => [true, false, false, false],
        // datos maestros
        'series' => [true, false, false, false],
        'formapagos' => [true, false, false, false],
        'almacenes' => [true, false, false, false],
        'clientes' => [true, true, false, false],                  // crea el cliente genérico si falta
        'proveedores' => [true, false, false, false],
        'productoproveedores' => [true, false, false, false],
        'empresas' => [true, false, false, false],
        'settings' => [true, false, false, false],
        'estadodocumentos' => [true, false, false, false],
        // endpoints personalizados (solo POST)
        'crearFacturaCliente' => [false, true, false, false],
        'crearPedidoProveedor' => [false, true, false, false],
        'pagarFacturaCliente' => [false, true, false, false],
    ];

    /**
     * Permisos extra del perfil de pruebas (se suman a los de producción).
     */
    const EXTRA_PRUEBAS = [
        'facturaclientes' => [false, false, false, true],
        'pedidoproveedores' => [false, false, false, true],
        'partidas' => [false, false, false, true],
        'formapagos' => [false, true, false, true],
    ];

    const PERFIL_PRODUCCION = 'produccion';
    const PERFIL_PRUEBAS = 'pruebas';

    /**
     * Permisos del perfil indicado: recurso => [get, post, put, delete].
     *
     * @return array<string, bool[]>
     */
    public static function perfil(string $perfil): array
    {
        $permisos = self::PRODUCCION;
        if ($perfil !== self::PERFIL_PRUEBAS) {
            return $permisos;
        }

        foreach (self::EXTRA_PRUEBAS as $recurso => $extra) {
            $base = $permisos[$recurso] ?? [false, false, false, false];
            foreach ($extra as $i => $valor) {
                $base[$i] = $base[$i] || $valor;
            }
            $permisos[$recurso] = $base;
        }

        return $permisos;
    }

    /**
     * Texto corto con los métodos permitidos: "GET, POST".
     */
    public static function metodos(array $flags): string
    {
        $nombres = ['GET', 'POST', 'PUT', 'DELETE'];
        $out = [];
        foreach ($nombres as $i => $nombre) {
            if (!empty($flags[$i])) {
                $out[] = $nombre;
            }
        }

        return implode(', ', $out);
    }
}
