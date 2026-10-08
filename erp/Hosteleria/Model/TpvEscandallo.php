<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Model;

use FacturaScripts\Core\DbUpdater;
use FacturaScripts\Core\Template\ModelClass;
use FacturaScripts\Core\Template\ModelTrait;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Variante;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

/**
 * Línea de receta (escandallo): cantidad NETA de un ingrediente que lleva un plato y su
 * porcentaje de merma. La cantidad BRUTA que sale del almacén es neta / (1 - merma / 100).
 *
 * Reglas (las mismas que EscandalloRepository de la app):
 *  - plato e ingrediente son referencias existentes de variantes (máx. 30 caracteres);
 *  - un plato no puede ser ingrediente de sí mismo (ni directa ni indirectamente: el plugin
 *    además impide recetas cíclicas, que el motor de escandallos de la app rechaza);
 *  - cantidad > 0 y merma en [0, 100);
 *  - un ingrediente aparece una sola vez en cada plato (UNIQUE plato + ingrediente).
 */
class TpvEscandallo extends ModelClass
{
    use ModelTrait;

    const MAX_REFERENCIA = 30;

    /** Límite de nodos al recorrer recetas anidadas (protección ante datos corruptos). */
    const MAX_NODOS = 500;

    /** @var string fecha y hora de modificación */
    public $actualizado;

    /** @var float cantidad neta del ingrediente por unidad de plato */
    public $cantidad;

    /** @var string fecha y hora de creación */
    public $creado;

    /** @var int clave primaria */
    public $id;

    /** @var float porcentaje de merma sobre el peso bruto, en [0, 100) */
    public $merma;

    /** @var string */
    public $observaciones;

    /** @var string referencia (variantes.referencia) del ingrediente o materia prima */
    public $ref_ingrediente;

    /** @var string referencia (variantes.referencia) del plato */
    public $ref_plato;

    public function __construct(array $data = [])
    {
        // la tabla se crea con el DDL canónico de la app antes de que el DbUpdater la revise
        if (false === DbUpdater::isTableChecked(static::tableName())) {
            TpvSchema::ensureTable(static::tableName());
        }

        parent::__construct($data);
    }

    /**
     * Cantidad bruta (con merma) que se descuenta del almacén por unidad de plato.
     */
    public function cantidadBruta(): float
    {
        return static::bruta((float)$this->cantidad, (float)$this->merma);
    }

    public static function bruta(float $neta, float $merma): float
    {
        if ($merma < 0 || $merma >= 100) {
            return $neta;
        }

        return $neta / (1 - $merma / 100);
    }

    public function clear(): void
    {
        parent::clear();
        $this->merma = 0.0;
    }

    /**
     * Devuelve true si añadir $refIngrediente a la receta de $refPlato crearía un ciclo
     * (el plato ya aparece, directa o indirectamente, dentro de la receta del ingrediente).
     */
    public static function createsCycle(string $refPlato, string $refIngrediente): bool
    {
        $target = mb_strtolower($refPlato);
        $pending = [$refIngrediente];
        $visited = [];

        while (!empty($pending) && count($visited) < static::MAX_NODOS) {
            $current = array_shift($pending);
            $key = mb_strtolower($current);
            if ($key === $target) {
                return true;
            }
            if (isset($visited[$key])) {
                continue;
            }
            $visited[$key] = true;

            $rows = static::table()
                ->select('ref_ingrediente')
                ->whereEq('ref_plato', $current)
                ->get();
            foreach ($rows as $row) {
                $pending[] = (string)$row['ref_ingrediente'];
            }
        }

        return false;
    }

    public function getIngrediente(): ?Variante
    {
        return static::findVariante((string)$this->ref_ingrediente);
    }

    public function getPlato(): ?Variante
    {
        return static::findVariante((string)$this->ref_plato);
    }

    public static function primaryColumn(): string
    {
        return 'id';
    }

    public function primaryDescriptionColumn(): string
    {
        return 'ref_ingrediente';
    }

    public static function tableName(): string
    {
        return 'tpv_escandallos';
    }

    public function test(): bool
    {
        $this->ref_plato = trim((string)$this->ref_plato);
        $this->ref_ingrediente = trim((string)$this->ref_ingrediente);
        $this->observaciones = static::emptyToNull(Tools::noHtml($this->observaciones));

        if (false === $this->testReferencia('ref_plato', 'tpv-dish') ||
            false === $this->testReferencia('ref_ingrediente', 'tpv-ingredient')) {
            return false;
        }

        if (mb_strtolower($this->ref_plato) === mb_strtolower($this->ref_ingrediente)) {
            Tools::log()->warning('tpv-recipe-self-ingredient', ['%ref%' => $this->ref_plato]);
            return false;
        }

        // cantidad neta > 0
        $cantidad = static::toFloat($this->cantidad);
        if (null === $cantidad || $cantidad <= 0) {
            Tools::log()->warning('tpv-recipe-invalid-quantity', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
                '%value%' => (string)$this->cantidad,
            ]);
            return false;
        }
        $this->cantidad = $cantidad;

        // merma en [0, 100)
        $merma = static::toFloat($this->merma ?? 0);
        if (null === $merma || $merma < 0 || $merma >= 100) {
            Tools::log()->warning('tpv-recipe-invalid-waste', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
                '%value%' => (string)$this->merma,
            ]);
            return false;
        }
        $this->merma = $merma;

        // un ingrediente una sola vez por plato
        $where = [
            Where::eq('ref_plato', $this->ref_plato),
            Where::eq('ref_ingrediente', $this->ref_ingrediente),
        ];
        if ($this->id) {
            $where[] = Where::notEq('id', $this->id);
        }
        if (static::count($where) > 0) {
            Tools::log()->warning('tpv-recipe-duplicate-ingredient', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
            ]);
            return false;
        }

        // sin recetas cíclicas
        if (static::createsCycle($this->ref_plato, $this->ref_ingrediente)) {
            Tools::log()->warning('tpv-recipe-cycle', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
            ]);
            return false;
        }

        // las fechas las gestiona el modelo (los formularios no pueden cambiarlas): FS reescribe la
        // fila completa y MySQL no aplica ON UPDATE CURRENT_TIMESTAMP si se asigna el valor actual
        $creado = $this->getOriginal('creado');
        if (!empty($creado)) {
            $this->creado = $creado;
        } elseif (empty($this->creado)) {
            $this->creado = Tools::dateTime();
        }
        $this->actualizado = Tools::dateTime();

        return parent::test();
    }

    private static function emptyToNull($value): ?string
    {
        if (null === $value) {
            return null;
        }

        $value = trim((string)$value);
        return '' === $value ? null : $value;
    }

    private static function findVariante(string $referencia): ?Variante
    {
        if ('' === $referencia) {
            return null;
        }

        $variante = new Variante();
        return $variante->loadWhereEq('referencia', $referencia) ? $variante : null;
    }

    private function testReferencia(string $field, string $label): bool
    {
        $value = (string)$this->{$field};
        if ('' === $value) {
            Tools::log()->warning('field-can-not-be-null', ['%fieldName%' => Tools::trans($label), '%tableName%' => static::tableName()]);
            return false;
        }

        if (mb_strlen($value) > static::MAX_REFERENCIA) {
            Tools::log()->warning('tpv-reference-too-long', ['%ref%' => $value, '%max%' => static::MAX_REFERENCIA]);
            return false;
        }

        $variante = static::findVariante($value);
        if (null === $variante) {
            Tools::log()->warning('tpv-reference-not-found', ['%ref%' => $value]);
            return false;
        }

        // guardamos la referencia tal y como está en variantes (la collation no distingue mayúsculas)
        $this->{$field} = $variante->referencia;
        return true;
    }

    private static function toFloat($value): ?float
    {
        if (is_string($value)) {
            $value = str_replace(',', '.', trim($value));
        }

        if (false === is_numeric($value)) {
            return null;
        }

        $number = (float)$value;
        return is_finite($number) ? $number : null;
    }
}
