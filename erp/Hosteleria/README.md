# Hosteleria · plugin de FacturaScripts

ERP del TPV y comandero de hostelería (`proyecto_comandero`, Flutter). FacturaScripts 2026.5 o superior, PHP 8.1 y **solo MySQL / MariaDB** (el TPV usa SQL directo).

## Qué añade

- **Escandallos** (`tpv_escandallos`): pestaña *Escandallo* en la ficha de producto con cantidad neta, merma, cantidad bruta, coste teórico y margen; botón para copiar el coste teórico a la ficha; pestaña *Usado en* para los ingredientes; listado y ficha de líneas en *Hostelería*. Las reglas son las del motor de escandallos de la app (`Lib/TpvGrafoRecetas.php`): un semielaborado se expande siempre hasta sus materias primas, no se admiten ciclos ni cadenas de más de 20 platos con receta (el plato y hasta 19 subrecetas) y las referencias se guardan tal como están en variantes.
- **Diario de stock del TPV** (`tpv_movimientos_stock`, solo lectura): `cantidad` es la variación de `stocks.cantidad` (negativa = consumo de una comanda, positiva = devolución de una anulación). Pestaña de consumo por materia prima y periodo.
- **Destino cocina/barra por familia**: `familias.tpv_destino` (`cocina`, `barra` o vacío = hereda), que el TPV lee en `GET /api/3/familias`.
- **Stock de cocina y de barra** (*Hostelería → Stock*): la pestaña *Stock* de *Almacén → Productos* partida en dos (`Lib/TpvStockDestino.php`). Cada referencia es de cocina o de barra por el destino de su familia o, si no lo tiene, por los platos que la usan; las que usan los dos salen en las dos pestañas y el asistente lo avisa.
- **Tickets** (`numero2 = 'TPV-…'`) y sus rectificativas (`'RTPV-…'`), **ventas diarias** por forma de pago, **asientos de cierre Z** (`documento = 'Z-…'`) y **pedidos de reposición** (`numproveedor = 'TPV-REPO-…'`).
- **Configurar TPV** (solo administradores): comprobaciones con botón de corrección, clave de API con los permisos mínimos (`Lib/TpvApiPermisos.php`), usuario de MySQL con privilegios mínimos (`Lib/TpvMysqlUsuario.php`), resumen de valores para la app y carta de ejemplo.
- Rol **Hosteleria** con las páginas del plugin. Se asigna junto con otro rol que incluya productos, familias, facturas, pedidos de proveedor y asientos: sin acceso a esas fichas, los listados del plugin no enlazan a ellas y los pedidos de reposición no se pueden aprobar ni agrupar.

## Instalación y actualización

1. Copia la carpeta en `Plugins/Hosteleria` y actívala en *Panel de control → Plugins*.
2. Abre *Hostelería → Configurar TPV* y pulsa *Crear todo lo que falta*.

FacturaScripts solo ejecuta `Init::update()` al activar el plugin (o al subir su ZIP). Si lo actualizas copiando la carpeta, pulsa *Reconstruir* en *Plugins* y después *Reparar el rol* en el asistente (o desactívalo y actívalo).

## Contrato con la app

Las tablas `tpv_*` tienen el mismo DDL que crea la app (`sql/tpv_schema.sql`); `Lib/TpvSchema.php` lo reproduce y `Table/*.xml` solo sirve para que el DbUpdater no cambie nada. El detalle de lo que el plugin asume de la app (signo del diario, profundidad máxima, claves idempotentes, permisos) está en el `CLAUDE.md` del repositorio de la app, sección *Contrato con el plugin Hosteleria*.

## Traducciones

`Translation/es_ES.json` y `en_EN.json` son las fuentes. FacturaScripts no tiene idioma de reserva, así que el resto de idiomas del núcleo son copias: las variantes del español, `ca_ES`, `eu_ES`, `gl_ES` y `va_ES` de `es_ES.json`, y los demás de `en_EN.json`. Al añadir claves, vuelve a copiarlas.
