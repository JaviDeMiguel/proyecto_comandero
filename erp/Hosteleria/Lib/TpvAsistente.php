<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Cache;
use FacturaScripts\Core\DbUpdater;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Almacen;
use FacturaScripts\Dinamic\Model\ApiAccess;
use FacturaScripts\Dinamic\Model\ApiKey;
use FacturaScripts\Dinamic\Model\Cliente;
use FacturaScripts\Dinamic\Model\Cuenta;
use FacturaScripts\Dinamic\Model\CuentaBanco;
use FacturaScripts\Dinamic\Model\Ejercicio;
use FacturaScripts\Dinamic\Model\FacturaCliente;
use FacturaScripts\Dinamic\Model\Familia;
use FacturaScripts\Dinamic\Model\FormaPago;
use FacturaScripts\Dinamic\Model\Producto;
use FacturaScripts\Dinamic\Model\Serie;
use FacturaScripts\Dinamic\Model\Subcuenta;

/**
 * Asistente "Configurar TPV": comprobaciones (ok / aviso / error) de todo lo que la app del
 * TPV espera encontrar en FacturaScripts y acciones para corregir cada una.
 *
 * Todas las acciones son idempotentes: vuelven a comprobar antes de escribir, crean solo lo que
 * falta y las que MODIFICAN datos existentes del usuario exigen confirmación explícita
 * (parámetro confirm = 1, que la vista pide con un diálogo).
 */
final class TpvAsistente
{
    /** Códigos por defecto de la app (contrato con proyecto_comandero, FiscalSettings). */
    const CODPAGO_EFECTIVO = 'TPVEFE';
    const CODPAGO_TARJETA = 'TPVTAR';
    const CODCLIENTE = 'TPV';
    const NOMBRE_CLIENTE = 'CLIENTES VARIOS (TPV)';
    const CODSERIE = 'S';

    const CUENTA_CAJA = '570';
    const CUENTA_BANCO = '572';

    /** Cuentas cuyas subcuentas resuelve la app para el asiento del cierre Z (FsAccountingService). */
    const CUENTAS_CIERRE_Z = ['570', '572', '700', '477', '659', '759'];

    /** Elementos que se listan como detalle de una comprobación (el resto se resume). */
    const MAX_DETALLES = 15;

    /** Días a partir de los cuales un pedido de reposición sin recibir se considera olvidado. */
    const DIAS_PEDIDO_ABIERTO = 7;

    const OK = 'ok';
    const AVISO = 'aviso';
    const ERROR = 'error';

    /** Acciones que modifican datos existentes: requieren confirm = 1. */
    const ACCIONES_CON_CONFIRMACION = [
        'adjust-payments', 'fix-customer', 'fix-serie', 'fix-api-key', 'api-key-test-profile',
        'regenerate-api-key', 'enable-api-key', 'fix-dishes', 'fix-ingredients', 'fix-recipe-refs',
        'fix-sale-without-stock', 'copy-costs', 'fix-refund-keys',
    ];

    /** Secciones de la página, en orden: grupo => ids de sus comprobaciones, en orden. */
    const GRUPOS = [
        'tpv-group-connection' => ['api', 'apikey', 'tablas', 'rol'],
        'tpv-group-accounting' => ['ejercicio', 'cuentas', 'subcuentas', 'pago-tpvefe', 'pago-tpvtar', 'cliente', 'serie', 'almacen'],
        'tpv-group-recipes' => ['recetas', 'platos', 'materias', 'mixtos', 'ventasinstock', 'costes', 'reposicion', 'stock'],
        'tpv-group-menu' => ['carta', 'claves'],
    ];

    // -----------------------------------------------------------------------------------------
    // Comprobaciones

    /**
     * Lista de comprobaciones en el orden en que se muestran.
     *
     * @return array[] cada una: id, titulo, estado, mensaje, detalles[], acciones[], clave, grupo
     */
    public function comprobaciones(): array
    {
        $porId = [];
        foreach ($this->todasLasComprobaciones() as $check) {
            $porId[$check['id']] = $check;
        }

        $checks = [];
        foreach (self::GRUPOS as $grupo => $ids) {
            foreach ($ids as $id) {
                if (isset($porId[$id])) {
                    $checks[] = $porId[$id] + ['grupo' => $grupo];
                    unset($porId[$id]);
                }
            }
        }

        // una comprobación nueva que aún no esté en GRUPOS sale al final, sin sección
        foreach ($porId as $check) {
            $checks[] = $check + ['grupo' => ''];
        }

        return $checks;
    }

    /**
     * @return array[]
     */
    private function todasLasComprobaciones(): array
    {
        return [
            $this->checkApi(),
            $this->checkEjercicio(),
            $this->checkCuentas(),
            $this->checkSubcuentasCierre(),
            $this->checkFormaPago(self::CODPAGO_EFECTIVO),
            $this->checkFormaPago(self::CODPAGO_TARJETA),
            $this->checkCliente(),
            $this->checkSerie(),
            $this->checkAlmacen(),
            $this->checkApiKey(),
            $this->checkTablas(),
            $this->checkRol(),
            $this->checkRecetas(),
            $this->checkPlatos(),
            $this->checkMateriasPrimas(),
            $this->checkProductosMixtos(),
            $this->checkVentaSinStock(),
            $this->checkCostes(),
            $this->checkReposicion(),
            $this->checkStockDestinos(),
            $this->checkCarta(),
            $this->checkClavesDuplicadas(),
        ];
    }

    public function checkApi(): array
    {
        $check = $this->check('api', 'tpv-check-api');
        $enabled = (bool)Tools::settings('default', 'enable_api', false);
        if ($enabled) {
            return $this->estado($check, self::OK, 'tpv-check-api-ok');
        }

        $check['acciones'][] = $this->accion('enable-api', 'tpv-action-enable-api');
        if (null !== Tools::config('api_key')) {
            return $this->estado($check, self::AVISO, 'tpv-check-api-constant');
        }

        return $this->estado($check, self::ERROR, 'tpv-check-api-disabled');
    }

    public function checkEjercicio(): array
    {
        $check = $this->check('ejercicio', 'tpv-check-exercise');
        $ejercicio = $this->ejercicio();
        if (null === $ejercicio) {
            return $this->estado($check, self::ERROR, 'tpv-check-exercise-missing', ['%date%' => Tools::date()]);
        }
        if (false === $ejercicio->hasAccountingPlan()) {
            return $this->estado($check, self::ERROR, 'tpv-check-exercise-no-plan', ['%exercise%' => $ejercicio->nombre]);
        }

        return $this->estado($check, self::OK, 'tpv-check-exercise-ok', ['%exercise%' => $ejercicio->nombre]);
    }

    public function checkCuentas(): array
    {
        $check = $this->check('cuentas', 'tpv-check-accounts');
        $ejercicio = $this->ejercicio();
        $faltan = [];
        foreach ([self::CUENTA_CAJA, self::CUENTA_BANCO] as $prefijo) {
            $cuenta = $this->cuentaBanco($prefijo);
            if (null === $cuenta) {
                $faltan[] = $prefijo;
                $check['detalles'][] = Tools::trans('tpv-account-missing', ['%account%' => $prefijo]);
                continue;
            }

            $texto = $cuenta->codcuenta . ' · ' . $cuenta->descripcion . ' → ' . $cuenta->codsubcuenta;
            if (null !== $ejercicio && false === $cuenta->getSubcuenta($ejercicio->codejercicio, false)->exists()) {
                $faltan[] = $prefijo;
                $texto .= ' (' . Tools::trans('tpv-subaccount-missing', ['%exercise%' => $ejercicio->codejercicio]) . ')';
            }
            $check['detalles'][] = $texto;
        }

        if (empty($faltan)) {
            return $this->estado($check, self::OK, 'tpv-check-accounts-ok');
        }

        $check['acciones'][] = $this->accion('create-accounts', 'tpv-action-create-accounts');
        return $this->estado($check, self::ERROR, 'tpv-check-accounts-missing');
    }

    /**
     * Subcuentas que la app necesita para el asiento del cierre Z (570, 572, 700, 477, 659, 759).
     */
    public function checkSubcuentasCierre(): array
    {
        $check = $this->check('subcuentas', 'tpv-check-subaccounts');
        $ejercicio = $this->ejercicio();
        if (null === $ejercicio || false === $ejercicio->hasAccountingPlan()) {
            return $this->estado($check, self::ERROR, 'tpv-check-requires-exercise');
        }

        $faltan = $this->cuentasSinSubcuenta($ejercicio);
        if (empty($faltan)) {
            return $this->estado($check, self::OK, 'tpv-check-subaccounts-ok', ['%exercise%' => $ejercicio->codejercicio]);
        }

        $check['detalles'][] = implode(', ', $faltan);
        $check['acciones'][] = $this->accion('create-subaccounts', 'tpv-action-create-subaccounts');
        return $this->estado($check, self::ERROR, 'tpv-check-subaccounts-missing', ['%exercise%' => $ejercicio->codejercicio]);
    }

    public function checkFormaPago(string $codpago): array
    {
        $efectivo = $codpago === self::CODPAGO_EFECTIVO;
        $check = $this->check('pago-' . strtolower($codpago), $efectivo ? 'tpv-check-cash' : 'tpv-check-card');

        $forma = new FormaPago();
        if (false === $forma->load($codpago)) {
            $check['acciones'][] = $this->accion('create-payments', 'tpv-action-create-payments');
            return $this->estado($check, self::ERROR, 'tpv-check-payment-missing', ['%code%' => $codpago]);
        }

        $check['detalles'][] = $forma->codpago . ' · ' . $forma->descripcion;
        $diferencias = $this->diferenciasFormaPago($forma, $efectivo ? self::CUENTA_CAJA : self::CUENTA_BANCO);
        if (empty($diferencias)) {
            return $this->estado($check, self::OK, 'tpv-check-payment-ok', ['%code%' => $codpago]);
        }

        foreach ($diferencias as $diferencia) {
            $check['detalles'][] = $diferencia;
        }
        $check['acciones'][] = $this->accion('adjust-payments', 'tpv-action-adjust-payments', 'tpv-confirm-adjust-payments');
        return $this->estado($check, self::AVISO, 'tpv-check-payment-differs', ['%code%' => $codpago]);
    }

    public function checkCliente(): array
    {
        $check = $this->check('cliente', 'tpv-check-customer');
        $cliente = new Cliente();
        if (false === $cliente->load(self::CODCLIENTE)) {
            $check['acciones'][] = $this->accion('create-customer', 'tpv-action-create-customer');
            return $this->estado($check, self::ERROR, 'tpv-check-customer-missing', ['%code%' => self::CODCLIENTE]);
        }

        $check['detalles'][] = $cliente->codcliente . ' · ' . $cliente->nombre;
        $problemas = $this->problemasCliente($cliente);
        if (empty($problemas)) {
            return $this->estado($check, self::OK, 'tpv-check-customer-ok', ['%code%' => self::CODCLIENTE]);
        }

        foreach ($problemas as $problema) {
            $check['detalles'][] = $problema;
        }
        $check['acciones'][] = $this->accion('fix-customer', 'tpv-action-fix-customer', 'tpv-confirm-fix-customer');
        return $this->estado($check, self::AVISO, 'tpv-check-customer-differs', ['%code%' => self::CODCLIENTE]);
    }

    public function checkSerie(): array
    {
        $check = $this->check('serie', 'tpv-check-serie');
        $serie = new Serie();
        if (false === $serie->load(self::CODSERIE)) {
            $check['acciones'][] = $this->accion('create-serie', 'tpv-action-create-serie');
            return $this->estado($check, self::ERROR, 'tpv-check-serie-missing', ['%code%' => self::CODSERIE]);
        }

        $check['detalles'][] = $serie->codserie . ' · ' . $serie->descripcion;
        if ($serie->tipo === 'S') {
            return $this->estado($check, self::OK, 'tpv-check-serie-ok', ['%code%' => self::CODSERIE]);
        }

        $check['acciones'][] = $this->accion('fix-serie', 'tpv-action-fix-serie', 'tpv-confirm-fix-serie');
        return $this->estado($check, self::AVISO, 'tpv-check-serie-not-simplified', ['%code%' => self::CODSERIE]);
    }

    public function checkAlmacen(): array
    {
        $check = $this->check('almacen', 'tpv-check-warehouse');
        $codalmacen = (string)Tools::settings('default', 'codalmacen', '');
        $almacen = new Almacen();
        if ($codalmacen === '' || false === $almacen->load($codalmacen)) {
            return $this->estado($check, self::ERROR, 'tpv-check-warehouse-missing');
        }

        $check['detalles'][] = $almacen->codalmacen . ' · ' . $almacen->nombre;
        if (false === (bool)$almacen->activo) {
            return $this->estado($check, self::ERROR, 'tpv-check-warehouse-inactive', ['%code%' => $almacen->codalmacen]);
        }

        return $this->estado($check, self::OK, 'tpv-check-warehouse-ok', ['%code%' => $almacen->codalmacen]);
    }

    public function checkApiKey(): array
    {
        $check = $this->check('apikey', 'tpv-check-api-key', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
        $clave = $this->apiKey();
        if (null === $clave) {
            $check['acciones'][] = $this->accion('create-api-key', 'tpv-action-create-api-key');
            return $this->estado($check, self::ERROR, 'tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
        }

        $check['clave'] = $clave->apikey;

        // una clave desactivada se activa con su propia acción: pudo desactivarse por seguridad
        if (false === (bool)$clave->enabled) {
            $check['acciones'][] = $this->accion('enable-api-key', 'tpv-action-enable-api-key', 'tpv-confirm-enable-api-key');
            $check['acciones'][] = $this->accion('regenerate-api-key', 'tpv-action-regenerate-api-key', 'tpv-confirm-regenerate-api-key', 'outline-danger');
            return $this->estado($check, self::ERROR, 'tpv-check-api-key-disabled');
        }

        $check['acciones'][] = $this->accion('regenerate-api-key', 'tpv-action-regenerate-api-key', 'tpv-confirm-regenerate-api-key', 'outline-danger', true);

        $problemas = [];
        if ((bool)$clave->fullaccess) {
            $problemas[] = Tools::trans('tpv-api-key-full-access');
        }

        $diferencias = [];
        $perfil = $this->perfilClave($clave, $diferencias);
        if (!empty($problemas) || null === $perfil) {
            foreach (array_merge($problemas, $diferencias) as $problema) {
                $check['detalles'][] = $problema;
            }
            $check['acciones'][] = $this->accion('fix-api-key', 'tpv-action-fix-api-key', 'tpv-confirm-fix-api-key');
            return $this->estado($check, self::AVISO, 'tpv-check-api-key-differs');
        }

        if ($perfil === TpvApiPermisos::PERFIL_PRUEBAS) {
            $check['acciones'][] = $this->accion('fix-api-key', 'tpv-action-api-key-production', 'tpv-confirm-fix-api-key');
            return $this->estado($check, self::AVISO, 'tpv-check-api-key-test-profile');
        }

        // el perfil de pruebas (permite borrar) solo lo necesitan las pruebas de integración de la app
        $check['acciones'][] = $this->accion('api-key-test-profile', 'tpv-action-api-key-test-profile', 'tpv-confirm-api-key-test-profile', 'outline-secondary', true);
        return $this->estado($check, self::OK, 'tpv-check-api-key-ok', ['%count%' => count(TpvApiPermisos::PRODUCCION)]);
    }

    public function checkTablas(): array
    {
        $check = $this->check('tablas', 'tpv-check-tables');
        $db = $this->db();
        $faltan = [];
        foreach (TpvSchema::TABLES as $tabla) {
            if (false === $db->tableExists($tabla)) {
                $faltan[] = $tabla;
            }
        }
        if (false === $this->tieneColumnaDestino()) {
            $faltan[] = 'familias.tpv_destino';
        }

        if (!empty($faltan)) {
            $check['detalles'][] = implode(', ', $faltan);
            $check['acciones'][] = $this->accion('create-tables', 'tpv-action-create-tables');
            return $this->estado($check, self::ERROR, 'tpv-check-tables-missing');
        }

        // la idempotencia de la app depende de los índices únicos
        $sinIndice = TpvSchema::indicesUnicosQueFaltan();
        if (!empty($sinIndice)) {
            $check['detalles'][] = implode(', ', $sinIndice);
            return $this->estado($check, self::ERROR, 'tpv-check-tables-unique-missing');
        }

        if (false === (bool)Tools::config('db_foreign_keys', true)) {
            $huerfanas = TpvSchema::lineasHuerfanas();
            if ($huerfanas > 0) {
                $check['detalles'][] = Tools::trans('tpv-orphan-recipe-lines', ['%count%' => $huerfanas]);
            }
            return $this->estado($check, self::AVISO, 'tpv-check-tables-no-foreign-keys');
        }

        return $this->estado($check, self::OK, 'tpv-check-tables-ok');
    }

    /**
     * Rol Hosteleria con todas las páginas del plugin (Init::update() solo se ejecuta al activar
     * el plugin: al actualizarlo copiando ficheros, las páginas nuevas no llegan al rol).
     */
    public function checkRol(): array
    {
        $check = $this->check('rol', 'tpv-check-role');
        $faltan = TpvRol::paginasQueFaltan();
        if (empty($faltan)) {
            return $this->estado($check, self::OK, 'tpv-check-role-ok', ['%role%' => TpvRol::ROLE_NAME]);
        }

        $check['detalles'][] = implode(', ', $faltan);
        $check['acciones'][] = $this->accion('fix-role', 'tpv-action-fix-role');
        return $this->estado($check, self::AVISO, 'tpv-check-role-missing', ['%role%' => TpvRol::ROLE_NAME]);
    }

    /**
     * El grafo de recetas tiene que ser válido para el motor de la app: un ciclo o una cadena de
     * más de 20 platos con receta hacen que no descuente stock de NINGUNA venta. Además, las referencias
     * deben estar escritas exactamente como en variantes (el motor distingue mayúsculas).
     */
    public function checkRecetas(): array
    {
        $check = $this->check('recetas', 'tpv-check-recipes');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $errores = TpvGrafoRecetas::cargar()->errores(self::MAX_DETALLES);
        foreach ($errores as $error) {
            $clave = $error['tipo'] === 'ciclo' ? 'tpv-recipe-graph-cycle' : 'tpv-recipe-graph-too-deep';
            $check['detalles'][] = Tools::trans($clave, [
                '%path%' => implode(' → ', $error['camino']),
                '%max%' => TpvGrafoRecetas::MAX_PROFUNDIDAD,
            ]);
        }

        $noCanonicas = $this->referenciasNoCanonicas();
        foreach (array_slice($noCanonicas, 0, self::MAX_DETALLES) as $row) {
            $check['detalles'][] = Tools::trans('tpv-recipe-non-canonical', [
                '%found%' => $row['guardada'],
                '%expected%' => $row['referencia'],
            ]);
        }
        if (!empty($noCanonicas)) {
            $check['acciones'][] = $this->accion('fix-recipe-refs', 'tpv-action-fix-recipe-refs', 'tpv-confirm-fix-recipe-refs');
        }

        if (!empty($errores)) {
            return $this->estado($check, self::ERROR, 'tpv-check-recipes-invalid');
        }
        if (!empty($noCanonicas)) {
            return $this->estado($check, self::AVISO, 'tpv-check-recipes-non-canonical', ['%count%' => count($noCanonicas)]);
        }

        return $this->estado($check, self::OK, 'tpv-check-recipes-ok', ['%count%' => $this->contarPlatosConReceta()]);
    }

    public function checkPlatos(): array
    {
        $check = $this->check('platos', 'tpv-check-dishes');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $platos = $this->platosConStock();
        if (empty($platos)) {
            $total = $this->contarPlatosConReceta();
            return $this->estado($check, self::OK, $total > 0 ? 'tpv-check-dishes-ok' : 'tpv-check-dishes-none', ['%count%' => $total]);
        }

        $this->detallesProductos($check, $platos);
        $check['acciones'][] = $this->accion('fix-dishes', 'tpv-action-fix-dishes', 'tpv-confirm-fix-dishes');
        return $this->estado($check, self::AVISO, 'tpv-check-dishes-with-stock', ['%count%' => count($platos)]);
    }

    public function checkMateriasPrimas(): array
    {
        $check = $this->check('materias', 'tpv-check-ingredients');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $materias = $this->materiasSinStock();
        if (empty($materias)) {
            $total = $this->contarMateriasPrimas();
            return $this->estado($check, self::OK, $total > 0 ? 'tpv-check-ingredients-ok' : 'tpv-check-ingredients-none', ['%count%' => $total]);
        }

        $this->detallesProductos($check, $materias);
        $check['acciones'][] = $this->accion('fix-ingredients', 'tpv-action-fix-ingredients', 'tpv-confirm-fix-ingredients');
        return $this->estado($check, self::AVISO, 'tpv-check-ingredients-without-stock', ['%count%' => count($materias)]);
    }

    /**
     * Productos con una variante que es plato (con receta) y otra que es materia prima: «no
     * controlar stock» es del producto, así que no hay valor correcto para los dos papeles.
     */
    public function checkProductosMixtos(): array
    {
        $check = $this->check('mixtos', 'tpv-check-mixed-products');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $mixtos = $this->productosMixtos();
        if (empty($mixtos)) {
            return $this->estado($check, self::OK, 'tpv-check-mixed-products-ok');
        }

        $this->detallesProductos($check, $mixtos);
        return $this->estado($check, self::AVISO, 'tpv-check-mixed-products-found', ['%count%' => count($mixtos)]);
    }

    /**
     * Productos de la carta con control de stock que no permiten vender sin stock: si su stock en
     * FacturaScripts se queda corto, crearFacturaCliente falla y, como la cola de facturas de la
     * app es FIFO estricta, ningún ticket posterior se factura hasta resolverlo.
     */
    public function checkVentaSinStock(): array
    {
        $check = $this->check('ventasinstock', 'tpv-check-sale-without-stock');
        $productos = $this->productosSinVentaSinStock();
        if (false === (bool)Tools::settings('default', 'ventasinstock', true)) {
            $check['detalles'][] = Tools::trans('tpv-default-no-sale-without-stock');
        }
        if (empty($productos)) {
            return $this->estado($check, self::OK, 'tpv-check-sale-without-stock-ok');
        }

        $this->detallesProductos($check, $productos);
        $check['acciones'][] = $this->accion('fix-sale-without-stock', 'tpv-action-fix-sale-without-stock', 'tpv-confirm-fix-sale-without-stock');
        return $this->estado($check, self::AVISO, 'tpv-check-sale-without-stock-found', ['%count%' => count($productos)]);
    }

    /**
     * Costes: materias primas de receta sin coste (el coste teórico sale por debajo del real) y
     * platos cuyo coste en ficha no coincide con el teórico (FS lo usa como coste de cada venta).
     */
    public function checkCostes(): array
    {
        $check = $this->check('costes', 'tpv-check-costs');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $sinCoste = $this->materiasSinCoste();
        foreach (array_slice($sinCoste, 0, self::MAX_DETALLES) as $row) {
            $check['detalles'][] = Tools::trans('tpv-ingredient-no-cost', ['%ref%' => $row['referencia'], '%name%' => $row['descripcion']]);
        }
        if (count($sinCoste) > self::MAX_DETALLES) {
            $check['detalles'][] = Tools::trans('tpv-and-more', ['%count%' => count($sinCoste) - self::MAX_DETALLES]);
        }

        $distintos = $this->platosConCosteDistinto();
        foreach (array_slice($distintos, 0, self::MAX_DETALLES) as $item) {
            $check['detalles'][] = Tools::trans('tpv-dish-cost-differs', [
                '%ref%' => $item['referencia'],
                '%cost%' => Tools::money($item['coste'], '', 4),
                '%current%' => Tools::money($item['coste_ficha'], '', 4),
            ]);
        }
        if (count($distintos) > self::MAX_DETALLES) {
            $check['detalles'][] = Tools::trans('tpv-and-more', ['%count%' => count($distintos) - self::MAX_DETALLES]);
        }
        if (!empty($distintos)) {
            $check['acciones'][] = $this->accion('copy-costs', 'tpv-action-copy-costs', 'tpv-confirm-copy-costs');
        }

        // con margen en la variante no se copia el coste (FS recalcularía su precio): solo se informa
        foreach ($this->platosConCosteDistinto(true) as $item) {
            if ($item['margen'] > 0) {
                $check['detalles'][] = Tools::trans('tpv-dish-cost-differs-margin', [
                    '%ref%' => $item['referencia'],
                    '%cost%' => Tools::money($item['coste'], '', 4),
                    '%current%' => Tools::money($item['coste_ficha'], '', 4),
                    '%margin%' => Tools::number($item['margen']),
                ]);
            }
        }

        if (empty(Tools::settings('default', 'costpricepolicy', ''))) {
            $check['detalles'][] = Tools::trans('tpv-no-cost-price-policy');
        }

        if (empty($sinCoste) && empty($distintos)) {
            return $this->estado($check, self::OK, 'tpv-check-costs-ok');
        }

        return $this->estado($check, self::AVISO, 'tpv-check-costs-differs', [
            '%without%' => count($sinCoste),
            '%differs%' => count($distintos),
        ]);
    }

    /**
     * Lo que necesita la reposición automática de la app: stock mínimo en las materias primas
     * (solo repone referencias con stockmin > 0), un proveedor activo, mínimos y máximos no
     * negativos (uno negativo invalida toda la auditoría) y pedidos que no se quedan sin recibir
     * (su cantidad pendiente frena las reposiciones siguientes).
     */
    /**
     * Stock de cocina y barra (Hostelería › Stock). Avisa de las referencias que salen en las dos
     * pestañas (las usan platos de cocina y de barra y su familia no tiene destino): lo decide el
     * usuario poniéndolas en una familia con destino o creando un producto para cada sitio. Informa,
     * sin avisar, de las que son de un sitio por su familia pero usan platos del otro (una receta
     * con el producto del otro sitio, o asignadas así a propósito), de las que usan platos sin
     * destino en el ERP y de las que no son de ninguno.
     */
    public function checkStockDestinos(): array
    {
        $check = $this->check('stock', 'tpv-check-stock-stations');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS) || false === $this->tieneColumnaDestino()) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $compartidas = [];
        $cruces = [];
        $sinDestinoErp = [];
        $sinDestino = [];
        foreach (TpvStockDestino::clasificar() as $item) {
            $ref = $item['referencia'];
            if (count($item['destinos']) > 1) {
                $compartidas[$ref] = $ref . ' (' . $this->textoUsos($item['usos']) . ')';
            } elseif (empty($item['destinos'])) {
                $sinDestino[$ref] = $ref;
            }

            $otros = $item['por_familia'] ? array_diff_key($item['usos'], array_flip($item['destinos'])) : [];
            if (!empty($otros)) {
                $cruces[$ref] = $ref . ' (' . $this->textoDestino($item['destinos'][0]) . '; ' . $this->textoUsos($otros) . ')';
            }
            if (!empty($item['platos_sin_destino'])) {
                $sinDestinoErp[$ref] = $ref . ' (' . $this->textoPlatos($item['platos_sin_destino']) . ')';
            }
        }
        $detalles = [
            'tpv-stock-shared' => $compartidas,
            'tpv-stock-cross' => $cruces,
            'tpv-stock-no-erp-destination' => $sinDestinoErp,
            'tpv-stock-unassigned' => $sinDestino,
        ];
        foreach ($detalles as $mensaje => $lista) {
            if (!empty($lista)) {
                ksort($lista, SORT_STRING);
                $check['detalles'][] = Tools::trans($mensaje, ['%refs%' => $this->listaCorta(array_values($lista))]);
            }
        }

        return empty($compartidas) ?
            $this->estado($check, self::OK, 'tpv-check-stock-stations-ok') :
            $this->estado($check, self::AVISO, 'tpv-check-stock-stations-review');
    }

    public function checkReposicion(): array
    {
        $check = $this->check('reposicion', 'tpv-check-restock');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        $codalmacen = (string)Tools::settings('default', 'codalmacen', '');
        $negativos = $this->stocksNegativos($codalmacen);
        $sinMinimo = $this->materiasSinMinimo($codalmacen);
        $sinProveedor = $this->materiasSinProveedor($codalmacen);
        $pedidos = $this->pedidosReposicionAbiertos();

        foreach (array_slice($negativos, 0, self::MAX_DETALLES) as $row) {
            $check['detalles'][] = Tools::trans('tpv-restock-negative', ['%ref%' => $row['referencia']]);
        }
        if (!empty($sinMinimo)) {
            $check['detalles'][] = Tools::trans('tpv-restock-without-minimum', [
                '%count%' => count($sinMinimo),
                '%refs%' => $this->listaCorta(array_column($sinMinimo, 'referencia')),
            ]);
        }
        if (!empty($sinProveedor)) {
            $check['detalles'][] = Tools::trans('tpv-restock-without-supplier', [
                '%count%' => count($sinProveedor),
                '%refs%' => $this->listaCorta(array_column($sinProveedor, 'referencia')),
            ]);
        }
        if (!empty($pedidos)) {
            $check['detalles'][] = Tools::trans('tpv-restock-open-orders', [
                '%count%' => count($pedidos),
                '%days%' => self::DIAS_PEDIDO_ABIERTO,
                '%codes%' => $this->listaCorta(array_column($pedidos, 'codigo')),
            ]);
        }

        if (!empty($negativos)) {
            return $this->estado($check, self::ERROR, 'tpv-check-restock-negative');
        }
        if (!empty($sinMinimo) || !empty($pedidos)) {
            return $this->estado($check, self::AVISO, 'tpv-check-restock-differs');
        }

        return $this->estado($check, self::OK, 'tpv-check-restock-ok');
    }

    /**
     * La carta: platos que se venden con «no controlar stock» y sin receta (no descuentan nada en
     * ningún sitio) y familias de productos vendibles sin destino de impresión (van al destino
     * por defecto del TPV).
     */
    public function checkCarta(): array
    {
        $check = $this->check('carta', 'tpv-check-menu');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::AVISO, 'tpv-check-requires-tables');
        }

        // puede ser intencionado (pan, servicio de mesa...): se informa sin dejar la comprobación en aviso
        $sinReceta = $this->platosSinReceta();
        if (!empty($sinReceta)) {
            $check['detalles'][] = Tools::trans('tpv-menu-without-recipe', [
                '%count%' => count($sinReceta),
                '%refs%' => $this->listaCorta(array_column($sinReceta, 'referencia')),
            ]);
        }

        $sinDestino = $this->familiasSinDestino();
        if (!empty($sinDestino)) {
            $check['detalles'][] = Tools::trans('tpv-menu-families-without-destination', [
                '%count%' => count($sinDestino),
                '%codes%' => $this->listaCorta($sinDestino),
            ]);
            return $this->estado($check, self::AVISO, 'tpv-check-menu-review');
        }

        return $this->estado($check, self::OK, 'tpv-check-menu-ok');
    }

    /**
     * Claves idempotentes de la app repetidas en FacturaScripts: la app se detiene («Clave
     * duplicada... resolverlo a mano») y, en el caso de las facturas, bloquea la cola entera.
     */
    public function checkClavesDuplicadas(): array
    {
        $check = $this->check('claves', 'tpv-check-duplicated-keys');
        $consultas = [
            'tpv-duplicated-invoice' => 'SELECT numero2 AS clave, COUNT(*) AS n FROM facturascli'
                . " WHERE numero2 LIKE 'TPV-%' AND idfacturarect IS NULL GROUP BY numero2 HAVING COUNT(*) > 1",
            'tpv-duplicated-order' => 'SELECT numproveedor AS clave, COUNT(*) AS n FROM pedidosprov'
                . " WHERE numproveedor LIKE 'TPV-REPO-%' GROUP BY numproveedor HAVING COUNT(*) > 1",
            'tpv-duplicated-entry' => 'SELECT documento AS clave, COUNT(*) AS n FROM asientos'
                . " WHERE documento LIKE 'Z-%' GROUP BY documento HAVING COUNT(*) > 1",
        ];

        $db = $this->db();
        $total = 0;
        foreach ($consultas as $mensaje => $sql) {
            foreach ($db->selectLimit($sql, self::MAX_DETALLES) as $row) {
                $check['detalles'][] = Tools::trans($mensaje, ['%key%' => $row['clave'], '%count%' => $row['n']]);
                $total++;
            }
        }

        // rectificativas hechas antes de la 1.1 (o sin el plugin) con la clave de su ticket: la app
        // las encontraría si tuviera que reanudar ese ticket y se detendría
        $rectificativas = $this->rectificativasConClaveDeTicket();
        if ($rectificativas > 0) {
            $check['detalles'][] = Tools::trans('tpv-refunds-with-ticket-key', ['%count%' => $rectificativas]);
            $check['acciones'][] = $this->accion('fix-refund-keys', 'tpv-action-fix-refund-keys', 'tpv-confirm-fix-refund-keys');
        }

        if ($total > 0) {
            return $this->estado($check, self::ERROR, 'tpv-check-duplicated-keys-found');
        }
        if ($rectificativas > 0) {
            return $this->estado($check, self::AVISO, 'tpv-check-refund-keys');
        }

        return $this->estado($check, self::OK, 'tpv-check-duplicated-keys-ok');
    }

    // -----------------------------------------------------------------------------------------
    // Acciones

    /**
     * Ejecuta una acción del asistente. Devuelve true si terminó bien (o no había nada que hacer).
     * Los detalles quedan en el log de FacturaScripts (se muestran en la página).
     */
    public function ejecutar(string $accion, bool $confirmado = false, string $nick = ''): bool
    {
        if (in_array($accion, self::ACCIONES_CON_CONFIRMACION, true) && false === $confirmado) {
            Tools::log()->warning('tpv-action-needs-confirmation');
            return false;
        }

        switch ($accion) {
            case 'enable-api':
                return $this->accionActivarApi();

            case 'create-accounts':
                return $this->accionCrearCuentas();

            case 'create-subaccounts':
                return $this->accionCrearSubcuentas();

            case 'create-payments':
                return $this->accionCrearFormasPago();

            case 'adjust-payments':
                return $this->accionAjustarFormasPago();

            case 'create-customer':
                return $this->accionCrearCliente();

            case 'fix-customer':
                return $this->accionCorregirCliente();

            case 'create-serie':
                return $this->accionCrearSerie();

            case 'fix-serie':
                return $this->accionCorregirSerie();

            case 'create-api-key':
                return $this->accionCrearClave($nick);

            case 'fix-api-key':
                return $this->accionPermisosClave(TpvApiPermisos::PERFIL_PRODUCCION);

            case 'api-key-test-profile':
                return $this->accionPermisosClave(TpvApiPermisos::PERFIL_PRUEBAS);

            case 'enable-api-key':
                return $this->accionActivarClave();

            case 'regenerate-api-key':
                return $this->accionRegenerarClave();

            case 'create-tables':
                return $this->accionCrearTablas();

            case 'fix-role':
                return TpvRol::crear();

            case 'fix-recipe-refs':
                return $this->accionNormalizarReferencias();

            case 'fix-dishes':
                return $this->accionMarcarProductos($this->platosConStock(), 'nostock', true);

            case 'fix-ingredients':
                return $this->accionMarcarProductos($this->materiasSinStock(), 'nostock', false);

            case 'fix-sale-without-stock':
                return $this->accionMarcarProductos($this->productosSinVentaSinStock(), 'ventasinstock', true);

            case 'copy-costs':
                TpvRecetas::copiarCosteTeorico(array_column($this->platosConCosteDistinto(), 'referencia'));
                return true;

            case 'fix-refund-keys':
                return $this->accionCorregirClavesRectificativas();

            case 'setup-all':
                return $this->accionConfigurarTodo($nick);
        }

        Tools::log()->warning('tpv-unknown-action', ['%action%' => $accion]);
        return false;
    }

    /**
     * Crea todo lo que FALTA (no modifica nada existente): API, tablas, cuentas, subcuentas,
     * formas de pago, serie, cliente, clave de API y rol.
     */
    private function accionConfigurarTodo(string $nick): bool
    {
        $ok = true;
        if (false === (bool)Tools::settings('default', 'enable_api', false)) {
            $ok = $this->accionActivarApi() && $ok;
        }
        $ok = $this->accionCrearTablas() && $ok;
        $ok = $this->accionCrearCuentas() && $ok;
        $ok = $this->accionCrearSubcuentas() && $ok;
        $ok = $this->accionCrearFormasPago() && $ok;
        $ok = $this->accionCrearSerie() && $ok;
        $ok = $this->accionCrearCliente() && $ok;
        if (null === $this->apiKey()) {
            $ok = $this->accionCrearClave($nick) && $ok;
        }
        $ok = TpvRol::crear() && $ok;

        return $ok;
    }

    private function accionActivarApi(): bool
    {
        if ((bool)Tools::settings('default', 'enable_api', false)) {
            return true;
        }

        Tools::settingsSet('default', 'enable_api', true);
        if (false === Tools::settingsSave()) {
            Tools::settingsClear();
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::settingsClear();
        Tools::log()->notice('tpv-api-enabled');
        return true;
    }

    private function accionActivarClave(): bool
    {
        $clave = $this->apiKey();
        if (null === $clave) {
            Tools::log()->warning('tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
            return false;
        }
        if ((bool)$clave->enabled) {
            return true;
        }

        $clave->enabled = true;
        if (false === $clave->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-api-key-enabled');
        return true;
    }

    private function accionCrearCuentas(): bool
    {
        $ejercicio = $this->ejercicio();
        if (null === $ejercicio) {
            Tools::log()->error('tpv-check-exercise-missing', ['%date%' => Tools::date()]);
            return false;
        }
        if (false === $ejercicio->hasAccountingPlan()) {
            Tools::log()->error('tpv-check-exercise-no-plan', ['%exercise%' => $ejercicio->nombre]);
            return false;
        }

        $ok = true;
        $nombres = [self::CUENTA_CAJA => 'Caja', self::CUENTA_BANCO => 'Banco TPV'];
        foreach ($nombres as $prefijo => $descripcion) {
            $cuenta = $this->cuentaBanco($prefijo);
            if (null !== $cuenta) {
                // existe: solo nos aseguramos de que su subcuenta exista en el ejercicio vigente,
                // colgando de la cuenta de su prefijo (CuentaBanco::getSubcuenta(..., true) la
                // colgaría de la cuenta especial BANCO, también la de la caja)
                if (false === $cuenta->getSubcuenta($ejercicio->codejercicio, false)->exists()) {
                    $subcuenta = $this->crearSubcuentaExacta($ejercicio, (string)$cuenta->codsubcuenta, (string)$cuenta->descripcion);
                    if (null !== $subcuenta) {
                        Tools::log()->notice('tpv-subaccount-created', ['%code%' => $subcuenta->codsubcuenta]);
                    } else {
                        Tools::log()->error('tpv-subaccount-create-error', ['%code%' => $cuenta->codsubcuenta]);
                        $ok = false;
                    }
                }
                continue;
            }

            $subcuenta = $this->subcuentaParaCuenta($ejercicio, $prefijo, $descripcion);
            if (null === $subcuenta) {
                Tools::log()->error('tpv-subaccount-create-error', ['%code%' => $prefijo]);
                $ok = false;
                continue;
            }

            $nueva = new CuentaBanco();
            $nueva->descripcion = $descripcion;
            $nueva->codsubcuenta = $subcuenta->codsubcuenta;
            $nueva->idempresa = $ejercicio->idempresa;
            $nueva->activa = true;
            if (false === $nueva->save()) {
                Tools::log()->error('record-save-error');
                $ok = false;
                continue;
            }

            Tools::log()->notice('tpv-account-created', [
                '%code%' => $nueva->codcuenta,
                '%name%' => $descripcion,
                '%subaccount%' => $nueva->codsubcuenta,
            ]);
        }

        return $ok;
    }

    /**
     * Crea la primera subcuenta de cada cuenta del cierre Z que no tenga ninguna en el ejercicio
     * (la cuenta tiene que existir en el plan contable).
     */
    private function accionCrearSubcuentas(): bool
    {
        $ejercicio = $this->ejercicio();
        if (null === $ejercicio || false === $ejercicio->hasAccountingPlan()) {
            Tools::log()->error('tpv-check-requires-exercise');
            return false;
        }

        $ok = true;
        foreach ($this->cuentasSinSubcuenta($ejercicio) as $codcuenta) {
            $cuenta = new Cuenta();
            $where = [Where::eq('codejercicio', $ejercicio->codejercicio), Where::eq('codcuenta', $codcuenta)];
            $descripcion = $cuenta->loadWhere($where) ? (string)$cuenta->descripcion : $codcuenta;
            $subcuenta = $this->subcuentaParaCuenta($ejercicio, $codcuenta, $descripcion);
            if (null === $subcuenta) {
                Tools::log()->error('tpv-subaccount-create-error', ['%code%' => $codcuenta]);
                $ok = false;
                continue;
            }
            Tools::log()->notice('tpv-subaccount-created', ['%code%' => $subcuenta->codsubcuenta]);
        }

        return $ok;
    }

    private function accionCrearFormasPago(): bool
    {
        $definiciones = [
            self::CODPAGO_EFECTIVO => ['Efectivo TPV', self::CUENTA_CAJA],
            self::CODPAGO_TARJETA => ['Tarjeta TPV', self::CUENTA_BANCO],
        ];

        $ok = true;
        foreach ($definiciones as $codpago => [$descripcion, $prefijo]) {
            $forma = new FormaPago();
            if ($forma->load($codpago)) {
                continue; // existe: no se pisa (ver "Ajustar")
            }

            $cuenta = $this->cuentaBanco($prefijo);
            if (null === $cuenta) {
                $this->accionCrearCuentas();
                $cuenta = $this->cuentaBanco($prefijo);
            }
            if (null === $cuenta) {
                Tools::log()->error('tpv-account-missing', ['%account%' => $prefijo]);
                $ok = false;
                continue;
            }

            $forma->codpago = $codpago;
            $forma->descripcion = $descripcion;
            $forma->codcuentabanco = $cuenta->codcuenta;
            $forma->pagado = true;
            $forma->plazovencimiento = 0;
            $forma->tipovencimiento = 'days';
            $forma->domiciliado = false;
            $forma->activa = true;
            $forma->imprimir = true;
            if (false === $forma->save()) {
                Tools::log()->error('record-save-error');
                $ok = false;
                continue;
            }

            Tools::log()->notice('tpv-payment-created', ['%code%' => $codpago, '%account%' => $cuenta->codsubcuenta]);
        }

        return $ok;
    }

    private function accionAjustarFormasPago(): bool
    {
        $ok = true;
        foreach ([self::CODPAGO_EFECTIVO => self::CUENTA_CAJA, self::CODPAGO_TARJETA => self::CUENTA_BANCO] as $codpago => $prefijo) {
            $forma = new FormaPago();
            if (false === $forma->load($codpago)) {
                continue;
            }
            if (empty($this->diferenciasFormaPago($forma, $prefijo))) {
                continue;
            }

            $cuenta = $this->cuentaBancoDeForma($forma, $prefijo) ?? $this->cuentaBanco($prefijo);
            if (null === $cuenta) {
                $this->accionCrearCuentas();
                $cuenta = $this->cuentaBanco($prefijo);
            }
            if (null === $cuenta) {
                Tools::log()->error('tpv-account-missing', ['%account%' => $prefijo]);
                $ok = false;
                continue;
            }

            $forma->codcuentabanco = $cuenta->codcuenta;
            $forma->pagado = true;
            $forma->plazovencimiento = 0;
            $forma->tipovencimiento = 'days';
            $forma->activa = true;
            if (false === $forma->save()) {
                Tools::log()->error('record-save-error');
                $ok = false;
                continue;
            }

            Tools::log()->notice('tpv-payment-adjusted', ['%code%' => $codpago, '%account%' => $cuenta->codsubcuenta]);
        }

        return $ok;
    }

    private function accionCrearCliente(): bool
    {
        $cliente = new Cliente();
        if ($cliente->load(self::CODCLIENTE)) {
            return true;
        }

        $cliente->codcliente = self::CODCLIENTE;
        $cliente->nombre = self::NOMBRE_CLIENTE;
        $cliente->razonsocial = self::NOMBRE_CLIENTE;
        $cliente->cifnif = '';
        $cliente->personafisica = true;
        $cliente->riesgomax = null;
        $cliente->observaciones = Tools::trans('tpv-customer-notes');
        if ((new Serie())->load(self::CODSERIE)) {
            $cliente->codserie = self::CODSERIE;
        }
        if ((new FormaPago())->load(self::CODPAGO_EFECTIVO)) {
            $cliente->codpago = self::CODPAGO_EFECTIVO;
        }
        if (false === $cliente->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-customer-created', ['%code%' => self::CODCLIENTE]);
        return true;
    }

    private function accionCorregirCliente(): bool
    {
        $cliente = new Cliente();
        if (false === $cliente->load(self::CODCLIENTE)) {
            return $this->accionCrearCliente();
        }
        if (empty($this->problemasCliente($cliente))) {
            return true;
        }

        $cliente->riesgomax = null;
        $cliente->fechabaja = null;
        $cliente->debaja = false;
        if (false === $cliente->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-customer-fixed', ['%code%' => self::CODCLIENTE]);
        return true;
    }

    private function accionCrearSerie(): bool
    {
        $serie = new Serie();
        if ($serie->load(self::CODSERIE)) {
            return true;
        }

        $serie->codserie = self::CODSERIE;
        $serie->descripcion = 'Simplificadas';
        $serie->tipo = 'S';
        $serie->siniva = false;
        if (false === $serie->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-serie-created', ['%code%' => self::CODSERIE]);
        return true;
    }

    private function accionCorregirSerie(): bool
    {
        $serie = new Serie();
        if (false === $serie->load(self::CODSERIE)) {
            return $this->accionCrearSerie();
        }
        if ($serie->tipo === 'S') {
            return true;
        }

        $serie->tipo = 'S';
        if (false === $serie->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-serie-fixed', ['%code%' => self::CODSERIE]);
        return true;
    }

    private function accionCrearClave(string $nick): bool
    {
        if (null !== $this->apiKey()) {
            return true;
        }

        // la clave y sus permisos, todo o nada: una clave sin permisos daría 403 en cada llamada
        $db = $this->db();
        $db->beginTransaction();

        $clave = new ApiKey();
        $clave->apikey = self::nuevaClave();
        $clave->description = TpvApiPermisos::DESCRIPCION_CLAVE;
        $clave->nick = $nick === '' ? null : $nick;
        $clave->enabled = true;
        $clave->fullaccess = false;
        if (false === $clave->save() || false === $this->aplicarPerfil($clave, TpvApiPermisos::PERFIL_PRODUCCION)) {
            $db->rollback();
            Tools::log()->error('record-save-error');
            return false;
        }

        $db->commit();
        Tools::log()->notice('tpv-api-key-created', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
        return true;
    }

    /**
     * Deja en la clave exactamente los permisos del perfil y le quita el acceso total. No cambia
     * si está activa o no (una clave desactivada pudo desactivarse por seguridad).
     */
    private function accionPermisosClave(string $perfil): bool
    {
        $clave = $this->apiKey();
        if (null === $clave) {
            Tools::log()->warning('tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
            return false;
        }

        $db = $this->db();
        $db->beginTransaction();
        $clave->fullaccess = false;
        if (false === $clave->save() || false === $this->aplicarPerfil($clave, $perfil)) {
            $db->rollback();
            Tools::log()->error('record-save-error');
            return false;
        }

        $db->commit();
        Tools::log()->notice($perfil === TpvApiPermisos::PERFIL_PRUEBAS ? 'tpv-api-key-test-profile' : 'tpv-api-key-production');
        return true;
    }

    private function accionRegenerarClave(): bool
    {
        $clave = $this->apiKey();
        if (null === $clave) {
            Tools::log()->warning('tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
            return false;
        }

        $clave->apikey = self::nuevaClave();
        if (false === $clave->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->warning('tpv-api-key-regenerated');
        return true;
    }

    private function accionCrearTablas(): bool
    {
        $db = $this->db();
        $faltaba = false === $this->tieneColumnaDestino();
        foreach (TpvSchema::TABLES as $tabla) {
            $faltaba = $faltaba || false === $db->tableExists($tabla);
        }
        if (false === $faltaba) {
            return true;
        }

        $ok = TpvSchema::ensureAll();
        if (false === $this->tieneColumnaDestino()) {
            // la columna la añade el DbUpdater con Extension/Table/familias.xml: forzamos la revisión
            // y vaciamos la caché, que guarda la lista de campos del modelo (sin tpv_destino, el
            // destino ni se guardaría ni saldría en la API hasta que caducase)
            DbUpdater::rebuild();
            Cache::clear();
            new Familia();
            $ok = $this->tieneColumnaDestino() && $ok;
        }

        if ($ok) {
            Tools::log()->notice('tpv-check-tables-ok');
        }
        return $ok;
    }

    /**
     * @param array[] $filas filas con idproducto
     */
    private function accionMarcarProductos(array $filas, string $campo, bool $valor): bool
    {
        $ok = true;
        $cambiados = 0;
        $db = $this->db();
        foreach ($filas as $row) {
            $producto = new Producto();
            if (false === $producto->load($row['idproducto'])) {
                continue;
            }
            if ((bool)$producto->{$campo} === $valor) {
                continue;
            }

            // al marcar «no controlar stock» el producto borra su stock con SQL directo en test():
            // la transacción lo deshace si después el guardado falla
            $db->beginTransaction();
            $producto->{$campo} = $valor;
            if (false === $producto->save()) {
                $db->rollback();
                Tools::log()->error('record-save-error');
                $ok = false;
                continue;
            }
            $db->commit();
            $cambiados++;
        }

        Tools::log()->notice('tpv-products-updated', ['%count%' => $cambiados]);
        return $ok;
    }

    /**
     * Antepone una «R» al numero2 'TPV-...' de las rectificativas anteriores a la extensión
     * Extension/Model/FacturaCliente (la misma regla), para que la clave del ticket sea única.
     * Solo cambia numero2, un campo libre: no toca importes, numeración ni asientos.
     */
    private function accionCorregirClavesRectificativas(): bool
    {
        $db = $this->db();
        $sql = "UPDATE facturascli SET numero2 = SUBSTRING(CONCAT('R', numero2), 1, 50)"
            . " WHERE idfacturarect IS NOT NULL AND numero2 LIKE 'TPV-%';";
        if (false === $db->exec($sql)) {
            Tools::log()->error('record-save-error');
            return false;
        }

        (new FacturaCliente())->clearCache();
        Tools::log()->notice('tpv-refund-keys-fixed');
        return true;
    }

    /**
     * Escribe cada referencia de las recetas tal como está en variantes (el motor de la app
     * distingue mayúsculas; MySQL no).
     */
    private function accionNormalizarReferencias(): bool
    {
        $db = $this->db();
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $ok = true;
        foreach (['ref_plato', 'ref_ingrediente'] as $columna) {
            $sql = 'UPDATE ' . $tabla . ' e JOIN variantes v ON v.referencia = e.' . $columna
                . ' SET e.' . $columna . ' = v.referencia'
                . ' WHERE CAST(e.' . $columna . ' AS BINARY) <> CAST(v.referencia AS BINARY);';
            $ok = $db->exec($sql) && $ok;
        }

        if (false === $ok) {
            Tools::log()->error('record-save-error');
            return false;
        }

        Tools::log()->notice('tpv-recipe-refs-normalized');
        return true;
    }

    // -----------------------------------------------------------------------------------------
    // Consultas públicas (vista y resumen)

    public function apiKey(): ?ApiKey
    {
        $clave = new ApiKey();
        $where = [Where::eq('description', TpvApiPermisos::DESCRIPCION_CLAVE)];
        return $clave->loadWhere($where, ['id' => 'ASC']) ? $clave : null;
    }

    /**
     * Ejercicio abierto de la empresa por defecto para la fecha de hoy (no lo crea).
     */
    public function ejercicio(): ?Ejercicio
    {
        $ejercicio = new Ejercicio();
        $ejercicio->idempresa = (int)Tools::settings('default', 'idempresa', 1);
        return $ejercicio->loadFromDate(Tools::date(), true, false) ? $ejercicio : null;
    }

    /**
     * Cuenta bancaria activa de la empresa por defecto cuya subcuenta empieza por el prefijo.
     * Si la forma de pago del TPV ya apunta a una cuenta válida, se prefiere esa.
     */
    public function cuentaBanco(string $prefijo): ?CuentaBanco
    {
        $codpago = $prefijo === self::CUENTA_CAJA ? self::CODPAGO_EFECTIVO : self::CODPAGO_TARJETA;
        $forma = new FormaPago();
        if ($forma->load($codpago)) {
            $cuenta = $this->cuentaBancoDeForma($forma, $prefijo);
            if (null !== $cuenta) {
                return $cuenta;
            }
        }

        $where = [
            Where::like('codsubcuenta', $prefijo . '%'),
            Where::eq('idempresa', (int)Tools::settings('default', 'idempresa', 1)),
            Where::eq('activa', true),
        ];
        foreach (CuentaBanco::all($where, ['codcuenta' => 'ASC'], 0, 1) as $cuenta) {
            return $cuenta;
        }

        return null;
    }

    /**
     * Perfil de permisos de la clave ('produccion' | 'pruebas') o null si no coincide con
     * ninguno; en $diferencias deja la explicación respecto al perfil de producción.
     */
    public function perfilClave(ApiKey $clave, ?array &$diferencias = []): ?string
    {
        $actuales = [];
        foreach ($clave->getAccesses() as $access) {
            $actuales[$access->resource] = [
                (bool)$access->allowget, (bool)$access->allowpost, (bool)$access->allowput, (bool)$access->allowdelete,
            ];
        }

        foreach ([TpvApiPermisos::PERFIL_PRODUCCION, TpvApiPermisos::PERFIL_PRUEBAS] as $perfil) {
            if ($this->mismosPermisos($actuales, TpvApiPermisos::perfil($perfil))) {
                $diferencias = [];
                return $perfil;
            }
        }

        $diferencias = [];
        foreach (TpvApiPermisos::PRODUCCION as $recurso => $flags) {
            if (!isset($actuales[$recurso])) {
                $diferencias[] = Tools::trans('tpv-api-access-missing', [
                    '%resource%' => $recurso, '%methods%' => TpvApiPermisos::metodos($flags),
                ]);
            } elseif ($actuales[$recurso] !== $flags) {
                $diferencias[] = Tools::trans('tpv-api-access-differs', [
                    '%resource%' => $recurso,
                    '%methods%' => TpvApiPermisos::metodos($actuales[$recurso]) ?: '-',
                    '%expected%' => TpvApiPermisos::metodos($flags),
                ]);
            }
        }
        foreach (array_keys($actuales) as $recurso) {
            if (!isset(TpvApiPermisos::PRODUCCION[$recurso])) {
                $diferencias[] = Tools::trans('tpv-api-access-extra', ['%resource%' => $recurso]);
            }
        }

        return null;
    }

    public function tieneColumnaDestino(): bool
    {
        $db = $this->db();
        if (false === $db->tableExists('familias')) {
            return false;
        }

        return array_key_exists('tpv_destino', $db->getColumns('familias'));
    }

    /**
     * Clave de API aleatoria (32 caracteres alfanuméricos, generador criptográfico).
     */
    public static function nuevaClave(int $longitud = 32): string
    {
        $chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
        $clave = '';
        for ($i = 0; $i < $longitud; $i++) {
            $clave .= $chars[random_int(0, strlen($chars) - 1)];
        }
        return $clave;
    }

    // -----------------------------------------------------------------------------------------
    // Internos

    /**
     * Aplica exactamente los permisos del perfil: crea o ajusta los accesos y borra los que sobran.
     * El llamador lo envuelve en una transacción.
     */
    private function aplicarPerfil(ApiKey $clave, string $perfil): bool
    {
        $permisos = TpvApiPermisos::perfil($perfil);
        foreach ($clave->getAccesses() as $access) {
            if (!isset($permisos[$access->resource]) && false === $access->delete()) {
                return false;
            }
        }

        foreach ($permisos as $recurso => [$get, $post, $put, $delete]) {
            $access = $clave->getAccess($recurso);
            if (null === $access) {
                $access = new ApiAccess();
                $access->idapikey = $clave->id;
                $access->resource = $recurso;
            } elseif ((bool)$access->allowget === $get && (bool)$access->allowpost === $post
                && (bool)$access->allowput === $put && (bool)$access->allowdelete === $delete) {
                continue;
            }

            if (false === $access->setAllowed($get, $post, $put, $delete)) {
                return false;
            }
        }

        return true;
    }

    /**
     * @param string $estilo clase del botón (por defecto primary, o warning si pide confirmación)
     * @param bool $avanzada se muestra plegada en «Opciones avanzadas»
     */
    private function accion(string $accion, string $texto, string $confirmar = '', string $estilo = '', bool $avanzada = false): array
    {
        if ($estilo === '') {
            $estilo = $confirmar === '' ? 'primary' : 'warning';
        }

        return [
            'accion' => $accion,
            'texto' => Tools::trans($texto),
            'confirmar' => $confirmar === '' ? '' : Tools::trans($confirmar),
            'estilo' => $estilo,
            'avanzada' => $avanzada,
        ];
    }

    private function check(string $id, string $titulo, array $params = []): array
    {
        return [
            'id' => $id,
            'titulo' => Tools::trans($titulo, $params),
            'estado' => self::OK,
            'mensaje' => '',
            'detalles' => [],
            'acciones' => [],
            'clave' => null,
        ];
    }

    /**
     * Platos (productos que se venden) con escandallo, como en checkPlatos.
     */
    private function contarPlatosConReceta(): int
    {
        $sql = 'SELECT COUNT(DISTINCT p.idproducto) AS n'
            . ' FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_plato'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE COALESCE(p.sevende, 1) = 1';
        foreach ($this->db()->select($sql) as $row) {
            return (int)$row['n'];
        }
        return 0;
    }

    /**
     * Materias primas (ingredientes sin receta propia), como en checkMateriasPrimas.
     */
    private function contarMateriasPrimas(): int
    {
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $sql = 'SELECT COUNT(DISTINCT e.ref_ingrediente) AS n FROM ' . $tabla . ' e'
            . ' WHERE NOT EXISTS (SELECT 1 FROM ' . $tabla . ' e2 WHERE e2.ref_plato = e.ref_ingrediente)';
        foreach ($this->db()->select($sql) as $row) {
            return (int)$row['n'];
        }
        return 0;
    }

    /**
     * Cuenta bancaria de la forma de pago, si es de la empresa por defecto, está activa y su
     * subcuenta empieza por el prefijo.
     */
    private function cuentaBancoDeForma(FormaPago $forma, string $prefijo): ?CuentaBanco
    {
        if (empty($forma->codcuentabanco)) {
            return null;
        }

        $cuenta = new CuentaBanco();
        if ($cuenta->load($forma->codcuentabanco)
            && str_starts_with((string)$cuenta->codsubcuenta, $prefijo)
            && (bool)$cuenta->activa
            && (int)$cuenta->idempresa === (int)Tools::settings('default', 'idempresa', 1)) {
            return $cuenta;
        }

        return null;
    }

    /**
     * Cuentas del cierre Z sin ninguna subcuenta en el ejercicio.
     *
     * @return string[]
     */
    private function cuentasSinSubcuenta(Ejercicio $ejercicio): array
    {
        $faltan = [];
        foreach (self::CUENTAS_CIERRE_Z as $codcuenta) {
            $where = [Where::eq('codejercicio', $ejercicio->codejercicio), Where::eq('codcuenta', $codcuenta)];
            if (Subcuenta::count($where) === 0) {
                $faltan[] = $codcuenta;
            }
        }

        return $faltan;
    }

    /**
     * Crea en el ejercicio la subcuenta con ese código exacto, colgando de la cuenta del plan cuyo
     * código es el prefijo más largo del de la subcuenta.
     */
    private function crearSubcuentaExacta(Ejercicio $ejercicio, string $codsubcuenta, string $descripcion): ?Subcuenta
    {
        for ($largo = strlen($codsubcuenta) - 1; $largo >= 1; $largo--) {
            $cuenta = new Cuenta();
            $where = [
                Where::eq('codejercicio', $ejercicio->codejercicio),
                Where::eq('codcuenta', substr($codsubcuenta, 0, $largo)),
            ];
            if ($cuenta->loadWhere($where)) {
                $subcuenta = $cuenta->createSubcuenta($codsubcuenta, $descripcion);
                return $subcuenta->exists() ? $subcuenta : null;
            }
        }

        return null;
    }

    private function db(): DataBase
    {
        $db = new DataBase();
        $db->connect();
        return $db;
    }

    /**
     * Añade a los detalles de la comprobación las primeras filas (referencia · descripción) y un
     * resumen del resto.
     */
    private function detallesProductos(array &$check, array $filas): void
    {
        foreach (array_slice($filas, 0, self::MAX_DETALLES) as $row) {
            $check['detalles'][] = $row['referencia'] . ' · ' . $row['descripcion'];
        }
        if (count($filas) > self::MAX_DETALLES) {
            $check['detalles'][] = Tools::trans('tpv-and-more', ['%count%' => count($filas) - self::MAX_DETALLES]);
        }
    }

    /**
     * @return string[] diferencias (traducidas) respecto a lo que espera el TPV
     */
    private function diferenciasFormaPago(FormaPago $forma, string $prefijo): array
    {
        $diferencias = [];
        if (false === (bool)$forma->activa) {
            $diferencias[] = Tools::trans('tpv-payment-inactive');
        }
        if (false === (bool)$forma->pagado) {
            $diferencias[] = Tools::trans('tpv-payment-not-paid');
        }
        if ((int)$forma->plazovencimiento !== 0) {
            $diferencias[] = Tools::trans('tpv-payment-not-immediate', [
                '%term%' => $forma->plazovencimiento . ' ' . mb_strtolower(Tools::trans((string)$forma->tipovencimiento)),
            ]);
        }
        if (null === $this->cuentaBancoDeForma($forma, $prefijo)) {
            $diferencias[] = Tools::trans('tpv-payment-wrong-account', [
                '%account%' => $prefijo,
                '%current%' => empty($forma->codcuentabanco) ? '-' : $forma->codcuentabanco,
            ]);
        }

        return $diferencias;
    }

    private function estado(array $check, string $estado, string $mensaje, array $params = []): array
    {
        $check['estado'] = $estado;
        $check['mensaje'] = Tools::trans($mensaje, $params);
        return $check;
    }

    /**
     * Familias con productos vendibles (o sus madres) sin destino de impresión efectivo.
     *
     * @return string[] codfamilia
     */
    private function familiasSinDestino(): array
    {
        if (false === $this->tieneColumnaDestino()) {
            return [];
        }

        $sql = 'SELECT DISTINCT p.codfamilia FROM productos p'
            . ' WHERE COALESCE(p.sevende, 1) = 1 AND COALESCE(p.bloqueado, 0) = 0 AND p.codfamilia IS NOT NULL'
            . ' ORDER BY p.codfamilia';
        $out = [];
        foreach ($this->db()->select($sql) as $row) {
            $familia = new Familia();
            if ($familia->load($row['codfamilia']) && null === $familia->tpvDestinoEfectivo()) {
                $out[] = (string)$row['codfamilia'];
            }
        }

        return $out;
    }

    /**
     * Destino traducido: Cocina o Barra.
     */
    private function textoDestino(string $destino): string
    {
        return Tools::trans($destino === TpvStockDestino::BARRA ? 'tpv-bar' : 'tpv-kitchen');
    }

    /**
     * Los tres primeros platos y «…» si hay más.
     *
     * @param string[] $platos
     */
    private function textoPlatos(array $platos): string
    {
        sort($platos, SORT_STRING);
        return implode(', ', array_slice($platos, 0, 3)) . (count($platos) > 3 ? ' …' : '');
    }

    /**
     * «Cocina: PLA-A, PLA-B; Barra: BEB-C» a partir de destino => platos.
     */
    private function textoUsos(array $usos): string
    {
        $partes = [];
        foreach ($usos as $destino => $platos) {
            $partes[] = $this->textoDestino((string)$destino) . ': ' . $this->textoPlatos($platos);
        }

        return implode('; ', $partes);
    }

    /**
     * Lista de códigos abreviada: los diez primeros y «… y N más».
     */
    private function listaCorta(array $codigos): string
    {
        $lista = implode(', ', array_slice($codigos, 0, 10));
        return count($codigos) > 10 ? $lista . ' ' . Tools::trans('tpv-and-more', ['%count%' => count($codigos) - 10]) : $lista;
    }

    /**
     * Ingredientes (sin receta propia) cuyo producto tiene "no controlar stock" (el TPV no los
     * descuenta: solo los anota en su diario). Sin los productos mixtos, que se avisan aparte.
     */
    private function materiasSinStock(): array
    {
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $sql = 'SELECT DISTINCT p.idproducto, p.referencia, p.descripcion'
            . ' FROM ' . $tabla . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_ingrediente'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE COALESCE(p.nostock, 0) = 1'
            . ' AND NOT EXISTS (SELECT 1 FROM ' . $tabla . ' e2 WHERE e2.ref_plato = e.ref_ingrediente)'
            . ' ORDER BY p.referencia';
        return $this->sinMixtos($this->db()->select($sql));
    }

    /**
     * Materias primas de receta (hojas) con control de stock y sin coste en su ficha.
     */
    private function materiasSinCoste(): array
    {
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $sql = 'SELECT DISTINCT v.referencia, p.descripcion'
            . ' FROM ' . $tabla . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_ingrediente'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE COALESCE(v.coste, 0) <= 0'
            . ' AND NOT EXISTS (SELECT 1 FROM ' . $tabla . ' e2 WHERE e2.ref_plato = e.ref_ingrediente)'
            . ' ORDER BY v.referencia';
        return $this->db()->select($sql);
    }

    /**
     * Materias primas de receta con control de stock y sin fila de stock o sin stock mínimo en el
     * almacén: la reposición automática de la app no las pedirá nunca.
     */
    private function materiasSinMinimo(string $codalmacen): array
    {
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $sql = 'SELECT DISTINCT v.referencia'
            . ' FROM ' . $tabla . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_ingrediente'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' LEFT JOIN stocks s ON s.referencia = v.referencia AND s.codalmacen = ' . $this->db()->var2str($codalmacen)
            . ' WHERE COALESCE(p.nostock, 0) = 0 AND COALESCE(s.stockmin, 0) <= 0'
            . ' AND NOT EXISTS (SELECT 1 FROM ' . $tabla . ' e2 WHERE e2.ref_plato = e.ref_ingrediente)'
            . ' ORDER BY v.referencia';
        return $this->db()->select($sql);
    }

    /**
     * Referencias con stock mínimo en el almacén y sin ningún proveedor activo que las venda.
     */
    private function materiasSinProveedor(string $codalmacen): array
    {
        $sql = 'SELECT s.referencia FROM stocks s'
            . ' JOIN variantes v ON v.referencia = s.referencia'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE s.codalmacen = ' . $this->db()->var2str($codalmacen) . ' AND s.stockmin > 0'
            . ' AND COALESCE(p.nostock, 0) = 0'
            . ' AND NOT EXISTS (SELECT 1 FROM productosprov pp JOIN proveedores pr ON pr.codproveedor = pp.codproveedor'
            . ' WHERE pp.referencia = s.referencia AND pr.fechabaja IS NULL)'
            . ' ORDER BY s.referencia';
        return $this->db()->select($sql);
    }

    private function mismosPermisos(array $actuales, array $esperados): bool
    {
        if (count($actuales) !== count($esperados)) {
            return false;
        }
        foreach ($esperados as $recurso => $flags) {
            if (!isset($actuales[$recurso]) || $actuales[$recurso] !== $flags) {
                return false;
            }
        }
        return true;
    }

    /**
     * Pedidos de reposición del TPV que siguen sin recibir pasados unos días.
     */
    private function pedidosReposicionAbiertos(): array
    {
        $limite = date('Y-m-d', strtotime('-' . self::DIAS_PEDIDO_ABIERTO . ' days'));
        $sql = 'SELECT codigo FROM pedidosprov'
            . " WHERE numproveedor LIKE 'TPV-REPO-%' AND editable = 1"
            . ' AND fecha < ' . $this->db()->var2str($limite)
            . ' ORDER BY fecha';
        return $this->db()->select($sql);
    }

    /**
     * Productos vendibles con escandallo que todavía controlan stock (FS descontaría el plato
     * además de sus ingredientes). Sin los productos mixtos, que se avisan aparte.
     */
    private function platosConStock(): array
    {
        $sql = 'SELECT DISTINCT p.idproducto, p.referencia, p.descripcion'
            . ' FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_plato'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE COALESCE(p.sevende, 1) = 1 AND COALESCE(p.nostock, 0) = 0'
            . ' ORDER BY p.referencia';
        return $this->sinMixtos($this->db()->select($sql));
    }

    /**
     * Platos con receta completa cuyo coste en ficha no coincide con el teórico. Con $conMargen
     * false, sin las variantes con margen (no se les copia el coste: FS recalcularía su precio).
     *
     * @return array[] referencia, coste (teórico), coste_ficha, margen
     */
    private function platosConCosteDistinto(bool $conMargen = false): array
    {
        $costes = new TpvCosteEscandallo();
        $platos = $costes->grafo()->platos();
        $datos = TpvCatalogo::variantes($platos);
        $out = [];
        foreach ($platos as $plato) {
            $fila = TpvCatalogo::fila($datos, $plato);
            $margen = (float)($fila['margen'] ?? 0);
            if ($margen > 0 && false === $conMargen) {
                continue;
            }

            $teorico = $costes->costeUnitario($plato);
            $ficha = (float)($fila['coste'] ?? 0);
            if ($teorico['origen'] === TpvCosteEscandallo::ORIGEN_RECETA && $teorico['coste'] > 0
                && abs($teorico['coste'] - $ficha) > TpvRecetas::TOLERANCIA_COSTE) {
                $out[] = ['referencia' => $plato, 'coste' => $teorico['coste'], 'coste_ficha' => $ficha, 'margen' => $margen];
            }
        }

        return $out;
    }

    /**
     * Productos que se venden, con «no controlar stock» y sin receta en ninguna de sus variantes:
     * ni FS ni el TPV descuentan nada al venderlos (puede ser intencionado: pan, servicio...).
     */
    private function platosSinReceta(): array
    {
        $sql = 'SELECT p.idproducto, p.referencia, p.descripcion FROM productos p'
            . ' WHERE COALESCE(p.sevende, 1) = 1 AND COALESCE(p.bloqueado, 0) = 0 AND COALESCE(p.nostock, 0) = 1'
            . ' AND NOT EXISTS (SELECT 1 FROM variantes v JOIN ' . TpvSchema::TABLE_ESCANDALLOS . ' e'
            . ' ON e.ref_plato = v.referencia WHERE v.idproducto = p.idproducto)'
            . ' ORDER BY p.referencia';
        return $this->db()->select($sql);
    }

    /**
     * @return string[]
     */
    private function problemasCliente(Cliente $cliente): array
    {
        $problemas = [];
        if ((bool)$cliente->debaja) {
            $problemas[] = Tools::trans('tpv-customer-inactive');
        }
        if (!empty($cliente->riesgomax) && (float)$cliente->riesgomax > 0) {
            $problemas[] = Tools::trans('tpv-customer-risk', ['%risk%' => Tools::money((float)$cliente->riesgomax)]);
        }
        return $problemas;
    }

    /**
     * Productos con una variante que es plato (tiene receta) y otra que es materia prima (hoja
     * de otra receta).
     */
    private function productosMixtos(): array
    {
        $tabla = TpvSchema::TABLE_ESCANDALLOS;
        $sql = 'SELECT DISTINCT p.idproducto, p.referencia, p.descripcion FROM productos p'
            . ' WHERE EXISTS (SELECT 1 FROM variantes v JOIN ' . $tabla . ' e ON e.ref_plato = v.referencia'
            . ' WHERE v.idproducto = p.idproducto)'
            . ' AND EXISTS (SELECT 1 FROM variantes v2 JOIN ' . $tabla . ' e2 ON e2.ref_ingrediente = v2.referencia'
            . ' WHERE v2.idproducto = p.idproducto'
            . ' AND NOT EXISTS (SELECT 1 FROM ' . $tabla . ' e3 WHERE e3.ref_plato = v2.referencia))'
            . ' ORDER BY p.referencia';
        return $this->db()->select($sql);
    }

    /**
     * Productos de la carta con control de stock que no permiten vender sin stock.
     */
    private function productosSinVentaSinStock(): array
    {
        $sql = 'SELECT p.idproducto, p.referencia, p.descripcion FROM productos p'
            . ' WHERE COALESCE(p.sevende, 1) = 1 AND COALESCE(p.bloqueado, 0) = 0'
            . ' AND COALESCE(p.nostock, 0) = 0 AND COALESCE(p.ventasinstock, 0) = 0'
            . ' ORDER BY p.referencia';
        return $this->db()->select($sql);
    }

    /**
     * Rectificativas que conservan el numero2 'TPV-...' de su ticket.
     */
    private function rectificativasConClaveDeTicket(): int
    {
        $sql = "SELECT COUNT(*) AS n FROM facturascli WHERE idfacturarect IS NOT NULL AND numero2 LIKE 'TPV-%'";
        foreach ($this->db()->select($sql) as $row) {
            return (int)$row['n'];
        }

        return 0;
    }

    /**
     * Líneas de receta cuya referencia no está escrita exactamente como en variantes.
     *
     * @return array[] guardada, referencia
     */
    private function referenciasNoCanonicas(): array
    {
        $out = [];
        foreach (['ref_plato', 'ref_ingrediente'] as $columna) {
            $sql = 'SELECT DISTINCT e.' . $columna . ' AS guardada, v.referencia'
                . ' FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e JOIN variantes v ON v.referencia = e.' . $columna
                . ' WHERE CAST(e.' . $columna . ' AS BINARY) <> CAST(v.referencia AS BINARY)';
            foreach ($this->db()->select($sql) as $row) {
                $out[$row['guardada']] = $row;
            }
        }

        return array_values($out);
    }

    /**
     * Quita de las filas los productos mixtos (los avisa checkProductosMixtos, sin acción
     * automática: las acciones de platos y de materias primas se anularían entre sí).
     */
    private function sinMixtos(array $filas): array
    {
        $mixtos = array_column($this->productosMixtos(), 'idproducto');
        if (empty($mixtos)) {
            return $filas;
        }

        return array_values(array_filter($filas, function ($row) use ($mixtos) {
            return false === in_array($row['idproducto'], $mixtos);
        }));
    }

    /**
     * Filas de stock del almacén con mínimo o máximo negativos (la app invalida la auditoría
     * de reposición completa).
     */
    private function stocksNegativos(string $codalmacen): array
    {
        $sql = 'SELECT referencia FROM stocks WHERE codalmacen = ' . $this->db()->var2str($codalmacen)
            . ' AND (stockmin < 0 OR stockmax < 0) ORDER BY referencia';
        return $this->db()->select($sql);
    }

    /**
     * Subcuenta del ejercicio para una cuenta (570 / 572 / 659...): la primera existente o una nueva.
     */
    private function subcuentaParaCuenta(Ejercicio $ejercicio, string $codcuenta, string $descripcion): ?Subcuenta
    {
        $where = [
            Where::eq('codejercicio', $ejercicio->codejercicio),
            Where::eq('codcuenta', $codcuenta),
        ];
        foreach (Subcuenta::all($where, ['codsubcuenta' => 'ASC'], 0, 1) as $subcuenta) {
            return $subcuenta;
        }

        $cuenta = new Cuenta();
        if (false === $cuenta->loadWhere($where)) {
            return null;
        }

        $codigo = str_pad($codcuenta, (int)$ejercicio->longsubcuenta, '0');
        $subcuenta = $cuenta->createSubcuenta($codigo, $descripcion);
        return $subcuenta->exists() ? $subcuenta : null;
    }
}
