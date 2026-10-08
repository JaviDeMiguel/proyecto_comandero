<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model;

use FacturaScripts\Core\DbUpdater;
use FacturaScripts\Core\Template\ModelClass;
use FacturaScripts\Core\Template\ModelTrait;
use FacturaScripts\Core\Tools;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

/**
 * Movimiento del diario de stock del TPV.
 *
 * El TPV descuenta (cantidad > 0) o devuelve (cantidad < 0) materias primas por SQL directo
 * dentro de una transacción y apunta aquí cada referencia. El UNIQUE (operacion, referencia,
 * codalmacen) es su garantía de idempotencia, así que desde FacturaScripts el diario es de
 * SOLO LECTURA: el modelo rechaza altas, cambios y borrados.
 */
class TpvMovimientoStock extends ModelClass
{
    use ModelTrait;

    /** @var float cantidad bruta: positiva = consumo (resta stock), negativa = devolución */
    public $cantidad;

    /** @var string almacén afectado */
    public $codalmacen;

    /** @var string fecha y hora en la que el TPV aplicó el movimiento */
    public $creado;

    /** @var int clave primaria */
    public $id;

    /** @var string motivo: comanda, anulacion... */
    public $motivo;

    /** @var string clave idempotente de la operación (id de línea de comanda, "<id>:anulacion"...) */
    public $operacion;

    /** @var string descripción legible del origen (mesa y línea) */
    public $origen;

    /** @var string referencia (variantes.referencia) de la materia prima */
    public $referencia;

    public function __construct(array $data = [])
    {
        // la tabla se crea con el DDL canónico de la app antes de que el DbUpdater la revise
        if (false === DbUpdater::isTableChecked(static::tableName())) {
            TpvSchema::ensureTable(static::tableName());
        }

        parent::__construct($data);
    }

    public function delete(): bool
    {
        Tools::log()->warning('tpv-stock-journal-read-only');
        return false;
    }

    /**
     * true si el movimiento es una devolución al almacén (anulación).
     */
    public function isDevolucion(): bool
    {
        return (float)$this->cantidad < 0;
    }

    public static function primaryColumn(): string
    {
        return 'id';
    }

    public function primaryDescriptionColumn(): string
    {
        return 'operacion';
    }

    public function save(): bool
    {
        Tools::log()->warning('tpv-stock-journal-read-only');
        return false;
    }

    public static function tableName(): string
    {
        return 'tpv_movimientos_stock';
    }

    public function update(array $values): bool
    {
        Tools::log()->warning('tpv-stock-journal-read-only');
        return false;
    }

    public function url(string $type = 'auto', string $list = 'List'): string
    {
        // no hay ficha de edición: cualquier enlace lleva al listado
        return 'ListTpvMovimientoStock';
    }
}
