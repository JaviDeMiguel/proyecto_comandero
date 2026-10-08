<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
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

    const OK = 'ok';
    const AVISO = 'aviso';
    const ERROR = 'error';

    /** Acciones que modifican datos existentes: requieren confirm = 1. */
    const ACCIONES_CON_CONFIRMACION = [
        'adjust-payments', 'fix-customer', 'fix-serie', 'fix-api-key', 'api-key-test-profile',
        'regenerate-api-key', 'fix-dishes', 'fix-ingredients',
    ];

    /** Mensaje de la última acción (para la vista). @var string */
    public $mensaje = '';

    // -----------------------------------------------------------------------------------------
    // Comprobaciones

    /**
     * Lista de comprobaciones en el orden en que se muestran.
     *
     * @return array[] cada una: id, titulo, estado, mensaje, detalles[], acciones[]
     */
    public function comprobaciones(): array
    {
        return [
            $this->checkApi(),
            $this->checkEjercicio(),
            $this->checkCuentas(),
            $this->checkFormaPago(self::CODPAGO_EFECTIVO),
            $this->checkFormaPago(self::CODPAGO_TARJETA),
            $this->checkCliente(),
            $this->checkSerie(),
            $this->checkAlmacen(),
            $this->checkApiKey(),
            $this->checkTablas(),
            $this->checkPlatos(),
            $this->checkMateriasPrimas(),
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
        return $this->estado($check, self::OK, 'tpv-check-warehouse-ok', ['%code%' => $almacen->codalmacen]);
    }

    public function checkApiKey(): array
    {
        $check = $this->check('apikey', 'tpv-check-api-key');
        $clave = $this->apiKey();
        if (null === $clave) {
            $check['acciones'][] = $this->accion('create-api-key', 'tpv-action-create-api-key');
            return $this->estado($check, self::ERROR, 'tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
        }

        $check['clave'] = $clave->apikey;
        $check['acciones'][] = $this->accion('regenerate-api-key', 'tpv-action-regenerate-api-key', 'tpv-confirm-regenerate-api-key', 'outline-danger');

        $problemas = [];
        if (false === (bool)$clave->enabled) {
            $problemas[] = Tools::trans('tpv-api-key-disabled');
        }
        if ((bool)$clave->fullaccess) {
            $problemas[] = Tools::trans('tpv-api-key-full-access');
        }

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

        $check['acciones'][] = $this->accion('api-key-test-profile', 'tpv-action-api-key-test-profile', 'tpv-confirm-api-key-test-profile', 'outline-secondary');
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

        if (empty($faltan)) {
            return $this->estado($check, self::OK, 'tpv-check-tables-ok');
        }

        $check['detalles'][] = implode(', ', $faltan);
        $check['acciones'][] = $this->accion('create-tables', 'tpv-action-create-tables');
        return $this->estado($check, self::ERROR, 'tpv-check-tables-missing');
    }

    public function checkPlatos(): array
    {
        $check = $this->check('platos', 'tpv-check-dishes');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::ERROR, 'tpv-check-requires-tables');
        }

        $platos = $this->platosConStock();
        if (empty($platos)) {
            return $this->estado($check, self::OK, 'tpv-check-dishes-ok', ['%count%' => $this->contarPlatosConReceta()]);
        }

        foreach ($platos as $row) {
            $check['detalles'][] = $row['referencia'] . ' · ' . $row['descripcion'];
        }
        $check['acciones'][] = $this->accion('fix-dishes', 'tpv-action-fix-dishes', 'tpv-confirm-fix-dishes');
        return $this->estado($check, self::AVISO, 'tpv-check-dishes-with-stock', ['%count%' => count($platos)]);
    }

    public function checkMateriasPrimas(): array
    {
        $check = $this->check('materias', 'tpv-check-ingredients');
        if (false === $this->db()->tableExists(TpvSchema::TABLE_ESCANDALLOS)) {
            return $this->estado($check, self::ERROR, 'tpv-check-requires-tables');
        }

        $materias = $this->materiasSinStock();
        if (empty($materias)) {
            return $this->estado($check, self::OK, 'tpv-check-ingredients-ok', ['%count%' => $this->contarIngredientes()]);
        }

        foreach ($materias as $row) {
            $check['detalles'][] = $row['referencia'] . ' · ' . $row['descripcion'];
        }
        $check['acciones'][] = $this->accion('fix-ingredients', 'tpv-action-fix-ingredients', 'tpv-confirm-fix-ingredients');
        return $this->estado($check, self::AVISO, 'tpv-check-ingredients-without-stock', ['%count%' => count($materias)]);
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

            case 'regenerate-api-key':
                return $this->accionRegenerarClave();

            case 'create-tables':
                return $this->accionCrearTablas();

            case 'fix-dishes':
                return $this->accionMarcarProductos($this->platosConStock(), true);

            case 'fix-ingredients':
                return $this->accionMarcarProductos($this->materiasSinStock(), false);

            case 'setup-all':
                return $this->accionConfigurarTodo($nick);
        }

        Tools::log()->warning('tpv-unknown-action', ['%action%' => $accion]);
        return false;
    }

    /**
     * Crea todo lo que FALTA (no modifica nada existente): API, cuentas, formas de pago,
     * cliente, serie, clave de API y tablas.
     */
    private function accionConfigurarTodo(string $nick): bool
    {
        $ok = true;
        if (false === (bool)Tools::settings('default', 'enable_api', false)) {
            $ok = $this->accionActivarApi() && $ok;
        }
        $ok = $this->accionCrearTablas() && $ok;
        $ok = $this->accionCrearCuentas() && $ok;
        $ok = $this->accionCrearFormasPago() && $ok;
        $ok = $this->accionCrearSerie() && $ok;
        $ok = $this->accionCrearCliente() && $ok;
        if (null === $this->apiKey()) {
            $ok = $this->accionCrearClave($nick) && $ok;
        }

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

    private function accionCrearCuentas(): bool
    {
        $ejercicio = $this->ejercicio();
        if (null === $ejercicio || false === $ejercicio->hasAccountingPlan()) {
            Tools::log()->error('tpv-check-exercise-no-plan', ['%exercise%' => $ejercicio->nombre ?? Tools::date()]);
            return false;
        }

        $ok = true;
        $nombres = [self::CUENTA_CAJA => 'Caja', self::CUENTA_BANCO => 'Banco TPV'];
        foreach ($nombres as $prefijo => $descripcion) {
            $cuenta = $this->cuentaBanco($prefijo);
            if (null !== $cuenta) {
                // existe: solo nos aseguramos de que su subcuenta exista en el ejercicio vigente
                if (false === $cuenta->getSubcuenta($ejercicio->codejercicio, false)->exists()) {
                    $subcuenta = $cuenta->getSubcuenta($ejercicio->codejercicio, true);
                    if ($subcuenta->exists()) {
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

        $clave = new ApiKey();
        $clave->apikey = self::nuevaClave();
        $clave->description = TpvApiPermisos::DESCRIPCION_CLAVE;
        $clave->nick = $nick === '' ? null : $nick;
        $clave->enabled = true;
        $clave->fullaccess = false;
        if (false === $clave->save()) {
            Tools::log()->error('record-save-error');
            return false;
        }

        if (false === $this->aplicarPerfil($clave, TpvApiPermisos::PERFIL_PRODUCCION)) {
            return false;
        }

        Tools::log()->notice('tpv-api-key-created', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
        return true;
    }

    private function accionPermisosClave(string $perfil): bool
    {
        $clave = $this->apiKey();
        if (null === $clave) {
            Tools::log()->warning('tpv-check-api-key-missing', ['%name%' => TpvApiPermisos::DESCRIPCION_CLAVE]);
            return false;
        }

        $clave->enabled = true;
        $clave->fullaccess = false;
        if (false === $clave->save() || false === $this->aplicarPerfil($clave, $perfil)) {
            Tools::log()->error('record-save-error');
            return false;
        }

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
            DbUpdater::rebuild();
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
    private function accionMarcarProductos(array $filas, bool $nostock): bool
    {
        $ok = true;
        $cambiados = 0;
        foreach ($filas as $row) {
            $producto = new Producto();
            if (false === $producto->load($row['idproducto'])) {
                continue;
            }
            if ((bool)$producto->nostock === $nostock) {
                continue;
            }

            $producto->nostock = $nostock;
            if (false === $producto->save()) {
                Tools::log()->error('record-save-error');
                $ok = false;
                continue;
            }
            $cambiados++;
        }

        Tools::log()->notice('tpv-products-updated', ['%count%' => $cambiados]);
        return $ok;
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

    // -----------------------------------------------------------------------------------------
    // Internos

    /**
     * Aplica exactamente los permisos del perfil: crea o ajusta los accesos y borra los que sobran.
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

    private function accion(string $accion, string $texto, string $confirmar = '', string $estilo = ''): array
    {
        if ($estilo === '') {
            $estilo = $confirmar === '' ? 'primary' : 'warning';
        }

        return [
            'accion' => $accion,
            'texto' => Tools::trans($texto),
            'confirmar' => $confirmar === '' ? '' : Tools::trans($confirmar),
            'estilo' => $estilo,
        ];
    }

    private function check(string $id, string $titulo): array
    {
        return [
            'id' => $id,
            'titulo' => Tools::trans($titulo),
            'estado' => self::OK,
            'mensaje' => '',
            'detalles' => [],
            'acciones' => [],
            'clave' => null,
        ];
    }

    private function contarIngredientes(): int
    {
        $sql = 'SELECT COUNT(DISTINCT ref_ingrediente) AS n FROM ' . TpvSchema::TABLE_ESCANDALLOS;
        foreach ($this->db()->select($sql) as $row) {
            return (int)$row['n'];
        }
        return 0;
    }

    private function contarPlatosConReceta(): int
    {
        $sql = 'SELECT COUNT(DISTINCT ref_plato) AS n FROM ' . TpvSchema::TABLE_ESCANDALLOS;
        foreach ($this->db()->select($sql) as $row) {
            return (int)$row['n'];
        }
        return 0;
    }

    private function cuentaBancoDeForma(FormaPago $forma, string $prefijo): ?CuentaBanco
    {
        if (empty($forma->codcuentabanco)) {
            return null;
        }

        $cuenta = new CuentaBanco();
        if ($cuenta->load($forma->codcuentabanco) && str_starts_with((string)$cuenta->codsubcuenta, $prefijo)) {
            return $cuenta;
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
                '%term%' => $forma->plazovencimiento . ' ' . $forma->tipovencimiento,
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
     * Ingredientes (sin receta propia) cuyo producto tiene "no controlar stock".
     */
    private function materiasSinStock(): array
    {
        $sql = 'SELECT DISTINCT p.idproducto, p.referencia, p.descripcion'
            . ' FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_ingrediente'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE p.nostock = 1'
            . ' AND NOT EXISTS (SELECT 1 FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e2 WHERE e2.ref_plato = e.ref_ingrediente)'
            . ' ORDER BY p.referencia';
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

    /**
     * Productos vendibles con escandallo que todavía controlan stock.
     */
    private function platosConStock(): array
    {
        $sql = 'SELECT DISTINCT p.idproducto, p.referencia, p.descripcion'
            . ' FROM ' . TpvSchema::TABLE_ESCANDALLOS . ' e'
            . ' JOIN variantes v ON v.referencia = e.ref_plato'
            . ' JOIN productos p ON p.idproducto = v.idproducto'
            . ' WHERE p.sevende = 1 AND p.nostock = 0'
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
     * Subcuenta del ejercicio para una cuenta (570 / 572): la primera existente o una nueva.
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
        $whereCuenta = [
            Where::eq('codejercicio', $ejercicio->codejercicio),
            Where::eq('codcuenta', $codcuenta),
        ];
        if (false === $cuenta->loadWhere($whereCuenta)) {
            return null;
        }

        $codigo = str_pad($codcuenta, (int)$ejercicio->longsubcuenta, '0');
        $subcuenta = $cuenta->createSubcuenta($codigo, $descripcion);
        return $subcuenta->exists() ? $subcuenta : null;
    }
}
