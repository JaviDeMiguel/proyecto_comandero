<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Tools;
use mysqli;
use mysqli_driver;
use mysqli_sql_exception;
use Throwable;

/**
 * Sentencias CREATE USER / GRANT para el usuario de MySQL del TPV, con privilegios mínimos
 * (exactamente lo que ejecuta la app, ver stock_repository.dart y escandallo_repository.dart):
 *  - stocks: SELECT, INSERT, UPDATE (INSERT ... ON DUPLICATE KEY UPDATE de cantidad y disponible);
 *  - productos: SELECT y UPDATE solo de las columnas stockfis y actualizado;
 *  - variantes: SELECT, UPDATE solo de stockfis y REFERENCES solo de referencia (la clave ajena
 *    de las tablas tpv_* si es la app quien las crea);
 *  - solo lectura en productosprov, proveedores y familias (reaprovisionamiento);
 *  - tpv_escandallos y tpv_movimientos_stock: SELECT, INSERT, UPDATE, DELETE y CREATE
 *    (CREATE TABLE IF NOT EXISTS). Sin DROP, ALTER, INDEX ni TRIGGER: quien obtenga las
 *    credenciales de la tableta no puede borrar el diario de idempotencia ni cambiar precios.
 *
 * Seguridad de "Ejecutar ahora":
 *  - nunca sobre la cuenta de FacturaScripts (db_user de config.php) ni sobre cuentas del
 *    sistema (root, mysql.*, debian-sys-maint...): errores() las rechaza;
 *  - si la cuenta no existe se crea con CREATE USER (sin IF NOT EXISTS, que fallaría en silencio);
 *  - si ya existe no se toca, salvo que se pida explícitamente restablecer su contraseña
 *    (casilla con su propia confirmación): entonces ALTER USER, se retiran los privilegios de
 *    tabla anteriores sobre estas tablas y se conceden los mínimos.
 *
 * Las sentencias solo se ejecutan a petición explícita del usuario y con una conexión mysqli
 * propia (no con DataBase de FacturaScripts, que guarda el SQL en el historial y mostraría la
 * contraseña). La contraseña no se guarda en ningún sitio: se muestra una vez.
 */
final class TpvMysqlUsuario
{
    /** Privilegios por tabla de FacturaScripts (por columna donde la app solo escribe algunas). */
    const PRIVILEGIOS = [
        'stocks' => 'SELECT, INSERT, UPDATE',
        'variantes' => 'SELECT, UPDATE (stockfis), REFERENCES (referencia)',
        'productos' => 'SELECT, UPDATE (stockfis, actualizado)',
        'productosprov' => 'SELECT',
        'proveedores' => 'SELECT',
        'familias' => 'SELECT',
    ];

    /** Privilegios sobre las tablas propias del TPV (TpvSchema::TABLES). */
    const PRIVILEGIOS_TPV = 'SELECT, INSERT, UPDATE, DELETE, CREATE';

    /** Cuentas que nunca se crean ni se modifican desde aquí (además del db_user de config.php). */
    const CUENTAS_RESERVADAS = [
        'root', 'mysql.sys', 'mysql.session', 'mysql.infoschema', 'mariadb.sys', 'debian-sys-maint',
    ];

    /** ER_CANNOT_USER: CREATE USER de una cuenta que existe o ALTER USER de una que no existe. */
    const ERRNO_CANNOT_USER = 1396;

    /** ER_NONEXISTING_GRANT / ER_NONEXISTING_TABLE_GRANT: REVOKE de algo que no estaba concedido. */
    const ERRNO_REVOKE_SIN_GRANT = [1141, 1147];

    /** @var string */
    public $host;

    /** @var string */
    public $password;

    /** @var bool */
    public $tls;

    /** @var string */
    public $usuario;

    public function __construct(string $usuario = 'tpv_comandero', string $host = '192.168.1.%', bool $tls = true, string $password = '')
    {
        $this->usuario = trim($usuario);
        $this->host = trim($host);
        $this->tls = $tls;
        $this->password = $password === '' ? self::generarPassword() : $password;
    }

    /**
     * Contraseña aleatoria fuerte (24 caracteres, generador criptográfico).
     * Sin comillas ni barras para que se pueda copiar a cualquier configuración.
     */
    public static function generarPassword(int $longitud = 24): string
    {
        $grupos = ['ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.!*+=@#'];
        $todos = implode('', $grupos);
        $chars = [];
        foreach ($grupos as $grupo) {
            $chars[] = $grupo[random_int(0, strlen($grupo) - 1)];
        }
        while (count($chars) < $longitud) {
            $chars[] = $todos[random_int(0, strlen($todos) - 1)];
        }

        // barajado con random_int (Fisher-Yates)
        for ($i = count($chars) - 1; $i > 0; $i--) {
            $j = random_int(0, $i);
            [$chars[$i], $chars[$j]] = [$chars[$j], $chars[$i]];
        }

        return implode('', $chars);
    }

    public static function baseDatos(): string
    {
        return (string)Tools::config('db_name', '');
    }

    /**
     * Cuenta en formato 'usuario'@'host' (los valores ya están validados por errores()).
     */
    public function cuenta(): string
    {
        return "'" . $this->usuario . "'@'" . $this->host . "'";
    }

    /**
     * Errores de validación (claves de traducción). Vacío si todo es válido.
     *
     * @return string[]
     */
    public function errores(): array
    {
        $errores = [];
        if (1 !== preg_match('/^[A-Za-z0-9_]{1,32}$/', $this->usuario)) {
            $errores[] = 'tpv-mysql-invalid-user';
        }
        if ($this->esCuentaReservada()) {
            $errores[] = 'tpv-mysql-reserved-user';
        }
        if (1 !== preg_match('/^[A-Za-z0-9.%_:\-]{1,255}$/', $this->host)) {
            $errores[] = 'tpv-mysql-invalid-host';
        }
        if (1 !== preg_match('/^[A-Za-z0-9\-_.!*+=@#]{16,64}$/', $this->password)) {
            $errores[] = 'tpv-mysql-invalid-password';
        }
        if (1 !== preg_match('/^[A-Za-z0-9_$]{1,64}$/', self::baseDatos())) {
            $errores[] = 'tpv-mysql-invalid-database';
        }

        return $errores;
    }

    /**
     * True si el usuario es el de FacturaScripts (config.php) o una cuenta del sistema.
     * Sin distinguir mayúsculas: más vale rechazar 'ROOT' que arriesgarse.
     */
    public function esCuentaReservada(): bool
    {
        $usuario = strtolower($this->usuario);
        $dbUser = strtolower(trim((string)Tools::config('db_user', '')));
        return ($dbUser !== '' && $usuario === $dbUser) || in_array($usuario, self::CUENTAS_RESERVADAS, true);
    }

    /**
     * Sentencias SQL (sin punto y coma final).
     *  - Cuenta nueva: CREATE USER (sin IF NOT EXISTS: si ya existe, falla sin tocar nada) y GRANT.
     *  - Restablecer una cuenta existente: ALTER USER (contraseña y TLS), REVOKE de los privilegios
     *    de tabla anteriores sobre estas tablas (versiones antiguas concedían de más) y GRANT.
     *
     * @return string[]
     */
    public function sentencias(bool $restablecer = false): array
    {
        $cuenta = $this->cuenta();
        $db = '`' . self::baseDatos() . '`';
        $require = $this->tls ? 'REQUIRE SSL' : 'REQUIRE NONE';
        $pass = "'" . $this->password . "'";

        $tablas = self::PRIVILEGIOS;
        foreach (TpvSchema::TABLES as $tabla) {
            $tablas[$tabla] = self::PRIVILEGIOS_TPV;
        }

        $sql = [];
        if ($restablecer) {
            $sql[] = 'ALTER USER ' . $cuenta . ' IDENTIFIED BY ' . $pass . ' ' . $require;
            foreach (array_keys($tablas) as $tabla) {
                $sql[] = 'REVOKE ALL PRIVILEGES ON ' . $db . '.`' . $tabla . '` FROM ' . $cuenta;
            }
        } else {
            $sql[] = 'CREATE USER ' . $cuenta . ' IDENTIFIED BY ' . $pass . ' ' . $require;
        }
        foreach ($tablas as $tabla => $privilegios) {
            $sql[] = 'GRANT ' . $privilegios . ' ON ' . $db . '.`' . $tabla . '` TO ' . $cuenta;
        }

        return $sql;
    }

    /**
     * Texto para copiar y pegar en un cliente de MySQL (con punto y coma).
     */
    public function script(bool $restablecer = false): string
    {
        return implode(";\n", $this->sentencias($restablecer)) . ";\n";
    }

    /**
     * Ejecuta las sentencias con una conexión propia con el usuario de config.php.
     * Si la cuenta ya existe no hace nada, salvo que $restablecer sea true.
     * Devuelve [ok, mensaje]. El mensaje nunca contiene la contraseña.
     *
     * @return array{0: bool, 1: string}
     */
    public function ejecutar(bool $restablecer = false): array
    {
        if (!empty($this->errores())) {
            return [false, Tools::trans('tpv-mysql-invalid-data')];
        }
        if ('mysql' !== strtolower((string)Tools::config('db_type', 'mysql'))) {
            return [false, Tools::trans('tpv-mysql-only')];
        }
        if (false === class_exists(mysqli::class)) {
            return [false, 'mysqli'];
        }

        $link = null;
        $modoPrevio = (new mysqli_driver())->report_mode;
        try {
            mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
            $link = new mysqli(
                (string)Tools::config('db_host', 'localhost'),
                (string)Tools::config('db_user', ''),
                (string)Tools::config('db_pass', ''),
                self::baseDatos(),
                (int)Tools::config('db_port', 3306)
            );
            return $this->ejecutarEn($link, $restablecer, $this->cuentaExiste($link));
        } catch (Throwable $e) {
            return [false, str_replace($this->password, '***', $e->getMessage())];
        } finally {
            mysqli_report($modoPrevio);
            if ($link instanceof mysqli) {
                $link->close();
            }
        }
    }

    /**
     * Ejecuta las sentencias en una conexión ya abierta (con MYSQLI_REPORT_STRICT activo).
     * $existe es el resultado de cuentaExiste(): true, false o null (no se ha podido saber).
     *
     * @return array{0: bool, 1: string}
     */
    public function ejecutarEn(mysqli $link, bool $restablecer, ?bool $existe): array
    {
        if (!empty($this->errores())) {
            return [false, Tools::trans('tpv-mysql-invalid-data')];
        }
        if ($existe === true && false === $restablecer) {
            return [false, Tools::trans('tpv-mysql-user-exists', ['%account%' => $this->cuenta()])];
        }
        // si consta que no existe, se crea aunque se pidiera restablecer
        $restablecer = $restablecer && $existe !== false;

        $sentencias = $this->sentencias($restablecer);
        $hecho = 0;
        foreach ($sentencias as $num => $sql) {
            try {
                $link->query($sql);
                $hecho++;
            } catch (mysqli_sql_exception $e) {
                $codigo = $e->getCode();
                if (0 === strpos($sql, 'REVOKE ') && in_array($codigo, self::ERRNO_REVOKE_SIN_GRANT, true)) {
                    // no tenía privilegios sobre esa tabla: nada que retirar
                    $hecho++;
                    continue;
                }
                if ($num === 0 && $codigo === self::ERRNO_CANNOT_USER) {
                    // CREATE USER de una cuenta que ya existe (no se pudo comprobar antes) o
                    // ALTER USER de una que no existe: no se ha cambiado nada
                    $clave = $restablecer ? 'tpv-mysql-user-missing' : 'tpv-mysql-user-exists';
                    return [false, Tools::trans($clave, ['%account%' => $this->cuenta()])];
                }

                return [false, Tools::trans('tpv-mysql-execute-error', [
                    '%num%' => $num + 1,
                    '%total%' => count($sentencias),
                    '%count%' => $hecho,
                    '%error%' => str_replace($this->password, '***', $e->getMessage()),
                ])];
            }
        }

        $clave = $restablecer ? 'tpv-mysql-executed-reset' : 'tpv-mysql-executed';
        return [true, Tools::trans($clave, ['%count%' => $hecho, '%account%' => $this->cuenta()])];
    }

    /**
     * ¿Existe ya la cuenta? Consulta preparada a mysql.user.
     * Null si no se puede saber (el usuario de FacturaScripts no puede leer mysql.user):
     * en ese caso CREATE USER sin IF NOT EXISTS falla si existe, así que sigue siendo seguro.
     */
    public function cuentaExiste(mysqli $link): ?bool
    {
        try {
            $stmt = $link->prepare('SELECT 1 FROM mysql.user WHERE User = ? AND Host = ?');
            if (false === $stmt) {
                return null;
            }
            $usuario = $this->usuario;
            $host = $this->host;
            $stmt->bind_param('ss', $usuario, $host);
            $stmt->execute();
            $stmt->store_result();
            $existe = $stmt->num_rows > 0;
            $stmt->close();
            return $existe;
        } catch (mysqli_sql_exception $e) {
            return null;
        }
    }
}
