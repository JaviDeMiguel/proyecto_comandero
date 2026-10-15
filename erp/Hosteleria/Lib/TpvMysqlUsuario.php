<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Tools;
use InvalidArgumentException;
use mysqli;
use mysqli_driver;
use mysqli_sql_exception;
use Throwable;

/**
 * Sentencias CREATE USER / GRANT para el usuario de MySQL del TPV, con privilegios mínimos
 * (exactamente lo que ejecuta la app, ver stock_repository.dart y escandallo_repository.dart):
 *  - stocks: SELECT, INSERT y UPDATE solo de cantidad y disponible (INSERT ... ON DUPLICATE KEY
 *    UPDATE): no puede tocar stockmin, stockmax, pterecibir ni reservada;
 *  - productos: SELECT y UPDATE solo de stockfis y actualizado;
 *  - variantes: SELECT y UPDATE solo de stockfis (no puede cambiar precios ni costes);
 *  - solo lectura en productosprov y proveedores (reaprovisionamiento);
 *  - tpv_escandallos: SELECT, INSERT, UPDATE y DELETE (la pantalla de recetas de la app);
 *  - tpv_movimientos_stock: SELECT e INSERT. Sin UPDATE ni DELETE: quien obtenga las
 *    credenciales de la tableta no puede borrar ni reescribir el diario de idempotencia.
 * Sin CREATE, DROP, ALTER, INDEX, REFERENCES ni TRIGGER: las tablas tpv_* las crea el plugin (al
 * activarse, en «Crear tablas» y antes de generar estas sentencias). MySQL 8 exige REFERENCES a
 * nivel de TABLA sobre variantes para crear la clave ajena, así que la app no las podría crear con
 * este usuario; no le hace falta (TpvSchemaMigrator solo crea las que faltan).
 *
 * Seguridad de «Ejecutar ahora»:
 *  - nunca sobre la cuenta de FacturaScripts (db_user de config.php) ni sobre cuentas del
 *    sistema (root, mysql.*, debian-sys-maint...): errores() las rechaza;
 *  - si la cuenta no existe se crea con CREATE USER (sin IF NOT EXISTS, que fallaría en silencio)
 *    y, si después falla algún GRANT, se borra (DROP USER) para no dejarla a medias;
 *  - si ya existe no se toca, salvo que se pida explícitamente restablecer su contraseña
 *    (casilla con su propia confirmación) Y la cuenta sea del TPV: solo puede tener USAGE global y
 *    privilegios sobre estas tablas de la base de datos de FacturaScripts (SHOW GRANTS). Así no se
 *    puede usar para tomar la cuenta de otra aplicación del servidor. Se retiran entonces sus
 *    privilegios sobre estas tablas (y las de versiones anteriores) y se conceden los mínimos.
 *
 * Las sentencias solo se ejecutan a petición explícita del usuario y con una conexión mysqli
 * propia (no con DataBase de FacturaScripts, que guarda el SQL en el historial y mostraría la
 * contraseña). La contraseña no se guarda en ningún sitio.
 */
final class TpvMysqlUsuario
{
    /** Privilegios por tabla (por columna donde la app solo escribe algunas). */
    const PRIVILEGIOS = [
        'stocks' => 'SELECT, INSERT, UPDATE (cantidad, disponible)',
        'variantes' => 'SELECT, UPDATE (stockfis)',
        'productos' => 'SELECT, UPDATE (stockfis, actualizado)',
        'productosprov' => 'SELECT',
        'proveedores' => 'SELECT',
        TpvSchema::TABLE_ESCANDALLOS => 'SELECT, INSERT, UPDATE, DELETE',
        TpvSchema::TABLE_MOVIMIENTOS => 'SELECT, INSERT',
    ];

    /** Tablas sobre las que versiones anteriores del plugin concedían privilegios (se revocan al restablecer). */
    const TABLAS_ANTERIORES = ['familias'];

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
     * true si SHOW GRANTS de la cuenta solo contiene USAGE global y privilegios sobre las tablas
     * del TPV (actuales o de versiones anteriores) de la base de datos de FacturaScripts.
     *
     * @param string[] $grants líneas de SHOW GRANTS
     */
    public static function esCuentaDelTpv(array $grants): bool
    {
        $tablas = array_merge(array_keys(self::PRIVILEGIOS), self::TABLAS_ANTERIORES);
        foreach ($grants as $grant) {
            $grant = trim((string)$grant);
            if (1 === preg_match('/^GRANT USAGE ON \*\.\* TO /i', $grant)) {
                continue;
            }

            if (1 !== preg_match('/^GRANT (.+?) ON `([^`]+)`\.`([^`]+)` TO /i', $grant, $m)
                || stripos($grant, 'WITH GRANT OPTION') !== false
                || $m[2] !== self::baseDatos()
                || false === in_array(strtolower($m[3]), $tablas, true)) {
                return false;
            }
        }

        return true;
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
     *  - Restablecer una cuenta del TPV: ALTER USER (contraseña y TLS), REVOKE de sus privilegios
     *    sobre estas tablas (y las de versiones anteriores) y GRANT.
     * Las tablas tpv_* deben existir (los GRANT sin CREATE no admiten tablas inexistentes).
     *
     * @return string[]
     * @throws InvalidArgumentException si los datos no son válidos (errores() no vacío)
     */
    public function sentencias(bool $restablecer = false): array
    {
        if (!empty($this->errores())) {
            throw new InvalidArgumentException('tpv-mysql-invalid-data');
        }

        $cuenta = $this->cuenta();
        $db = '`' . self::baseDatos() . '`';
        $require = $this->tls ? 'REQUIRE SSL' : 'REQUIRE NONE';
        $pass = "'" . $this->password . "'";

        $sql = [];
        if ($restablecer) {
            $sql[] = 'ALTER USER ' . $cuenta . ' IDENTIFIED BY ' . $pass . ' ' . $require;
            foreach (array_merge(array_keys(self::PRIVILEGIOS), self::TABLAS_ANTERIORES) as $tabla) {
                $sql[] = 'REVOKE ALL PRIVILEGES ON ' . $db . '.`' . $tabla . '` FROM ' . $cuenta;
            }
        } else {
            $sql[] = 'CREATE USER ' . $cuenta . ' IDENTIFIED BY ' . $pass . ' ' . $require;
        }
        foreach (self::PRIVILEGIOS as $tabla => $privilegios) {
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
     * Si la cuenta ya existe no hace nada, salvo que $restablecer sea true y sea una cuenta del TPV.
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
            return [false, Tools::trans('tpv-mysql-no-mysqli')];
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

        // restablecer solo cuentas del TPV: si no se pueden leer sus privilegios, no se toca
        if ($restablecer) {
            $grants = $this->grants($link);
            if (null === $grants) {
                return [false, Tools::trans('tpv-mysql-cannot-verify-account', ['%account%' => $this->cuenta()])];
            }
            if (false === self::esCuentaDelTpv($grants)) {
                return [false, Tools::trans('tpv-mysql-not-tpv-account', ['%account%' => $this->cuenta()])];
            }
        }

        $sentencias = $this->sentencias($restablecer);
        $hecho = 0;
        $creada = false;
        foreach ($sentencias as $num => $sql) {
            try {
                $link->query($sql);
                $hecho++;
                $creada = $creada || ($num === 0 && false === $restablecer);
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

                // una cuenta recién creada no se deja a medias (sin privilegios o con parte de ellos)
                $deshecha = $creada && $this->borrarCuenta($link);
                return [false, Tools::trans($deshecha ? 'tpv-mysql-execute-error-undone' : 'tpv-mysql-execute-error', [
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
        } catch (mysqli_sql_exception) {
            return null;
        }
    }

    private function borrarCuenta(mysqli $link): bool
    {
        try {
            $link->query('DROP USER ' . $this->cuenta());
            return true;
        } catch (mysqli_sql_exception) {
            return false;
        }
    }

    /**
     * Líneas de SHOW GRANTS de la cuenta, o null si no se pueden leer.
     *
     * @return string[]|null
     */
    private function grants(mysqli $link): ?array
    {
        try {
            $result = $link->query('SHOW GRANTS FOR ' . $this->cuenta());
            if (false === $result || true === $result) {
                return null;
            }

            $grants = [];
            while ($row = $result->fetch_row()) {
                $grants[] = (string)$row[0];
            }
            $result->free();
            return $grants;
        } catch (mysqli_sql_exception) {
            return null;
        }
    }
}
