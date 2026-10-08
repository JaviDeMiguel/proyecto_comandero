<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Controller;

use FacturaScripts\Core\Base\Controller;
use FacturaScripts\Core\Tools;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvApiPermisos;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvAsistente;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCartaEjemplo;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvMysqlUsuario;

/**
 * Página "Configurar TPV": comprobaciones con botón de corrección, usuario de MySQL para el
 * TPV, resumen con los valores que hay que poner en la app y carga de la carta de ejemplo.
 *
 * Solo para administradores (muestra la clave de API y puede crear usuarios de MySQL).
 * Todas las acciones van por POST con el token del formulario.
 */
class ConfigurarTpv extends Controller
{
    /** @var TpvAsistente */
    public $asistente;

    /** @var array[] */
    public $comprobaciones = [];

    /** @var bool */
    public $esAdmin = false;

    /** @var TpvMysqlUsuario|null usuario de MySQL generado en esta petición (contraseña visible) */
    public $mysql = null;

    /** @var array resultado de ejecutar las sentencias de MySQL: [ok, mensaje] */
    public $mysqlResultado = [];

    /** @var array formulario de MySQL: usuario, host, tls */
    public $mysqlForm = ['usuario' => 'tpv_comandero', 'host' => '192.168.1.%', 'tls' => true];

    /** @var array resumen de la última carga de la carta */
    public $resumenCarta = [];

    public function getPageData(): array
    {
        $data = parent::getPageData();
        $data['menu'] = 'hosteleria';
        $data['title'] = 'tpv-setup';
        $data['icon'] = 'fa-solid fa-wand-magic-sparkles';
        $data['ordernum'] = 1;
        return $data;
    }

    /**
     * Valores que hay que configurar en la app (Ajustes del TPV).
     */
    public function resumen(): array
    {
        $clave = $this->asistente->apiKey();
        $dbHost = (string)Tools::config('db_host', '');
        $local = self::esHostLocal($dbHost);

        // la URL sale del ajuste site_url o de la petición del administrador: en WAMP suele ser
        // http://localhost/facturascripts, inservible desde la tableta
        $url = rtrim(Tools::siteUrl(), '/');
        $urlLocal = self::esHostLocal((string)parse_url($url, PHP_URL_HOST));
        $urlSugerida = $urlLocal ? self::urlConIp($url, self::ipRedLocal()) : null;

        return [
            'url' => $url,
            'api' => $url . '/api/3',
            'urlLocal' => $urlLocal,
            'urlSugerida' => $urlSugerida,
            'apiSugerida' => $urlSugerida === null ? null : $urlSugerida . '/api/3',
            'clave' => $clave ? $clave->apikey : null,
            'codserie' => TpvAsistente::CODSERIE,
            'codcliente' => TpvAsistente::CODCLIENTE,
            'codalmacen' => (string)Tools::settings('default', 'codalmacen', ''),
            'idempresa' => (int)Tools::settings('default', 'idempresa', 1),
            'efectivo' => TpvAsistente::CODPAGO_EFECTIVO,
            'tarjeta' => TpvAsistente::CODPAGO_TARJETA,
            'dbHost' => $dbHost,
            'dbHostLocal' => $local,
            'dbPort' => (int)Tools::config('db_port', 3306),
            'dbName' => TpvMysqlUsuario::baseDatos(),
            'dbUser' => $this->mysqlForm['usuario'],
            'dbType' => strtolower((string)Tools::config('db_type', 'mysql')),
        ];
    }

    /**
     * True si el host es de bucle local (no sirve para conectar desde otro equipo).
     */
    public static function esHostLocal(string $host): bool
    {
        $host = strtolower(trim($host, " []"));
        return in_array($host, ['localhost', '127.0.0.1', '::1', '0.0.0.0'], true)
            || 0 === strpos($host, '127.');
    }

    /**
     * IPv4 privada de este servidor en la red local, o null si no se encuentra.
     * Prefiere 192.168.x.x, luego 10.x.x.x y luego 172.16-31.x.x (en Windows las redes
     * virtuales de Hyper-V/WSL suelen ser 172.x).
     */
    public static function ipRedLocal(): ?string
    {
        $candidatas = [];
        if (!empty($_SERVER['SERVER_ADDR'])) {
            $candidatas[] = (string)$_SERVER['SERVER_ADDR'];
        }
        $nombre = gethostname();
        if (is_string($nombre) && $nombre !== '') {
            $ips = gethostbynamel($nombre);
            if (is_array($ips)) {
                $candidatas = array_merge($candidatas, $ips);
            }
        }

        $mejor = null;
        $mejorRango = PHP_INT_MAX;
        foreach ($candidatas as $ip) {
            if (false === filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4)) {
                continue;
            }
            if (0 === strpos($ip, '192.168.')) {
                $rango = 0;
            } elseif (0 === strpos($ip, '10.')) {
                $rango = 1;
            } elseif (1 === preg_match('/^172\.(1[6-9]|2\d|3[01])\./', $ip)) {
                $rango = 2;
            } else {
                continue;
            }
            if ($rango < $mejorRango) {
                $mejor = $ip;
                $mejorRango = $rango;
            }
        }

        return $mejor;
    }

    /**
     * La misma URL con el host cambiado por la IP (conserva esquema, puerto y ruta).
     */
    public static function urlConIp(string $url, ?string $ip): ?string
    {
        $partes = parse_url($url);
        if (null === $ip || false === $partes || empty($partes['host'])) {
            return null;
        }

        return ($partes['scheme'] ?? 'http') . '://' . $ip
            . (isset($partes['port']) ? ':' . $partes['port'] : '')
            . rtrim($partes['path'] ?? '', '/');
    }

    public function totalesCarta(): array
    {
        return TpvCartaEjemplo::totales();
    }

    public function permisosApi(): array
    {
        $out = [];
        foreach (TpvApiPermisos::PRODUCCION as $recurso => $flags) {
            $out[$recurso] = TpvApiPermisos::metodos($flags);
        }
        return $out;
    }

    public function privateCore(&$response, $user, $permissions)
    {
        parent::privateCore($response, $user, $permissions);
        $this->asistente = new TpvAsistente();
        $this->esAdmin = (bool)$user->admin;
        if (false === $this->esAdmin) {
            Tools::log()->warning('tpv-setup-admin-only');
            return;
        }

        $action = $this->request->input('action', '');
        if ($action !== '' && $this->request->isMethod('POST')) {
            $this->execAction($action);
        }

        $this->comprobaciones = $this->asistente->comprobaciones();
    }

    private function execAction(string $action): void
    {
        if (false === $this->validateFormToken()) {
            return;
        }

        switch ($action) {
            case 'tpv-fix':
                $fix = (string)$this->request->input('fix', '');
                $confirm = $this->request->input('confirm', '') === '1';
                if ($this->asistente->ejecutar($fix, $confirm, (string)$this->user->nick)) {
                    Tools::log()->notice('tpv-action-done');
                }
                return;

            case 'mysql-generate':
                $this->leerFormMysql();
                $mysql = new TpvMysqlUsuario($this->mysqlForm['usuario'], $this->mysqlForm['host'], $this->mysqlForm['tls']);
                $errores = $mysql->errores();
                foreach ($errores as $error) {
                    Tools::log()->warning($error);
                }
                if (empty($errores)) {
                    $this->mysql = $mysql;
                }
                return;

            case 'mysql-execute':
                $this->leerFormMysql();
                if ($this->request->input('confirm', '') !== '1') {
                    Tools::log()->warning('tpv-action-needs-confirmation');
                    return;
                }
                $mysql = new TpvMysqlUsuario(
                    $this->mysqlForm['usuario'],
                    $this->mysqlForm['host'],
                    $this->mysqlForm['tls'],
                    (string)$this->request->input('password', '')
                );
                foreach ($mysql->errores() as $error) {
                    Tools::log()->warning($error);
                }
                // restablecer la contraseña de una cuenta que ya existe exige marcar la casilla
                // (que tiene su propia confirmación en la vista)
                $restablecer = $this->request->input('reset_password', '') === '1';
                $this->mysqlResultado = $mysql->ejecutar($restablecer);
                if ($this->mysqlResultado[0]) {
                    Tools::log()->notice('tpv-mysql-executed-ok');
                } else {
                    Tools::log()->error('tpv-mysql-executed-failed');
                }
                return;

            case 'load-menu':
                $carta = new TpvCartaEjemplo();
                $ok = $carta->cargar();
                $this->resumenCarta = $carta->resumen;
                if ($ok) {
                    Tools::log()->notice('tpv-menu-loaded');
                }
                return;
        }

        Tools::log()->warning('tpv-unknown-action', ['%action%' => $action]);
    }

    private function leerFormMysql(): void
    {
        $this->mysqlForm = [
            'usuario' => trim((string)$this->request->input('mysql_user', 'tpv_comandero')),
            'host' => trim((string)$this->request->input('mysql_host', '192.168.1.%')),
            'tls' => $this->request->input('mysql_tls', '') === '1',
        ];
    }
}
