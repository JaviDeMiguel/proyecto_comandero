<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Model\Role;
use FacturaScripts\Core\Model\RoleAccess;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;

/**
 * Rol «Hosteleria»: acceso a las páginas del plugin para usuarios no administradores.
 *
 * Lo crea Init::update() (que el núcleo solo ejecuta al activar el plugin o al subir su ZIP) y lo
 * repara el asistente: al actualizar el plugin copiando ficheros, las páginas nuevas no llegan al
 * rol hasta pulsar «Reparar el rol» o desactivar y activar el plugin.
 *
 * El rol no da acceso a las fichas del núcleo (productos, familias, facturas, asientos): se asigna
 * junto con otro rol que las incluya; mientras tanto los enlaces a esas fichas no se muestran.
 * ConfigurarTpv no está: solo la usan administradores (muestra la clave de la API y puede crear
 * usuarios de MySQL).
 */
final class TpvRol
{
    const ROLE_NAME = 'Hosteleria';

    /** Páginas del plugin que se añaden al rol. */
    const PAGES = [
        'EditTpvEscandallo',
        'ListTpvCierreZ',
        'ListTpvEscandallo',
        'ListTpvMovimientoStock',
        'ListTpvPedidoReposicion',
        'ListTpvStock',
        'ListTpvTicket',
    ];

    /**
     * Crea el rol y le añade las páginas que le falten (no toca los permisos ya existentes).
     */
    public static function crear(): bool
    {
        new Role();
        new RoleAccess();

        $dataBase = new DataBase();
        $dataBase->beginTransaction();

        $role = new Role();
        if (false === $role->load(self::ROLE_NAME)) {
            $role->codrole = self::ROLE_NAME;
            $role->descripcion = 'Hostelería (TPV)';
            if (false === $role->save()) {
                $dataBase->rollback();
                Tools::log()->warning('tpv-role-save-error');
                return false;
            }
        }

        foreach (self::paginasQueFaltan() as $pageName) {
            $access = new RoleAccess();
            $access->allowdelete = true;
            $access->allowupdate = true;
            $access->codrole = self::ROLE_NAME;
            $access->pagename = $pageName;
            $access->onlyownerdata = false;
            if (false === $access->save()) {
                $dataBase->rollback();
                Tools::log()->warning('tpv-role-save-error');
                return false;
            }
        }

        $dataBase->commit();
        return true;
    }

    /**
     * Páginas del plugin que el rol aún no tiene (todas si el rol no existe).
     *
     * @return string[]
     */
    public static function paginasQueFaltan(): array
    {
        $faltan = [];
        foreach (self::PAGES as $pageName) {
            $access = new RoleAccess();
            $where = [
                Where::eq('codrole', self::ROLE_NAME),
                Where::eq('pagename', $pageName),
            ];
            if (false === $access->loadWhere($where)) {
                $faltan[] = $pageName;
            }
        }

        return $faltan;
    }
}
