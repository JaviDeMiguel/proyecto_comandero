# Directrices de Desarrollo - TPV Comandero & FacturaScripts ERP

TPV y comandero de hostelería en Flutter con arquitectura dual: **modo Host** (tablet: servidor TCP, caja, impresión, sincronización con el ERP) y **modo Comandero** (móvil: descubre el host por UDP y envía comandas por TCP). El ERP es FacturaScripts (API REST v3 + MySQL directo).

## Comandos

El `dart` del PATH de esta máquina (`C:\dart`, 3.9.4) **no** es el del SDK de Flutter (3.13.x) y no puede resolver este proyecto. Usa siempre `flutter ...` o el Dart de Flutter:

```bash
flutter pub get
C:\Users\Admin\flutter\bin\dart.bat format lib test      # formato
flutter analyze                                           # análisis estático (debe quedar a cero)
flutter test                                              # todas las suites (Dart puro + widgets)
C:\Users\Admin\flutter\bin\dart.bat test                  # solo suites Dart puro (rutas en dart_test.yaml)
C:\Users\Admin\flutter\bin\dart.bat test test/core/network/protocol   # una carpeta o fichero
flutter build windows --debug                             # compila el host de escritorio
flutter build apk --debug                                 # compila Android
```

## Arquitectura del Proyecto
- **Patrón:** Clean Architecture / Feature-First.
  - `lib/app/`: arranque, tema, navegación y canales de plataforma (Flutter).
  - `lib/core/errors/`, `lib/core/logging/`, `lib/core/money/`, `lib/core/utils/`: primitivas transversales.
  - `lib/core/network/`: Sockets TCP, UDP Broadcast, manejo de streams y framing de mensajes.
    - `protocol/` (framing JSON-line y sobre de mensaje), `discovery/` (UDP 4041), `tcp/` (servidor host 4040 y cliente comandero), `printing/` (ESC/POS raw por TCP 9100).
  - `lib/core/database/`: Conexión MySQL (`mysql_client`) con soporte para transacciones.
  - `lib/core/facturascripts/`: Cliente HTTP REST v3.
  - `lib/core/isolates/`: Tareas pesadas fuera del hilo de UI (ESC/POS, escandallos, reaprovisionamiento, cuadre contable).
  - `lib/features/host/`: Lógica exclusiva de la Tablet (Servidor TCP, Host UDP, caja, Cierre Z).
  - `lib/features/comandero/`: Lógica exclusiva del móvil (Cliente TCP, Sondeo UDP, toma de comandas).
  - `lib/features/escandallos/`: Modelos y servicios de recetas y mermas.
  - `lib/features/sala/`, `catalog/`, `settings/`, `cierre_z/`: mesas y comandas, catálogo, configuración y visor de cierre.
  - `sql/`: DDL de las tablas propias (`tpv_*`).
- **Puntos de entrada:**
  - Host: `HostRuntime.create(...)` (`lib/features/host/application/host_runtime.dart`) compone sala, cola de sincronización (`SyncOutbox`), facturación, stock, reposición, Cierre Z, impresión y red; la UI lo obtiene de `hostRuntimeProvider` y recibe `HostSettings` mediante `hostSettingsFromApp` (`presentation/host_settings_mapper.dart`).
  - Comandero: `ComanderoController` (`lib/features/comandero/application/`), envuelto por `ComanderoGateway` en la UI; configuración con `comanderoConfigFromApp`.
  - Ajustes: `appSettingsProvider` / `settingsServiceProvider` / `settingsRepositoryProvider` (`lib/features/settings/presentation/settings_providers.dart`). En tests: `settingsRepositoryProvider.overrideWith((ref) => InMemorySettingsRepository(...))`.
- **Capas y dependencias** (las verifica `test/architecture/layering_test.dart`):
  - `lib/core/**` es **Dart puro**: no importa Flutter ni plugins de plataforma, ni `lib/features` ni `lib/app`.
  - En cada feature: `domain/` y `application/` son Dart puro; `data/` implementa repositorios; solo `presentation/` usa Flutter y Riverpod.
  - Los tests espejan `lib/` bajo `test/`. Los Dart puro usan `package:test`; los de widgets van en `test/widget/` con `flutter_test`.

## Reglas Críticas de Código
1. **Regla de Sockets:**
   - TCP no tiene concepto de paquete completo: usa siempre delimitador (`\n`) o length-prefix. El framing vive en `lib/core/network/protocol/frame_codec.dart`: no lo dupliques.
   - El socket UDP de descubrimiento debe usar `broadcastEnabled = true` hacia `255.255.255.255`.
   - Todo `Future` de un socket (`done`, `flush`, `close`) debe tener manejador de error: un `SocketException` sin capturar tumba la zona.
2. **Regla de Isolates:**
   - Todas las funciones pasadas a `Isolate.run` deben ser estáticas de primer nivel o funciones globales puras. Lánzalas a través de `IsolateRunner` (`lib/core/isolates/isolate_runner.dart`).
   - No pases instancias complejas de UI o sockets abiertos entre hilos: pasa únicamente DTOs planos, primitivos o mapas serializables.
3. **Regla de Persistencia e Integridad:**
   - Factura legal, Asiento contable y Pedidos a proveedor **SIEMPRE** vía API REST de FacturaScripts (para no romper la correlatividad de series ni la lógica interna del ERP).
   - Descuento de stock en tiempo real y lectura de escandallos **VÍA MYSQL DIRECTO** dentro de bloques `START TRANSACTION ... COMMIT / ROLLBACK`.
4. **Dinero y errores:**
   - Importes en céntimos enteros (`int`) e IVA en puntos básicos (`1000` = 10 %) con `lib/core/money/money.dart`; `double` solo en el borde con el ERP.
   - Lanza y captura las excepciones tipadas de `lib/core/errors/app_exception.dart`; no dejes escapar `SocketException`, errores de MySQL o HTTP sin traducir.
5. **Durabilidad del host:**
   - Todo efecto con el ERP o MySQL es un `SyncJob` de la `SyncOutbox`, idempotente por clave, y se encola **en la misma escritura del diario** que el cambio de sala que lo origina (hooks síncronos `SalaEffects.alAceptarLineas` / `alAnularLinea` / `alCobrar`). Nunca encoles después de guardar: si la app muere entre medias, el efecto se pierde.
   - Las facturas se envían en orden FIFO estricto (correlatividad de la serie); la pausa global de la cola es solo para fallos de credenciales del ERP. Para reanudarla usa `HostRuntime.reanudarSincronizacion()` (rearma el cortafuegos anti-baneo), no `outbox.reanudar()`.
   - El host es la autoridad de precios y de destinos: al aceptar líneas fija precio, neto, IVA y `codimpuesto` desde su catálogo, y el destino (cocina/barra) con `EnrutamientoComandas` (regla por familia heredada de la familia madre; por defecto cocina).
   - La anulación de una línea revierte lo realmente aplicado según el diario `tpv_movimientos_stock`, nunca lo recalcula.
6. **Idioma:** comentarios, documentación y textos de UI en español; identificadores técnicos en inglés y sustantivos de dominio en español (`Comanda`, `Mesa`, `Escandallo`, `CierreZ`).
7. **Comprobación de Calidad:**
   - Tras cada archivo o feature implementada, ejecuta formato y análisis (ver *Comandos*; `dart format .` con el Dart del PATH falla).
   - No dejes advertencias de tipos o imports sin resolver. `analysis_options.yaml` activa `strict-casts`, `strict-inference`, `strict-raw-types` y `unawaited_futures`: no los silencies con `// ignore`.

## Protocolo de red local
- **Descubrimiento:** el comandero envía un *probe* UDP a `255.255.255.255:4041`; el host responde por unicast con su identidad y puerto TCP.
- **Sesión TCP (4040):** tramas JSON-line (`{"v":1,"id","type","ts","replyTo"?,"payload"}` + `\n`). Handshake `hello` → `welcome`/`reject`; latido `ping`/`pong`; peticiones con respuesta `ack`/`error` enlazada por `replyTo`. El host deduplica por `id`, de modo que el comandero puede retransmitir tras reconectar.
- **Impresión:** bytes ESC/POS generados en un isolate y enviados en crudo por TCP al puerto 9100.

## FacturaScripts (hechos verificados contra la instalación local 2026.5)
- La autenticación de la API es la cabecera **`Token: <api key>`** (también acepta `X-Auth-Token`); no existe `FS-TOKEN`. Cinco tokens inválidos (401/403) en 10 minutos banean la IP (429): tras un fallo de credenciales el cliente se bloquea y no reintenta solo.
- El cuerpo de POST/PUT es **`application/x-www-form-urlencoded`** (el JSON se ignora). Valores: `null` → `"null"`, booleanos `1`/`0`, números con punto, fechas `dd-MM-yyyy`. En PUT se envían solo los campos que cambian. Codificación y lectura tolerante en `lib/core/facturascripts/fs_values.dart`.
- Los recursos de la API son el plural del modelo: `facturaclientes`, `lineafacturaclientes`, `pedidoproveedores`, `lineapedidoproveedores`, `asientos`, `partidas`, `productos`, `variantes`, `stocks`, `formapagos`, `settings`... (`lib/core/facturascripts/fs_resources.dart`). `GET /api/3` los lista.
- Las facturas de ticket se crean con **`POST /api/3/crearFacturaCliente`** (transaccional: totales, numeración, asiento, recibos y stock en una llamada) y los pedidos con **`crearPedidoProveedor`**; los recursos de modelo "en crudo" no recalculan totales ni son atómicos. Idempotencia propia: `numero2` (facturas), `numproveedor` (pedidos), `documento` (asientos).
- Cada factura genera automáticamente su asiento (430 → 700/477) y cada cobro el suyo (570/572 → 430). Por eso el asiento del Cierre Z es, por defecto, solo el **descuadre de caja** (659/759 contra 570); el modo "resumen completo" (570/572/700/477) existe pero duplicaría la contabilidad si las facturas tienen asiento.
- Los totales del ticket se calculan con una réplica del `Calculator` de FS (`lib/core/fiscal/`): redondeo por tipo de IVA, no por línea; precios netos con 5 decimales.
- No existe la tabla `articulos`: el maestro es `productos` + `variantes` (clave de negocio `variantes.referencia`, UNIQUE); el stock por almacén está en `stocks` (`UNIQUE (codalmacen, referencia)`). Las tablas propias (`tpv_escandallos`, `tpv_movimientos_stock`) tienen FK a `variantes(referencia)` con `ON UPDATE CASCADE`. Al descontar stock por SQL hay que mantener `stocks.disponible`, `variantes.stockfis` y `productos.stockfis`.
- Los platos deben tener `nostock = 1` en FS (FS no les lleva stock y no bloquea la venta); las materias primas `nostock = 0`, y las descuenta el TPV según el escandallo.
- Cobro mixto (efectivo + tarjeta): `crearFacturaCliente` genera **un** recibo por el total y `pagarFacturaCliente` con `codpago` se lo pone a **todos** los recibos (el tramo de tarjeta acabaría en la 570). El cobro mixto se reconcilia a mano sobre `reciboclientes`: PUT de importe/`codpago` en los recibos abiertos, DELETE de los pagados que no encajan (borra su pago y su asiento), POST de los que faltan ya pagados y cierre con `pagarFacturaCliente` **sin** `codpago`; se divide y cobra antes de emitir. Cada recibo pagado genera su `pagoclientes` y su asiento 570/572 → 430. Lógica en `FsCobroMixto` (`lib/core/facturascripts/documents/`).
- Si la forma de pago tiene `pagado = 0`, la factura nace sin cobrar: `FsInvoiceService` decide el `ModoPago` por `FsFormaPago.pagado` y, si hace falta, llama a `pagarFacturaCliente/{id}` (idempotente) con `fechapago` y `codpago`.
- MySQL 8.4 autentica con `caching_sha2_password` y `mysql_client` 0.0.27 solo lo consigue con TLS (`MysqlConfig.secure = true`; acepta cualquier certificado); sin TLS falla con "supported only with secure connections" salvo que el usuario use `mysql_native_password`. MySQL 8 rechaza (errno 3823) un `CHECK` sobre columnas con `ON UPDATE CASCADE`: la regla `ref_plato <> ref_ingrediente` la valida `EscandalloRepository`, no el DDL.
- Los tests de `test/integration/**` solo se ejecutan con las variables `TPV_FS_BASE_URL`, `TPV_FS_TOKEN` y `TPV_MYSQL_*` (ver README); sin ellas se omiten. Nunca apuntarlos a la instalación real de FS.
