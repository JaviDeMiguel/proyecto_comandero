<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 *
 * ERP de hostelería contra el que trabaja el TPV/comandero (proyecto_comandero).
 */

namespace FacturaScripts\Plugins\Hosteleria;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Model\Role;
use FacturaScripts\Core\Model\RoleAccess;
use FacturaScripts\Core\Template\InitClass;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Familia;
use FacturaScripts\Dinamic\Model\TpvEscandallo;
use FacturaScripts\Dinamic\Model\TpvMovimientoStock;
use FacturaScripts\Dinamic\Model\Variante;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

final class Init extends InitClass
{
    /** Rol con acceso a las páginas del plugin (para usuarios no administradores). */
    const ROLE_NAME = 'Hosteleria';

    /**
     * Páginas del plugin que se añaden al rol. Los módulos posteriores añaden aquí sus
     * controladores. ConfigurarTpv NO está: solo la usan administradores (muestra la clave de
     * la API y puede crear usuarios de MySQL).
     */
    const PAGES = [
        'EditTpvEscandallo',
        'ListTpvCierreZ',
        'ListTpvEscandallo',
        'ListTpvMovimientoStock',
        'ListTpvTicket',
    ];

    public function init(): void
    {
        $this->loadExtension(new Extension\Controller\EditFamilia());
        $this->loadExtension(new Extension\Controller\EditProducto());
        $this->loadExtension(new Extension\Controller\ListFamilia());
        $this->loadExtension(new Extension\Model\Familia());
    }

    public function uninstall(): void
    {
        // No se borran tablas ni columnas: tpv_escandallos, tpv_movimientos_stock y
        // familias.tpv_destino pertenecen también a la app del TPV.
    }

    /**
     * Se ejecuta al activar o actualizar el plugin. Todo lo que hace es idempotente.
     */
    public function update(): void
    {
        // tablas del núcleo de las que dependemos; familias recibe la columna tpv_destino
        new Variante();
        new Familia();

        // tablas propias con el DDL canónico de la app (CREATE TABLE IF NOT EXISTS) y
        // comprobación posterior del DbUpdater contra Table/*.xml (no debe cambiar nada)
        TpvSchema::ensureAll();
        new TpvEscandallo();
        new TpvMovimientoStock();

        $this->createRole();
    }

    private function createRole(): void
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
                return;
            }
        }

        foreach (self::PAGES as $pageName) {
            $access = new RoleAccess();
            $where = [
                Where::eq('codrole', self::ROLE_NAME),
                Where::eq('pagename', $pageName),
            ];
            if ($access->loadWhere($where)) {
                continue;
            }

            $access->allowdelete = true;
            $access->allowupdate = true;
            $access->codrole = self::ROLE_NAME;
            $access->pagename = $pageName;
            $access->onlyownerdata = false;
            if (false === $access->save()) {
                $dataBase->rollback();
                Tools::log()->warning('tpv-role-save-error');
                return;
            }
        }

        $dataBase->commit();
    }
}
