<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 *
 * ERP de hostelería contra el que trabaja el TPV/comandero (proyecto_comandero).
 */

namespace FacturaScripts\Plugins\Hosteleria;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Template\InitClass;
use FacturaScripts\Core\Tools;
use FacturaScripts\Dinamic\Model\Familia;
use FacturaScripts\Dinamic\Model\TpvEscandallo;
use FacturaScripts\Dinamic\Model\TpvMovimientoStock;
use FacturaScripts\Dinamic\Model\Variante;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvRol;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

final class Init extends InitClass
{
    /** Rol con acceso a las páginas del plugin (para usuarios no administradores). */
    const ROLE_NAME = TpvRol::ROLE_NAME;

    /** Páginas del plugin que se añaden al rol (ver Lib/TpvRol). */
    const PAGES = TpvRol::PAGES;

    public function init(): void
    {
        $this->loadExtension(new Extension\Controller\EditFamilia());
        $this->loadExtension(new Extension\Controller\EditProducto());
        $this->loadExtension(new Extension\Controller\ListFamilia());
        $this->loadExtension(new Extension\Model\FacturaCliente());
        $this->loadExtension(new Extension\Model\Familia());
        $this->loadExtension(new Extension\Model\Producto());
        $this->loadExtension(new Extension\Model\Variante());
    }

    public function uninstall(): void
    {
        // No se borran tablas ni columnas: tpv_escandallos, tpv_movimientos_stock y
        // familias.tpv_destino pertenecen también a la app del TPV.
    }

    /**
     * Se ejecuta al activar el plugin (y al subir su ZIP con el plugin activo). Copiar los ficheros
     * a mano no lo ejecuta: en ese caso hay que pulsar «Reconstruir» en Plugins y reparar el rol
     * desde «Configurar TPV» (o desactivar y activar el plugin). Todo lo que hace es idempotente.
     */
    public function update(): void
    {
        // la app del TPV solo trabaja con MySQL / MariaDB (DDL propio, SQL directo)
        $db = new DataBase();
        $db->connect();
        if ('mysql' !== strtolower($db->type())) {
            Tools::log()->error('tpv-mysql-only');
            return;
        }

        // tablas del núcleo de las que dependemos; familias recibe la columna tpv_destino
        new Variante();
        new Familia();

        // tablas propias con el DDL canónico de la app (CREATE TABLE IF NOT EXISTS) y
        // comprobación posterior del DbUpdater contra Table/*.xml (no debe cambiar nada)
        TpvSchema::ensureAll();
        new TpvEscandallo();
        new TpvMovimientoStock();

        TpvRol::crear();
    }
}
