<?php
/**
 * This file is part of Hosteleria plugin for FacturaScripts.
 */

namespace FacturaScripts\Plugins\Hosteleria\Lib;

use FacturaScripts\Core\Base\DataBase;
use FacturaScripts\Core\Model\Impuesto as CoreImpuesto;
use FacturaScripts\Core\Tools;
use FacturaScripts\Core\Where;
use FacturaScripts\Dinamic\Model\Almacen;
use FacturaScripts\Dinamic\Model\Familia;
use FacturaScripts\Dinamic\Model\Impuesto;
use FacturaScripts\Dinamic\Model\Producto;
use FacturaScripts\Dinamic\Model\ProductoProveedor;
use FacturaScripts\Dinamic\Model\Proveedor;
use FacturaScripts\Dinamic\Model\Stock;
use FacturaScripts\Dinamic\Model\TpvEscandallo;
use FacturaScripts\Dinamic\Model\Variante;
use Throwable;

/**
 * Carta de ejemplo de un restaurante de La Mancha: familias con destino cocina / barra,
 * productos de carta, materias primas con stock, proveedores con sus precios y escandallos.
 *
 * Idempotente por códigos y referencias, y nunca toca datos que ya existan:
 *  - una familia, proveedor o referencia que ya existe se deja tal cual (se cuenta como "ya existía");
 *  - stock, precios de proveedor y escandallo solo se crean para los productos creados en esta carga;
 *  - todo va en una transacción: si algo falla no queda nada a medias.
 *
 * Precios de venta con IVA del 10 % (hostelería): el precio neto se guarda con 5 decimales para
 * que el PVP con IVA sea exacto (2,50 → 2,27273). Las materias primas llevan el IVA de compra.
 *
 * IVA de los envasados: FacturaScripts guarda un solo codimpuesto por producto y lo usa tanto al
 * vender como al comprar (crearPedidoProveedor toma el del producto si la línea no lo trae, y la
 * app no lo envía). El agua tributa al 10 % en la compra y en la venta, así que lleva proveedor y
 * entra en la reposición automática. Los refrescos con azúcares o edulcorantes añadidos se venden
 * en sala al 10 % (servicio de hostelería) pero su compra tributa al 21 % (Ley 11/2020): por eso
 * NO se les asigna proveedor (sin fila en productosprov): la reposición de la app los avisa como
 * "bajo mínimo sin proveedor" y su pedido se hace a mano en FacturaScripts con IVA 21 % en esas
 * líneas.
 */
final class TpvCartaEjemplo
{
    const PLATO = 'plato';
    const ENVASADO = 'envasado';
    const MATERIA = 'materia';

    /** codfamilia => [descripción, madre, tpv_destino] (las madres van antes que las hijas). */
    const FAMILIAS = [
        'BEB' => ['Bebidas', null, 'barra'],
        'BEBREF' => ['Refrescos', 'BEB', null],
        'BEBAGU' => ['Aguas', 'BEB', null],
        'BEBCER' => ['Cervezas', 'BEB', null],
        'BEBVIN' => ['Vinos', 'BEB', null],
        'BEBCAF' => ['Cafés e infusiones', 'BEB', null],
        'COC' => ['Cocina', null, 'cocina'],
        'COCENT' => ['Entrantes', 'COC', null],
        'COCRAC' => ['Raciones', 'COC', null],
        'COCPRI' => ['Principales', 'COC', null],
        'COCPOS' => ['Postres', 'COC', null],
        'MATPRI' => ['Materias primas', null, null],
    ];

    /**
     * Productos que se venden: referencia => [descripción, familia, PVP con IVA 10 %, tipo].
     * Platos y bebidas de receta: "no controlar stock". Envasados: con stock (ver STOCK).
     */
    const CARTA = [
        // refrescos y aguas envasados: se venden tal cual y llevan stock
        'BEB-COLA-LATA' => ['Refresco de cola (lata 33 cl)', 'BEBREF', 2.20, self::ENVASADO],
        'BEB-NARANJA-LATA' => ['Refresco de naranja (lata 33 cl)', 'BEBREF', 2.20, self::ENVASADO],
        'BEB-LIMON-LATA' => ['Refresco de limón (lata 33 cl)', 'BEBREF', 2.20, self::ENVASADO],
        'BEB-TONICA' => ['Tónica (botellín 20 cl)', 'BEBREF', 2.30, self::ENVASADO],
        'BEB-AGUA-50' => ['Agua mineral (50 cl)', 'BEBAGU', 1.60, self::ENVASADO],
        'BEB-AGUA-GAS' => ['Agua con gas (50 cl)', 'BEBAGU', 1.90, self::ENVASADO],
        // bebidas de barra con escandallo
        'BEB-CANA' => ['Caña de cerveza (barril)', 'BEBCER', 1.80, self::PLATO],
        'BEB-DOBLE' => ['Doble de cerveza (barril)', 'BEBCER', 2.50, self::PLATO],
        'BEB-COPA-TINTO' => ['Copa de vino tinto D.O. La Mancha', 'BEBVIN', 2.50, self::PLATO],
        'BEB-COPA-BLANCO' => ['Copa de vino blanco Airén', 'BEBVIN', 2.50, self::PLATO],
        'BEB-CAFE-SOLO' => ['Café solo', 'BEBCAF', 1.30, self::PLATO],
        'BEB-CORTADO' => ['Café cortado', 'BEBCAF', 1.40, self::PLATO],
        'BEB-CAFE-LECHE' => ['Café con leche', 'BEBCAF', 1.60, self::PLATO],
        'BEB-INFUSION' => ['Infusión', 'BEBCAF', 1.50, self::PLATO],
        // cocina
        'PLA-GAZPACHO' => ['Gazpacho de la casa', 'COCENT', 4.50, self::PLATO],
        'PLA-QUESO' => ['Queso manchego curado (ración)', 'COCENT', 12.00, self::PLATO],
        'PLA-JAMON' => ['Jamón serrano (ración)', 'COCENT', 14.00, self::PLATO],
        'PLA-CROQUETAS' => ['Croquetas caseras de jamón (6 uds.)', 'COCRAC', 8.50, self::PLATO],
        'PLA-CALAMARES' => ['Calamares a la romana', 'COCRAC', 11.00, self::PLATO],
        'PLA-TORTILLA' => ['Tortilla de patatas (ración)', 'COCRAC', 6.50, self::PLATO],
        'PLA-BRAVAS' => ['Patatas bravas', 'COCRAC', 5.50, self::PLATO],
        'PLA-MIGAS' => ['Migas manchegas', 'COCRAC', 9.00, self::PLATO],
        'PLA-PAELLA' => ['Paella mixta (ración)', 'COCPRI', 12.00, self::PLATO],
        'PLA-PISTO' => ['Pisto manchego con huevo', 'COCPRI', 9.50, self::PLATO],
        'PLA-POLLO-AJILLO' => ['Pollo al ajillo', 'COCPRI', 11.50, self::PLATO],
        'PLA-CHULETAS' => ['Chuletas de cordero con patatas', 'COCPRI', 16.50, self::PLATO],
        'PLA-FLAN' => ['Flan de huevo casero', 'COCPOS', 4.50, self::PLATO],
        'PLA-TARTA-QUESO' => ['Tarta de queso manchego', 'COCPOS', 5.50, self::PLATO],
        'PLA-ARROZ-LECHE' => ['Arroz con leche', 'COCPOS', 4.50, self::PLATO],
    ];

    /**
     * Materias primas (no se venden, se compran, con stock): referencia => [descripción, IVA de compra %].
     */
    const MATERIAS = [
        'MP-ARROZ' => ['Arroz redondo (kg)', 4],
        'MP-POLLO' => ['Pollo de corral troceado (kg)', 10],
        'MP-CALAMAR' => ['Calamar fresco (kg)', 10],
        'MP-CORDERO' => ['Chuletas de cordero manchego (kg)', 10],
        'MP-JAMON' => ['Jamón serrano (kg)', 10],
        'MP-CHORIZO' => ['Chorizo (kg)', 10],
        'MP-QUESO' => ['Queso manchego curado D.O.P. (kg)', 4],
        'MP-HUEVO' => ['Huevo de gallina M (ud)', 4],
        'MP-LECHE' => ['Leche entera (l)', 4],
        'MP-HARINA' => ['Harina de trigo (kg)', 4],
        'MP-PAN' => ['Pan del día (kg)', 4],
        'MP-ACEITE' => ['Aceite de oliva virgen extra (l)', 4],
        'MP-TOMATE' => ['Tomate (kg)', 4],
        'MP-PIMIENTO-VERDE' => ['Pimiento verde (kg)', 4],
        'MP-PIMIENTO-ROJO' => ['Pimiento rojo (kg)', 4],
        'MP-CALABACIN' => ['Calabacín (kg)', 4],
        'MP-CEBOLLA' => ['Cebolla (kg)', 4],
        'MP-AJO' => ['Ajo morado (kg)', 4],
        'MP-PATATA' => ['Patata (kg)', 4],
        'MP-AZUCAR' => ['Azúcar (kg)', 10],
        'MP-CAFE' => ['Café en grano (kg)', 10],
        'MP-INFUSION' => ['Infusión en sobre (ud)', 10],
        'MP-CERVEZA-BARRIL' => ['Cerveza de barril (l)', 21],
        'MP-VINO-TINTO' => ['Vino tinto D.O. La Mancha (l)', 21],
        'MP-VINO-BLANCO' => ['Vino blanco Airén D.O. La Mancha (l)', 21],
    ];

    /**
     * Stock en el almacén por defecto: referencia => [coste neto, cantidad, mínimo, máximo].
     * Algunas quedan por debajo del mínimo para que la reposición proponga pedidos.
     */
    const STOCK = [
        'MP-ARROZ' => [2.40, 18, 8, 40],
        'MP-POLLO' => [4.90, 12, 6, 25],
        'MP-CALAMAR' => [9.50, 2, 4, 15],          // bajo mínimo
        'MP-CORDERO' => [14.50, 8, 4, 16],
        'MP-JAMON' => [16.00, 6, 3, 10],
        'MP-CHORIZO' => [8.50, 3, 2, 6],
        'MP-QUESO' => [15.50, 5, 3, 10],
        'MP-HUEVO' => [0.20, 40, 60, 240],         // bajo mínimo
        'MP-LECHE' => [0.85, 30, 20, 60],
        'MP-HARINA' => [0.75, 10, 5, 25],
        'MP-PAN' => [2.20, 6, 4, 12],
        'MP-ACEITE' => [6.50, 6, 10, 30],          // bajo mínimo
        'MP-TOMATE' => [1.60, 15, 8, 30],
        'MP-PIMIENTO-VERDE' => [1.90, 6, 3, 12],
        'MP-PIMIENTO-ROJO' => [2.30, 5, 3, 12],
        'MP-CALABACIN' => [1.40, 6, 3, 12],
        'MP-CEBOLLA' => [0.90, 10, 5, 20],
        'MP-AJO' => [5.50, 2, 1, 4],
        'MP-PATATA' => [0.80, 30, 15, 60],
        'MP-AZUCAR' => [1.10, 8, 3, 15],
        'MP-CAFE' => [16.00, 1.5, 2, 8],           // bajo mínimo
        'MP-INFUSION' => [0.08, 80, 50, 200],
        'MP-CERVEZA-BARRIL' => [1.90, 60, 30, 120],
        'MP-VINO-TINTO' => [3.20, 8, 12, 36],      // bajo mínimo
        'MP-VINO-BLANCO' => [2.90, 14, 9, 27],
        'BEB-COLA-LATA' => [0.45, 48, 24, 96],
        'BEB-NARANJA-LATA' => [0.45, 24, 12, 48],
        'BEB-LIMON-LATA' => [0.45, 24, 12, 48],
        'BEB-TONICA' => [0.55, 10, 12, 48],        // bajo mínimo
        'BEB-AGUA-50' => [0.22, 60, 24, 120],
        'BEB-AGUA-GAS' => [0.35, 24, 12, 48],
    ];

    /** codproveedor => nombre (datos ficticios: sin CIF y con correo .invalid). */
    const PROVEEDORES = [
        'RUIDERA' => ['Huerta de Ruidera S.L.', 'pedidos@huerta-ruidera.invalid'],
        'MONTIEL' => ['Cárnicas Campo de Montiel S.L.', 'pedidos@carnicas-montiel.invalid'],
        'DULCINEA' => ['Ultramarinos Dulcinea S.L.', 'pedidos@ultramarinos-dulcinea.invalid'],
        'ROCINANTE' => ['Bebidas Rocinante Distribución S.L.', 'pedidos@bebidas-rocinante.invalid'],
    ];

    /** Precios de compra: referencia => [[codproveedor, referencia del proveedor, precio neto], ...]. */
    const COMPRAS = [
        'MP-TOMATE' => [['RUIDERA', 'RUI-TOM-01', 1.60]],
        'MP-PIMIENTO-VERDE' => [['RUIDERA', 'RUI-PIV-01', 1.90]],
        'MP-PIMIENTO-ROJO' => [['RUIDERA', 'RUI-PIR-01', 2.30]],
        'MP-CALABACIN' => [['RUIDERA', 'RUI-CAL-01', 1.40]],
        'MP-CEBOLLA' => [['RUIDERA', 'RUI-CEB-01', 0.90]],
        'MP-AJO' => [['RUIDERA', 'RUI-AJO-PED', 5.50]],
        'MP-PATATA' => [['RUIDERA', 'RUI-PAT-25', 0.80]],
        'MP-HUEVO' => [['RUIDERA', 'RUI-HUE-M30', 0.20], ['DULCINEA', 'DUL-1201', 0.22]],
        'MP-POLLO' => [['MONTIEL', 'MON-POL-TR', 4.90]],
        'MP-CORDERO' => [['MONTIEL', 'MON-COR-CHU', 14.50]],
        'MP-JAMON' => [['MONTIEL', 'MON-JAM-SER', 16.00]],
        'MP-CHORIZO' => [['MONTIEL', 'MON-CHO-SAR', 8.50]],
        'MP-ARROZ' => [['DULCINEA', 'DUL-0101', 2.40]],
        'MP-HARINA' => [['DULCINEA', 'DUL-0102', 0.75]],
        'MP-AZUCAR' => [['DULCINEA', 'DUL-0103', 1.10]],
        'MP-ACEITE' => [['DULCINEA', 'DUL-0201', 6.50], ['RUIDERA', 'RUI-AOVE-5L', 6.80]],
        'MP-LECHE' => [['DULCINEA', 'DUL-0301', 0.85]],
        'MP-QUESO' => [['DULCINEA', 'DUL-0401', 15.50]],
        'MP-CALAMAR' => [['DULCINEA', 'DUL-0501', 9.50]],
        'MP-PAN' => [['DULCINEA', 'DUL-0601', 2.20]],
        'MP-CAFE' => [['DULCINEA', 'DUL-0701', 16.00]],
        'MP-INFUSION' => [['DULCINEA', 'DUL-0702', 0.08]],
        'MP-CERVEZA-BARRIL' => [['ROCINANTE', 'ROC-BARRIL-30', 1.90]],
        'MP-VINO-TINTO' => [['ROCINANTE', 'ROC-TINTO-BIB', 3.20]],
        'MP-VINO-BLANCO' => [['ROCINANTE', 'ROC-BLANCO-BIB', 2.90]],
        // sin refrescos azucarados (BEB-COLA-LATA, BEB-NARANJA-LATA, BEB-LIMON-LATA, BEB-TONICA):
        // se venden al 10 % pero se compran al 21 % y FS usa un solo IVA por producto, así que un
        // pedido de reposición automático saldría al 10 % (ver el docblock de la clase)
        'BEB-AGUA-50' => [['ROCINANTE', 'ROC-AGUA-50', 0.22]],
        'BEB-AGUA-GAS' => [['ROCINANTE', 'ROC-AGUAG-50', 0.35]],
    ];

    /** Escandallos: plato => [[ingrediente, cantidad neta, merma %], ...]. */
    const RECETAS = [
        'BEB-CANA' => [['MP-CERVEZA-BARRIL', 0.20, 5]],
        'BEB-DOBLE' => [['MP-CERVEZA-BARRIL', 0.33, 5]],
        'BEB-COPA-TINTO' => [['MP-VINO-TINTO', 0.15, 2]],
        'BEB-COPA-BLANCO' => [['MP-VINO-BLANCO', 0.15, 2]],
        'BEB-CAFE-SOLO' => [['MP-CAFE', 0.007, 0], ['MP-AZUCAR', 0.008, 0]],
        'BEB-CORTADO' => [['MP-CAFE', 0.007, 0], ['MP-LECHE', 0.04, 5], ['MP-AZUCAR', 0.008, 0]],
        'BEB-CAFE-LECHE' => [['MP-CAFE', 0.007, 0], ['MP-LECHE', 0.15, 5], ['MP-AZUCAR', 0.008, 0]],
        'BEB-INFUSION' => [['MP-INFUSION', 1, 0], ['MP-AZUCAR', 0.008, 0]],
        'PLA-GAZPACHO' => [
            ['MP-TOMATE', 0.30, 5], ['MP-PIMIENTO-VERDE', 0.04, 15], ['MP-AJO', 0.004, 10],
            ['MP-PAN', 0.03, 0], ['MP-ACEITE', 0.03, 0],
        ],
        'PLA-QUESO' => [['MP-QUESO', 0.15, 8]],
        'PLA-JAMON' => [['MP-JAMON', 0.10, 12]],
        'PLA-CROQUETAS' => [
            ['MP-JAMON', 0.04, 12], ['MP-LECHE', 0.15, 0], ['MP-HARINA', 0.05, 3],
            ['MP-HUEVO', 1, 0], ['MP-PAN', 0.03, 0], ['MP-ACEITE', 0.05, 0],
        ],
        'PLA-CALAMARES' => [
            ['MP-CALAMAR', 0.25, 30], ['MP-HARINA', 0.05, 3], ['MP-HUEVO', 1, 0], ['MP-ACEITE', 0.06, 0],
        ],
        'PLA-TORTILLA' => [
            ['MP-PATATA', 0.20, 15], ['MP-HUEVO', 2, 0], ['MP-CEBOLLA', 0.04, 10], ['MP-ACEITE', 0.05, 0],
        ],
        'PLA-BRAVAS' => [
            ['MP-PATATA', 0.30, 15], ['MP-ACEITE', 0.05, 0], ['MP-TOMATE', 0.04, 5], ['MP-AJO', 0.002, 10],
        ],
        'PLA-MIGAS' => [
            ['MP-PAN', 0.20, 0], ['MP-CHORIZO', 0.06, 0], ['MP-AJO', 0.01, 10],
            ['MP-PIMIENTO-VERDE', 0.05, 15], ['MP-ACEITE', 0.05, 0],
        ],
        'PLA-PAELLA' => [
            ['MP-ARROZ', 0.10, 0], ['MP-POLLO', 0.12, 10], ['MP-CALAMAR', 0.05, 30],
            ['MP-PIMIENTO-ROJO', 0.04, 15], ['MP-TOMATE', 0.04, 5], ['MP-AJO', 0.003, 10], ['MP-ACEITE', 0.02, 0],
        ],
        'PLA-PISTO' => [
            ['MP-TOMATE', 0.25, 5], ['MP-PIMIENTO-VERDE', 0.10, 15], ['MP-PIMIENTO-ROJO', 0.10, 15],
            ['MP-CALABACIN', 0.15, 8], ['MP-CEBOLLA', 0.10, 10], ['MP-ACEITE', 0.04, 0], ['MP-HUEVO', 1, 0],
        ],
        'PLA-POLLO-AJILLO' => [
            ['MP-POLLO', 0.35, 10], ['MP-AJO', 0.02, 10], ['MP-ACEITE', 0.04, 0], ['MP-VINO-BLANCO', 0.05, 0],
        ],
        'PLA-CHULETAS' => [['MP-CORDERO', 0.30, 10], ['MP-PATATA', 0.20, 15], ['MP-ACEITE', 0.04, 0]],
        'PLA-FLAN' => [['MP-LECHE', 0.12, 0], ['MP-HUEVO', 1, 0], ['MP-AZUCAR', 0.03, 0]],
        'PLA-TARTA-QUESO' => [
            ['MP-QUESO', 0.06, 8], ['MP-LECHE', 0.05, 0], ['MP-HUEVO', 1, 0],
            ['MP-AZUCAR', 0.03, 0], ['MP-HARINA', 0.01, 0],
        ],
        'PLA-ARROZ-LECHE' => [['MP-ARROZ', 0.03, 0], ['MP-LECHE', 0.20, 5], ['MP-AZUCAR', 0.03, 0]],
    ];

    /** IVA de venta de la carta (hostelería). */
    const IVA_VENTA = 10;

    /** Resultado de la última carga: clave => [creados, ya existían]. @var array */
    public $resumen = [];

    /**
     * Carga la carta. Devuelve true si terminó bien (también si ya estaba cargada).
     */
    public function cargar(): bool
    {
        $this->resumen = [];
        foreach (['familias', 'productos', 'materias', 'proveedores', 'precios', 'stocks', 'escandallos'] as $clave) {
            $this->resumen[$clave] = [0, 0];
        }

        $codalmacen = (string)Tools::settings('default', 'codalmacen', '');
        if ($codalmacen === '' || false === (new Almacen())->load($codalmacen)) {
            Tools::log()->error('tpv-check-warehouse-missing');
            return false;
        }

        $impuestos = $this->impuestos();
        if (null === $impuestos) {
            return false;
        }

        // instanciamos los modelos antes de abrir la transacción: si alguna tabla no está
        // revisada, el DbUpdater podría crearla/alterarla (DDL = COMMIT implícito en MySQL)
        new Familia();
        new Producto();
        new Variante();
        new Stock();
        new Proveedor();
        new ProductoProveedor();
        new TpvEscandallo();

        $db = new DataBase();
        $db->connect();
        $db->beginTransaction();
        try {
            $ok = $this->cargarFamilias()
                && $this->cargarProveedores()
                && $this->cargarProductos($impuestos, $codalmacen);
        } catch (Throwable $e) {
            Tools::log()->error($e->getMessage());
            $ok = false;
        }

        if (false === $ok) {
            $db->rollback();
            Tools::log()->error('tpv-menu-load-error');
            return false;
        }

        $db->commit();
        return true;
    }

    /**
     * Precio neto (5 decimales) para que el PVP con IVA sea exacto.
     */
    public static function precioNeto(float $pvp, float $iva): float
    {
        return round($pvp * 100 / (100 + $iva), 5);
    }

    private function cargarFamilias(): bool
    {
        foreach (self::FAMILIAS as $cod => [$descripcion, $madre, $destino]) {
            $familia = new Familia();
            if ($familia->load($cod)) {
                $this->resumen['familias'][1]++;
                continue;
            }

            $familia->codfamilia = $cod;
            $familia->descripcion = $descripcion;
            $familia->madre = $madre;
            $familia->tpv_destino = $destino;
            if (false === $familia->save()) {
                Tools::log()->error('tpv-menu-save-error', ['%item%' => $cod]);
                return false;
            }
            $this->resumen['familias'][0]++;
        }

        return true;
    }

    private function cargarProveedores(): bool
    {
        foreach (self::PROVEEDORES as $cod => [$nombre, $email]) {
            $proveedor = new Proveedor();
            if ($proveedor->load($cod)) {
                $this->resumen['proveedores'][1]++;
                continue;
            }

            $proveedor->codproveedor = $cod;
            $proveedor->nombre = $nombre;
            $proveedor->razonsocial = $nombre;
            $proveedor->cifnif = '';
            $proveedor->personafisica = false;
            $proveedor->email = $email;
            $proveedor->observaciones = Tools::trans('tpv-menu-sample-data');
            if (false === $proveedor->save()) {
                Tools::log()->error('tpv-menu-save-error', ['%item%' => $cod]);
                return false;
            }
            $this->resumen['proveedores'][0]++;
        }

        return true;
    }

    /**
     * @param string[] $impuestos IVA % => codimpuesto
     */
    private function cargarProductos(array $impuestos, string $codalmacen): bool
    {
        $creados = [];

        foreach (self::CARTA as $ref => [$descripcion, $familia, $pvp, $tipo]) {
            $flags = $tipo === self::ENVASADO
                ? ['nostock' => false, 'secompra' => true, 'sevende' => true]
                : ['nostock' => true, 'secompra' => false, 'sevende' => true];
            $precio = self::precioNeto($pvp, self::IVA_VENTA);
            $resultado = $this->crearProducto($ref, $descripcion, $familia, $impuestos[self::IVA_VENTA], $precio, $flags);
            if (null === $resultado) {
                return false;
            }
            $this->resumen['productos'][$resultado ? 0 : 1]++;
            if ($resultado) {
                $creados[$ref] = true;
            }
        }

        foreach (self::MATERIAS as $ref => [$descripcion, $iva]) {
            $flags = ['nostock' => false, 'secompra' => true, 'sevende' => false];
            $resultado = $this->crearProducto($ref, $descripcion, 'MATPRI', $impuestos[$iva], 0.0, $flags);
            if (null === $resultado) {
                return false;
            }
            $this->resumen['materias'][$resultado ? 0 : 1]++;
            if ($resultado) {
                $creados[$ref] = true;
            }
        }

        // stock, coste y precios de compra: solo de lo creado ahora
        foreach (self::STOCK as $ref => [$coste, $cantidad, $minimo, $maximo]) {
            if (!isset($creados[$ref])) {
                $this->resumen['stocks'][1]++;
                continue;
            }
            if (false === $this->crearStock($ref, $codalmacen, $coste, $cantidad, $minimo, $maximo)) {
                return false;
            }
            $this->resumen['stocks'][0]++;
        }

        foreach (self::COMPRAS as $ref => $lineas) {
            foreach ($lineas as [$codproveedor, $refproveedor, $precio]) {
                if (!isset($creados[$ref])) {
                    $this->resumen['precios'][1]++;
                    continue;
                }
                if (false === $this->crearPrecioCompra($ref, $codproveedor, $refproveedor, $precio)) {
                    return false;
                }
                $this->resumen['precios'][0]++;
            }
        }

        foreach (self::RECETAS as $plato => $lineas) {
            if (!isset($creados[$plato])) {
                $this->resumen['escandallos'][1]++;
                continue;
            }
            foreach ($lineas as [$ingrediente, $cantidad, $merma]) {
                $linea = new TpvEscandallo();
                $linea->ref_plato = $plato;
                $linea->ref_ingrediente = $ingrediente;
                $linea->cantidad = (float)$cantidad;
                $linea->merma = (float)$merma;
                if (false === $linea->save()) {
                    Tools::log()->error('tpv-menu-save-error', ['%item%' => $plato . ' / ' . $ingrediente]);
                    return false;
                }
            }
            $this->resumen['escandallos'][0]++;
        }

        return true;
    }

    private function crearPrecioCompra(string $ref, string $codproveedor, string $refproveedor, float $precio): bool
    {
        $where = [Where::eq('referencia', $ref), Where::eq('codproveedor', $codproveedor)];
        if (ProductoProveedor::count($where) > 0) {
            return true;
        }

        $fila = new ProductoProveedor();
        $fila->referencia = $ref;
        $fila->codproveedor = $codproveedor;
        $fila->refproveedor = $refproveedor;
        $fila->precio = $precio;
        if (false === $fila->save()) {
            Tools::log()->error('tpv-menu-save-error', ['%item%' => $ref . ' / ' . $codproveedor]);
            return false;
        }

        return true;
    }

    /**
     * Crea el producto si su referencia no existe.
     *
     * @return bool|null true = creado, false = ya existía, null = error
     */
    private function crearProducto(string $ref, string $descripcion, string $familia, string $codimpuesto, float $precio, array $flags): ?bool
    {
        if (Variante::count([Where::eq('referencia', $ref)]) > 0 || Producto::count([Where::eq('referencia', $ref)]) > 0) {
            return false;
        }

        $producto = new Producto();
        $producto->referencia = $ref;
        $producto->descripcion = $descripcion;
        $producto->codfamilia = (new Familia())->load($familia) ? $familia : null;
        $producto->codimpuesto = $codimpuesto;
        $producto->precio = $precio;
        $producto->nostock = $flags['nostock'];
        $producto->secompra = $flags['secompra'];
        $producto->sevende = $flags['sevende'];
        $producto->ventasinstock = true;
        $producto->publico = false;
        $producto->observaciones = Tools::trans('tpv-menu-sample-data');
        if (false === $producto->save()) {
            Tools::log()->error('tpv-menu-save-error', ['%item%' => $ref]);
            return null;
        }

        return true;
    }

    private function crearStock(string $ref, string $codalmacen, float $coste, float $cantidad, float $minimo, float $maximo): bool
    {
        $variante = new Variante();
        if (false === $variante->loadWhereEq('referencia', $ref)) {
            Tools::log()->error('tpv-menu-save-error', ['%item%' => $ref]);
            return false;
        }
        if (abs((float)$variante->coste - $coste) > 0.000001) {
            $variante->coste = $coste;
            if (false === $variante->save()) {
                Tools::log()->error('tpv-menu-save-error', ['%item%' => $ref]);
                return false;
            }
        }

        $where = [Where::eq('referencia', $ref), Where::eq('codalmacen', $codalmacen)];
        if (Stock::count($where) > 0) {
            return true;
        }

        $stock = new Stock();
        $stock->referencia = $ref;
        $stock->idproducto = $variante->idproducto;
        $stock->codalmacen = $codalmacen;
        $stock->cantidad = $cantidad;
        $stock->stockmin = $minimo;
        $stock->stockmax = $maximo;
        if (false === $stock->save()) {
            Tools::log()->error('tpv-menu-save-error', ['%item%' => $ref . ' / ' . $codalmacen]);
            return false;
        }

        return true;
    }

    /**
     * Impuestos de IVA por porcentaje (4, 10, 21): el de código IVA<n> si existe, si no el
     * primero activo de tipo porcentaje con ese IVA.
     *
     * @return string[]|null IVA % => codimpuesto
     */
    private function impuestos(): ?array
    {
        $out = [];
        foreach ([4, 10, 21] as $iva) {
            $candidatos = [];
            foreach (Impuesto::all([], ['codimpuesto' => 'ASC']) as $impuesto) {
                if (abs((float)$impuesto->iva - $iva) < 0.001 && (int)$impuesto->tipo === CoreImpuesto::TYPE_PERCENTAGE
                    && (bool)$impuesto->activo) {
                    $candidatos[] = $impuesto->codimpuesto;
                }
            }
            if (empty($candidatos)) {
                Tools::log()->error('tpv-menu-tax-missing', ['%tax%' => $iva]);
                return null;
            }
            $out[$iva] = in_array('IVA' . $iva, $candidatos, true) ? 'IVA' . $iva : $candidatos[0];
        }

        return $out;
    }

    /**
     * Totales para mostrar: número de productos de carta, materias, recetas...
     */
    public static function totales(): array
    {
        return [
            'familias' => count(self::FAMILIAS),
            'productos' => count(self::CARTA),
            'materias' => count(self::MATERIAS),
            'proveedores' => count(self::PROVEEDORES),
            'escandallos' => count(self::RECETAS),
        ];
    }
}
