# TPV Comandero · FacturaScripts

TPV y comandero de hostelería en Flutter con arquitectura dual:

- **Modo Host (tablet)**: servidor TCP de comandas (puerto 4040), respondedor de descubrimiento UDP (4041), caja y cobro, impresión ESC/POS por red (9100), sincronización con FacturaScripts y Cierre Z.
- **Modo Comandero (móvil)**: descubre el host por UDP broadcast, toma comandas por mesa y las envía por TCP con entrega fiable (retransmisión y deduplicación tras una reconexión).

La integración con el ERP sigue dos vías, como exige la lógica de FacturaScripts:

| Operación | Vía | Motivo |
|---|---|---|
| Factura simplificada de cada ticket | API REST v3 (`POST /api/3/crearFacturaCliente`) | Numeración, asiento, recibos y stock los gestiona el ERP en una transacción |
| Cobro mixto (efectivo + tarjeta) | API REST v3 (`reciboclientes` + `pagarFacturaCliente`) | Un recibo por forma de pago: cada cobro va a su subcuenta (570 / 572) |
| Pedidos automáticos a proveedor | API REST v3 (`POST /api/3/crearPedidoProveedor`) | Un pedido por proveedor; deja `pterecibir` actualizado |
| Asiento del Cierre Z | API REST v3 (`asientos` + `partidas`) | Protocolo idempotente con compensación |
| Escandallos y descuento de materias primas | MySQL directo (`mysql_client`) | Tabla propia `tpv_escandallos` + transacciones `START TRANSACTION … COMMIT/ROLLBACK` sobre `stocks` |

Los cálculos pesados (resolución matricial de escandallos con merma, auditoría de stock mínimo, cuadre contable Debe/Haber y generación/rasterizado ESC/POS) se ejecutan en isolates (`Isolate.run`) con funciones top-level y DTOs planos: el hilo de UI nunca se bloquea.

## Requisitos

- Flutter 3.47 (Dart 3.13). En Windows, para compilar el escritorio hace falta el *Modo de desarrollador* activado (enlaces simbólicos de los plugins).
- FacturaScripts 2026.x con la API activada y una clave de API (Panel de control → API).
- Acceso MySQL a la base de datos de FacturaScripts (usuario con permisos sobre `stocks`, `productos`, `variantes`, `productosprov`, `proveedores` y para crear las tablas `tpv_*`). Con MySQL 8.x (autenticación `caching_sha2_password`) la conexión debe ir con TLS (opción *TLS* en Ajustes → MySQL); MySQL trae certificados autogenerados, no hay que instalar nada.
- Impresora térmica ESC/POS con interfaz de red (puerto 9100).

## Puesta en marcha

```bash
flutter pub get
flutter analyze
flutter test                       # suites Dart puro + widgets
flutter build apk --debug          # Android
flutter build windows --debug      # Windows (requiere Modo de desarrollador)
```

Si el `dart` del PATH no es el del SDK de Flutter, usa `<flutter>/bin/dart.bat test` (ver `CLAUDE.md`).

## Prueba de flujo en Windows

Arranca la app real en modo host sobre la interfaz de escritorio y recorre una mesa de punta a punta: comensales, platos en Primeros y Segundos y una bebida, envío (comandas de cocina y barra), «Marchar», precuenta, cobro en efectivo (documento provisional con apertura del cajón), factura de FacturaScripts con ORIGINAL y DUPLICADO y el detalle del ticket en *Caja y Cierre Z*. Las impresoras son servidores TCP locales que reciben los bytes ESC/POS de verdad, y el ERP está simulado en memoria:

```bash
flutter test integration_test/host_flujo_impresion_test.dart -d windows
```

La misma prueba incluye el cobro contra un FacturaScripts **de pruebas** (crea una factura real y la borra al terminar; **nunca** contra producción). Sin estas variables se omite sola:

```bash
flutter test integration_test/host_flujo_impresion_test.dart -d windows \
  --dart-define=TPV_FS_BASE_URL=http://localhost/fs_pruebas \
  --dart-define=TPV_FS_TOKEN=<clave> [--dart-define=TPV_FS_REF=<plato>]
```

## Primer arranque

La aplicación pregunta el rol del dispositivo la primera vez (se puede cambiar después en Ajustes):

**Servidor TPV (tablet)**

1. Ajustes → *ERP FacturaScripts*: URL base y clave de API → **Probar conexión**. Muestra el diagnóstico (serie, formas de pago, almacén, cliente) y carga las formas de pago y almacenes reales. Cada clave inválida cuenta para el baneo de IP de FacturaScripts (5 en 10 minutos): la app no reintenta sola.
2. *Fiscal*: serie, cliente genérico (botón **Crear cliente genérico** si no existe), almacén, formas de pago de efectivo y tarjeta y modo del asiento Z.
3. *MySQL* (opcional, para escandallos y stock): servidor, usuario, contraseña, base de datos y TLS → **Probar conexión** y **Crear/verificar tablas tpv_\***.
4. *Impresoras*: IP de tickets, cocina y barra (puerto 9100) → **Ticket de prueba**. **Enrutamiento por familias** (también desde el salón): cada familia del catálogo va a cocina o a barra, las subfamilias heredan el destino de su familia madre y el resto va al destino por defecto. El destino puede venir del ERP (destino cocina/barra de la familia, `familias.tpv_destino`, con el plugin de hostelería) o de una regla del TPV; en cada nivel de la jerarquía manda la regla del TPV y después el ERP, y la pantalla muestra el origen de cada destino (*ERP*, *Regla del TPV*, *Heredado de…*, *Por defecto*). El host decide el destino de cada línea, venga del comandero o de la tablet; una comanda con platos y bebidas sale en un ticket por puesto, y las anulaciones se imprimen en el puesto de la línea.
5. *Mesas*, *Reposición* y *Caja* (fondo inicial). Con *Código de emparejamiento* solo se conectan los comanderos que lo conozcan.

La sala funciona aunque el ERP, MySQL o la impresora no estén disponibles: facturas, descuentos de stock, pedidos y asientos esperan en la cola de sincronización (pantalla *Sincronización*) y se envían, en orden y sin duplicados, cuando vuelven.

**Comandero (móvil)**

En la misma red Wi-Fi que la tablet, **Buscar** encuentra el host por UDP; si la red bloquea el broadcast, usa la conexión manual `IP:4040`. Las comandas enviadas sin conexión quedan en cola y salen al reconectar.

## Cobro

En el diálogo de cobro se elige *Efectivo*, *Tarjeta* o *Mixto*. En *Mixto* se teclea la parte en efectivo (o la de tarjeta) y el resto se calcula solo; el cambio se calcula sobre la parte en efectivo. El ticket impreso muestra el desglose, el cajón se abre si hay parte en efectivo y el Cierre Z cuenta cada parte en su forma de pago (el efectivo esperado solo suma la parte en efectivo). En FacturaScripts la factura queda con un recibo cobrado por forma de pago, cada uno con su asiento de cobro.

La clave de API necesita acceso GET/POST/PUT/DELETE a `reciboclientes` y GET a `pagoclientes` además de los recursos habituales (la clave que crea el plugin ya los tiene). El diagnóstico de Ajustes no puede comprobar los permisos de la clave (`GET /api/3` lista todos los recursos); el asistente del plugin sí.

## Limitaciones conocidas

- El cobro mixto admite dos partes (efectivo + tarjeta); no hay pagos con más formas de pago ni rectificativas automáticas de un cobro mixto.
- La cola de envíos fiables del comandero vive en memoria: si se cierra la app con envíos pendientes, esas líneas se pierden (la app lo indica con el contador de pendientes).
- No hay nombre de camarero por defecto en los ajustes del comandero.
- Los comanderos reciben el enrutamiento efectivo del host (reglas del TPV + destinos del ERP) en el siguiente estado de la sala (al reconectar o refrescar); no afecta a la impresión porque el host fija el destino de cada línea al aceptarla.
- Una factura en error detiene las siguientes hasta reintentarla o descartarla en *Sincronización* (FacturaScripts exige orden cronológico en la serie).
- Con MySQL 8 la conexión debe ir con TLS (limitación de `mysql_client` con `caching_sha2_password`).
- La pantalla de escandallos abre su propia conexión MySQL mientras está abierta.

## ERP de hostelería (plugin de FacturaScripts)

El plugin **Hosteleria** (código en [`erp/Hosteleria`](erp/Hosteleria) de este repositorio; FacturaScripts 2026.5 o superior) convierte la instalación en el ERP del TPV:

- **Escandallos** (`tpv_escandallos`) con merma desde la ficha del producto (pestaña *Escandallo*), con el **coste teórico** calculado con la misma regla que el TPV (un semielaborado se expande siempre hasta sus materias primas), el margen y un botón para copiar ese coste a la ficha (FacturaScripts lo usa como coste de cada venta). Al guardar una línea se rechazan los ciclos y las cadenas de más de 20 platos con receta (el propio plato y hasta 19 subrecetas: la app dejaría de descontar stock de todas las ventas) y se avisa cuando el redondeo a 3 decimales del TPV descuenta bastante menos de lo previsto. La pestaña *Usado en* muestra las recetas que usan un ingrediente, que no se puede borrar mientras esté en alguna.
- **Diario de stock del TPV** (`tpv_movimientos_stock`, variación de `stocks.cantidad`: negativa = consumo, positiva = devolución) con descripción, filtros de consumos/devoluciones y una pestaña de **consumo por materia prima** y periodo (cantidades y valor). Si se renombra una referencia, el diario la sigue (no tiene clave ajena). Las tablas tienen el mismo DDL que crea la app; con el usuario de MySQL que genera el plugin las crea el plugin (ese usuario no puede crear tablas).
- **Destino cocina/barra por familia**: columna `familias.tpv_destino` (`cocina`, `barra` o vacío = hereda de la familia madre), visible en la API (`GET /api/3/familias`). El TPV la lee con el catálogo; en cada nivel de la jerarquía manda la regla del TPV y después el ERP.
- Consulta de los **tickets** (y sus rectificativas, que pasan a llevar `numero2` = `RTPV-…` para no duplicar la clave del ticket), de las **ventas diarias** por forma de pago (con el cobro mixto repartido), de los **asientos de cierre Z** y de los **pedidos de reposición** que crea el TPV.
- **Stock de cocina y de barra** (*Hostelería → Stock*): la pestaña *Stock* de *Almacén → Productos* (mismas columnas, filtros y avisos de mínimos) partida en dos. FacturaScripts lleva un solo stock por almacén; cada referencia es de cocina o de barra por el destino de su familia o, si no lo tiene, por los platos que la usan. Si la usan los dos, sale en las dos pestañas y el asistente lo avisa para decidir (subfamilia de materias primas con destino o un producto para cada sitio).
- Un **asistente** (*Hostelería → Configurar TPV*) con 22 comprobaciones y un botón para corregir cada una: API activada, ejercicio, cuentas *Caja* (570) y *Banco TPV* (572) y subcuentas del cierre Z, formas de pago `TPVEFE` (Efectivo TPV) y `TPVTAR` (Tarjeta TPV) que nacen pagadas, cliente genérico `TPV` ("CLIENTES VARIOS (TPV)"), serie `S` (simplificada), almacén activo, clave de API *TPV Comandero* con acceso solo a los 23 recursos que usa la app, tablas `tpv_*` con sus índices únicos, rol *Hosteleria*, recetas válidas para el motor de la app, platos/materias primas con el control de stock correcto, venta sin stock (un envasado sin stock bloquearía la cola de facturas), costes, reposición automática, stock de cocina y barra, carta y destinos, y claves del TPV duplicadas. También genera, a petición, el usuario de MySQL del TPV con privilegios mínimos (por columna en `stocks`, `variantes` y `productos`; solo `SELECT`/`INSERT` en el diario) y TLS, y muestra el resumen de valores para los Ajustes de la app.
- Una **carta de ejemplo** opcional (restaurante manchego): familias con destino, platos y bebidas con IVA 10 %, materias primas con stock mínimo, proveedores con precios y escandallos con merma.

Instalación: copia `erp/Hosteleria` en la carpeta `Plugins/` de FacturaScripts, actívalo en *Panel de control → Plugins* y ejecuta el asistente. Para actualizarlo, sube su ZIP en *Plugins* o, si copias la carpeta, pulsa *Reconstruir* y después *Reparar el rol* en el asistente (o desactiva y activa el plugin): FacturaScripts solo ejecuta su `update()` al activarlo. Solo MySQL / MariaDB. Sin el plugin la app funciona igual (sin destinos en el ERP; las formas de pago se eligen en Ajustes).

## Configuración recomendada en FacturaScripts

1. Serie para facturas simplificadas (de fábrica `S`).
2. Cliente genérico de contado `TPV` ("CLIENTES VARIOS (TPV)"), sin riesgo máximo. Lo crea el asistente del plugin; la app también puede crearlo desde Ajustes.
3. Formas de pago de efectivo y tarjeta con `pagado = sí` y asociadas a una cuenta bancaria cuya subcuenta sea `570…` (caja) y `572…` (banco). Sin esa cuenta, FacturaScripts contabiliza todos los cobros en 572. La app usa por defecto `TPVEFE` y `TPVTAR` (las del asistente); unos ajustes ya guardados conservan sus formas de pago.
4. Productos de carta con **"no controlar stock"** (el stock lo llevan las materias primas, que descuenta el TPV según el escandallo).
5. Ejercicio abierto con el plan contable cargado (subcuentas 570, 572, 700, 477, 659 y 759).
6. Con el plugin, el destino cocina/barra de las familias raíz (p. ej. Bebidas → barra); las subfamilias lo heredan.

## Cierre Z y contabilidad

Cada ticket es una factura con asiento automático (430 → 700/477) y cobro automático (570/572 → 430). Por eso el asiento del Cierre Z es, por defecto, **solo el descuadre de caja** (faltante: 659 contra 570; sobrante: 570 contra 759). El modo *resumen completo* (570/572/700/477/659/759) está disponible en Ajustes para instalaciones donde las facturas no generen asiento; la app avisa y bloquea si detecta facturas con asiento ese día.

## Estructura

```
lib/app          arranque, tema, shell y canales de plataforma
lib/core         Dart puro: red (protocolo, TCP, UDP, impresión), MySQL, API FacturaScripts,
                 motores en isolates (escandallos, reposición, cierre Z, ESC/POS), réplica fiscal
lib/features     sala (dominio y protocolo), host (runtime, cola de sincronización, pantallas),
                 comandero (controlador y pantallas), settings, escandallos, cierre_z
sql/             DDL de las tablas propias (tpv_escandallos, tpv_movimientos_stock)
test/            tests Dart puro (espejo de lib), test/widget (Flutter), test/integration (con variables de entorno)
integration_test/ prueba de flujo del host sobre la interfaz real (escritorio Windows)
```

Los tests de integración contra una instancia de FacturaScripts/MySQL se activan con `TPV_FS_BASE_URL`, `TPV_FS_TOKEN`, `TPV_MYSQL_HOST`, `TPV_MYSQL_PORT`, `TPV_MYSQL_USER`, `TPV_MYSQL_PASSWORD` y `TPV_MYSQL_DATABASE`; sin ellas se omiten.
