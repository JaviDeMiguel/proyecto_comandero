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
use FacturaScripts\Plugins\Hosteleria\Lib\TpvCosteEscandallo;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvGrafoRecetas;
use FacturaScripts\Plugins\Hosteleria\Lib\TpvSchema;

/**
 * Línea de receta (escandallo): cantidad NETA de un ingrediente que lleva un plato y su
 * porcentaje de merma. La cantidad BRUTA que sale del almacén es neta / (1 - merma / 100).
 *
 * Reglas (las mismas que EscandalloRepository y el motor de escandallos de la app):
 *  - plato e ingrediente son referencias existentes de variantes (máx. 30 caracteres), que se
 *    guardan tal como están en variantes (el motor de la app distingue mayúsculas);
 *  - un plato no puede ser ingrediente de sí mismo, ni directa ni indirectamente (ciclo);
 *  - una cadena de subrecetas no puede pasar de TpvGrafoRecetas::MAX_PROFUNDIDAD platos;
 *  - cantidad > 0 y merma en [0, 100);
 *  - un ingrediente aparece una sola vez en cada plato (UNIQUE plato + ingrediente).
 * Un ciclo o una cadena demasiado larga harían que la app rechazase el grafo COMPLETO y dejase de
 * descontar stock de todas las ventas.
 *
 * Atributos calculados (TpvCosteEscandallo::decorar, o al leerlos por primera vez, p. ej. al
 * exportar):
 *
 * @property float|null  $cantidad_bruta          cantidad bruta por unidad de plato
 * @property float|null  $coste_linea             cantidad bruta × coste unitario
 * @property string|null $coste_origen            ficha, receta, receta-incompleta, receta-invalida o sin-coste
 * @property float|null  $coste_unitario          coste del ingrediente (de su receta si la tiene)
 * @property float|null  $descuento_tpv           lo que descuenta el TPV (null si el ingrediente tiene receta)
 * @property string|null $ingrediente_descripcion
 * @property int|null    $ingrediente_idproducto
 * @property string|null $plato_descripcion
 * @property int|null    $plato_idproducto
 */
class TpvEscandallo extends ModelClass
{
    use ModelTrait;

    /** Atributos que calcula TpvCosteEscandallo::decorar(). */
    const CALCULADOS = [
        'cantidad_bruta', 'coste_linea', 'coste_origen', 'coste_unitario', 'descuento_tpv',
        'ingrediente_descripcion', 'ingrediente_idproducto', 'plato_descripcion', 'plato_idproducto',
    ];

    /** Decimales con los que la app descuenta el stock (StockRepository.round3). */
    const DECIMALES_STOCK = 3;

    const MAX_REFERENCIA = 30;

    /** Avisos de redondeo como máximo al guardar una línea. */
    const MAX_AVISOS_REDONDEO = 10;

    /** Diferencia relativa a partir de la cual se avisa del redondeo del descuento del TPV. */
    const TOLERANCIA_REDONDEO = 0.05;

    /** @var TpvCosteEscandallo|null calculadora compartida para los atributos perezosos */
    private static $costes = null;

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

    /**
     * Cantidad bruta (con merma) que se descuenta del almacén por unidad de plato.
     */
    public function cantidadBruta(): float
    {
        return static::bruta((float)$this->cantidad, (float)$this->merma);
    }

    public static function bruta(float $neta, float $merma): float
    {
        return TpvGrafoRecetas::bruta($neta, $merma);
    }

    public function clear(): void
    {
        $this->olvidarCalculados();
        parent::clear();
        $this->merma = 0.0;
    }

    public function loadFromData(array $data = [], array $exclude = [], bool $sync = true): void
    {
        $this->olvidarCalculados();
        parent::loadFromData($data, $exclude, $sync);
    }

    /**
     * Devuelve true si añadir $refIngrediente a la receta de $refPlato crearía un ciclo
     * (el plato ya aparece, directa o indirectamente, dentro de la receta del ingrediente).
     */
    public static function createsCycle(string $refPlato, string $refIngrediente): bool
    {
        return null !== TpvGrafoRecetas::cargar()->camino($refIngrediente, $refPlato);
    }

    public function delete(): bool
    {
        if (false === parent::delete()) {
            return false;
        }

        self::$costes = null;
        return true;
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

    /**
     * «PLATO › INGREDIENTE» (título de la ficha de la línea).
     */
    public function primaryDescription()
    {
        return $this->ref_plato . ' › ' . $this->ref_ingrediente;
    }

    public function primaryDescriptionColumn(): string
    {
        return 'ref_ingrediente';
    }

    public function save(): bool
    {
        if (false === parent::save()) {
            return false;
        }

        // los costes y grafos ya calculados en esta petición dejan de valer
        self::$costes = null;
        return true;
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

        // grafo de recetas válido para el motor de la app: sin ciclos ni cadenas demasiado largas
        $grafo = $this->testGrafo();
        if (null === $grafo) {
            return false;
        }

        $this->avisarRedondeoTpv($grafo);

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

    /**
     * Avisa (sin impedir el guardado) si, al vender una unidad de un plato, el TPV va a descontar
     * de alguna materia prima una cantidad muy distinta de la exacta. La app expande el plato hasta
     * sus hojas, suma por hoja y redondea a 3 decimales (0,0044 kg de ajo se quedan en 0,004, -10 %;
     * menos de 0,0005 no se descuenta). Se revisan las hojas a las que llega esta línea, en este
     * plato y en los que lo usan como semielaborado.
     */
    private function avisarRedondeoTpv(TpvGrafoRecetas $grafo): void
    {
        $hojasLinea = array_keys($grafo->hojasPorUnidad($this->ref_ingrediente) ?? []);

        // el plato y todos los que lo usan, directa o indirectamente
        $platos = [$this->ref_plato => true];
        $pendientes = [$this->ref_plato];
        while (!empty($pendientes)) {
            foreach ($grafo->usosDe(array_shift($pendientes)) as $usuario) {
                if (false === isset($platos[$usuario])) {
                    $platos[$usuario] = true;
                    $pendientes[] = $usuario;
                }
            }
        }

        $avisos = 0;
        foreach (array_keys($platos) as $plato) {
            $hojas = $grafo->hojasPorUnidad((string)$plato) ?? [];
            foreach ($hojasLinea as $hoja) {
                $exacta = $hojas[$hoja] ?? 0.0;
                if ($exacta <= 0 || $avisos >= self::MAX_AVISOS_REDONDEO) {
                    continue;
                }

                $tpv = round($exacta, self::DECIMALES_STOCK);
                $diferencia = abs($tpv - $exacta) / $exacta;
                if ($tpv > 0 && $diferencia <= self::TOLERANCIA_REDONDEO) {
                    continue;
                }

                $params = [
                    '%ingredient%' => $hoja,
                    '%dish%' => $plato,
                    '%gross%' => Tools::number($exacta, self::decimalesSignificativos($exacta)),
                    '%tpv%' => Tools::number($tpv, self::DECIMALES_STOCK),
                    '%pct%' => Tools::number(100 * $diferencia, 1),
                ];
                Tools::log()->warning($tpv > 0 ? 'tpv-recipe-stock-rounding' : 'tpv-recipe-below-stock-precision', $params);
                $avisos++;
            }
        }
    }

    /**
     * Decimales para mostrar una cantidad pequeña sin ceros de relleno (entre 3 y 6).
     */
    private static function decimalesSignificativos(float $valor): int
    {
        $decimales = 6;
        while ($decimales > self::DECIMALES_STOCK && round($valor, $decimales - 1) == round($valor, $decimales)) {
            $decimales--;
        }

        return $decimales;
    }

    /**
     * Olvida los atributos calculados (al limpiar o cargar otro registro en la misma instancia).
     */
    private function olvidarCalculados(): void
    {
        foreach (self::CALCULADOS as $key) {
            unset($this->attributes[$key]);
        }
    }

    /**
     * Calcula los atributos de coste y descripciones de esta línea (atributos perezosos: la
     * exportación a PDF/Excel vuelve a leer las líneas sin pasar por el controlador).
     */
    private function calcular(): void
    {
        foreach (self::CALCULADOS as $key) {
            // evita la recursión si decorar() lee algún atributo aún no asignado
            $this->attributes[$key] = null;
        }

        if (null === $this->id) {
            return;
        }

        if (null === self::$costes) {
            self::$costes = new TpvCosteEscandallo();
        }
        self::$costes->decorar([$this]);
    }

    private static function emptyToNull(mixed $value): ?string
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

    /**
     * La línea no puede crear un ciclo ni una cadena de más de TpvGrafoRecetas::MAX_PROFUNDIDAD
     * platos con receta. Solo se comprueban las cadenas que pasan por esta línea: una receta ya
     * corrupta (p. ej. guardada desde la app) no impide corregir las demás; la señala el asistente.
     *
     * @return TpvGrafoRecetas|null el grafo con la línea ya puesta, o null si no es válida
     */
    private function testGrafo(): ?TpvGrafoRecetas
    {
        $grafo = TpvGrafoRecetas::cargar();
        if ($this->id) {
            $grafo->quitar((string)$this->getOriginal('ref_plato'), (string)$this->getOriginal('ref_ingrediente'));
        }

        $ciclo = $grafo->camino($this->ref_ingrediente, $this->ref_plato);
        if (null !== $ciclo) {
            Tools::log()->warning('tpv-recipe-cycle', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
                '%path%' => implode(' → ', array_merge([$this->ref_plato], $ciclo)),
            ]);
            return null;
        }

        $grafo->poner($this->ref_plato, $this->ref_ingrediente, (float)$this->cantidad, (float)$this->merma);
        $niveles = $grafo->alturaArriba($this->ref_plato) + $grafo->altura($this->ref_ingrediente);
        if ($niveles > TpvGrafoRecetas::MAX_PROFUNDIDAD) {
            Tools::log()->warning('tpv-recipe-too-deep', [
                '%ingredient%' => $this->ref_ingrediente,
                '%dish%' => $this->ref_plato,
                '%levels%' => $niveles,
                '%max%' => TpvGrafoRecetas::MAX_PROFUNDIDAD,
            ]);
            return null;
        }

        return $grafo;
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

    private static function toFloat(mixed $value): ?float
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
