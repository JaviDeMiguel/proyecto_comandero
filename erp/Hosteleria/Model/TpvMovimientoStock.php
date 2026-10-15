<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model;

use FacturaScripts\Core\DbUpdater;
use FacturaScripts\Core\Template\ModelClass;
use FacturaScripts\Core\Template\ModelTrait;
use FacturaScripts\Core\Tools;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCatalogo;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

/**
 * Movimiento del diario de stock del TPV.
 *
 * El TPV descuenta o devuelve materias primas por SQL directo dentro de una transacción y apunta
 * aquí cada referencia con la VARIACIÓN que ha sumado a stocks.cantidad (StockRepository de la
 * app: delta = -consumo): negativa = consumo de una comanda, positiva = devolución de una
 * anulación. El UNIQUE (operacion, referencia, codalmacen) es su garantía de idempotencia, así
 * que desde FacturaScripts el diario es de SOLO LECTURA: el modelo rechaza altas, cambios y
 * borrados (la única excepción es seguir el renombrado de una referencia, ver
 * Extension/Model/Variante).
 *
 * También se apuntan las referencias «no controlar stock» aunque no se descuenten (la app las
 * omite con un aviso).
 *
 * descripcion e idproducto no son columnas: se leen de variantes y productos cuando se piden
 * (atributos perezosos, también al exportar). Una referencia que ya no existe (el diario no tiene
 * FK) se queda sin ellos.
 *
 * @property string|null $descripcion
 * @property int|null    $idproducto
 */
class TpvMovimientoStock extends ModelClass
{
    use ModelTrait;

    /** Atributos que no son columnas: se calculan al pedirlos (ver calcular()). */
    const CALCULADOS = ['descripcion', 'idproducto'];

    /** Motivos que escribe la app (StockService). */
    const MOTIVO_ANULACION = 'anulacion';
    const MOTIVO_COMANDA = 'comanda';

    /** @var array<string, ?array> clave de referencia => fila de TpvCatalogo (null si no existe) */
    private static $catalogo = [];

    /** @var float variación aplicada a stocks.cantidad: negativa = consumo, positiva = devolución */
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

    public function __get(string $key)
    {
        if (in_array($key, self::CALCULADOS, true) && false === array_key_exists($key, $this->attributes)) {
            $this->calcular();
        }

        return parent::__get($key);
    }

    public function __isset(string $key): bool
    {
        if (in_array($key, self::CALCULADOS, true) && false === array_key_exists($key, $this->attributes)) {
            $this->calcular();
        }

        return parent::__isset($key);
    }

    public function clear(): void
    {
        $this->olvidarCalculados();
        parent::clear();
    }

    public function delete(): bool
    {
        Tools::log()->warning('tpv-stock-journal-read-only');
        return false;
    }

    /**
     * Cantidad consumida (positiva) o devuelta (negativa): la variación con el signo cambiado.
     */
    public function consumo(): float
    {
        return -(float)$this->cantidad;
    }

    /**
     * true si el movimiento devuelve stock al almacén (anulación de una línea).
     */
    public function isDevolucion(): bool
    {
        return (float)$this->cantidad > 0;
    }

    public function loadFromData(array $data = [], array $exclude = [], bool $sync = true): void
    {
        $this->olvidarCalculados();
        parent::loadFromData($data, $exclude, $sync);
    }

    /**
     * Lee en una sola consulta las referencias de $movimientos que aún no se conocen (el listado
     * la llama con las filas de la página; sin ella, cada referencia nueva hace su consulta).
     *
     * @param TpvMovimientoStock[] $movimientos
     */
    public static function precargar(array $movimientos): void
    {
        $faltan = [];
        foreach ($movimientos as $movimiento) {
            $referencia = (string)$movimiento->referencia;
            if (false === array_key_exists(TpvCatalogo::clave($referencia), self::$catalogo)) {
                $faltan[TpvCatalogo::clave($referencia)] = $referencia;
            }
        }
        if (empty($faltan)) {
            return;
        }

        $datos = TpvCatalogo::variantes($faltan);
        foreach ($faltan as $clave => $referencia) {
            self::$catalogo[$clave] = TpvCatalogo::fila($datos, $referencia);
        }
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

    private function calcular(): void
    {
        self::precargar([$this]);
        $fila = self::$catalogo[TpvCatalogo::clave((string)$this->referencia)] ?? null;
        $this->attributes['descripcion'] = $fila['descripcion'] ?? null;
        $this->attributes['idproducto'] = $fila['idproducto'] ?? null;
    }

    private function olvidarCalculados(): void
    {
        foreach (self::CALCULADOS as $key) {
            unset($this->attributes[$key]);
        }
    }
}
