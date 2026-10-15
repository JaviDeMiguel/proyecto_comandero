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
    - `escpos/`: generador (`escpos_builder.dart`, documentos, QR rasterizado en `qr_raster.dart`) y su inversa `escpos_decoder.dart` (Dart puro), que usan la vista previa de la UI y los tests (estos, vía el adaptador estricto `test/core/isolates/escpos/escpos_decoder.dart`).
  - `lib/features/host/`: Lógica exclusiva de la Tablet (Servidor TCP, Host UDP, caja, Cierre Z).
    - Impresión: la fachada `PrintingService` (`application/printing_service.dart`, único `SalaEffects` de impresión y API de la UI) delega en `application/impresion/`: `canal_impresion` (genera en isolate con el perfil de cada impresora, encola y sigue el trabajo), `mapeo_documentos` (dominio → DTO, funciones puras), `comandas_impresion` (comanda, MARCHAR, anulación, reimpresión), `tickets_impresion` (provisional, factura ORIGINAL/DUPLICADO, precuenta, cajón) y `muestras` (documentos de muestra de «Tickets y comandas»).
  - `lib/features/impresion/domain/`: ajustes de formato compartidos por `settings` y `host` (`FormatoImpresion`, `PerfilImpresora` por impresora y `resolverPerfil`, la única regla para elegir el perfil de un endpoint).
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
  - Para no hacer crecer `SalaService` ni `ComanderoController`, las operaciones nuevas van en ficheros `part` con extensiones: `sala_cobro.dart`, `sala_pases.dart` y `sala_precuentas.dart` (extensiones privadas; la API pública sigue en `sala_service.dart`) y `comandero_pases.dart` (extensión `ComanderoPases`).

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
- **Pases y comensales** (`lib/features/sala/protocol/sala_messages.dart`): `comanda.pase.marchar` es una petición fiable (`mesaId`, `pase` ≥ 1, `marchaId` de 1 a 64 caracteres; `comandaId` y `camarero` opcionales), idempotente por `marchaId`: una retransmisión no repite la marcha ni la impresión; si `comandaId` no es la comanda abierta de la mesa, `mesa_sin_comanda` sin efectos, y un host antiguo responde `unknown_type`. `comanda.submit` lleva también `comandaId` opcional: un envío sin líneas (solo comensales) no se aplica si no coincide con la comanda abierta, nunca abre una mesa libre ni consume nº de envío. La capacidad se publica en `SalaSnapshot.pases` (`null` = host anterior: el comandero solo muestra pases y «Marchar» con `pases.activos`). `enrutamiento.changed` (sin payload) avisa de cualquier cambio de la configuración de sala del snapshot, reglas de destino **o pases**, y el comandero vuelve a pedir el snapshot.
- **Impresión:** bytes ESC/POS generados en un isolate y enviados en crudo por TCP al puerto 9100.
  - El `init` es `ESC @`, `ESC t 19` (CP858) y `ESC R 0` (juego internacional de EE. UU.: con «Spain I/II» la impresora sustituiría `# @ [ \ ] { | }`).
  - El QR tributario se genera con `qr` 4.0.0 (Dart puro, dentro del isolate) y se rasteriza para `GS v 0`; el tamaño del módulo se calcula en Dart (`elegirModulo`, `qr_raster.dart`) para que el símbolo mida 30-40 mm (objetivo 35) a 203 o 180 ppp, con 6 mm de margen blanco de diseño (mínimo 2).
  - `PrintQueue` es FIFO por impresora y por defecto reintenta cualquier fallo (`PrintRetryPolicy.always`: mejor una comanda repetida que perdida). Las facturas van con `connectOnly`: solo se repiten si el intento falló al conectar, para que el ORIGINAL no salga dos veces.
  - Reintento manual P2 («Reintentar» en el aviso; `PrintingService.reintentar` sobre `RetryablePrinterPort.reintentar`/`nadaEnviado`): reenvía los mismos bytes solo si ningún intento envió nada; una factura que pudo salir nunca se reenvía, se imprime el siguiente DUPLICADO.

## FacturaScripts (hechos verificados contra la instalación local 2026.5)
- La autenticación de la API es la cabecera **`Token: <api key>`** (también acepta `X-Auth-Token`); no existe `FS-TOKEN`. Cinco tokens inválidos (401/403) en 10 minutos banean la IP (429): tras un fallo de credenciales el cliente se bloquea y no reintenta solo.
- El cuerpo de POST/PUT es **`application/x-www-form-urlencoded`** (el JSON se ignora). Valores: `null` → `"null"`, booleanos `1`/`0`, números con punto, fechas `dd-MM-yyyy`. En PUT se envían solo los campos que cambian. Codificación y lectura tolerante en `lib/core/facturascripts/fs_values.dart`.
- Los recursos de la API son el plural del modelo: `facturaclientes`, `lineafacturaclientes`, `pedidoproveedores`, `lineapedidoproveedores`, `asientos`, `partidas`, `productos`, `variantes`, `stocks`, `formapagos`, `settings`... (`lib/core/facturascripts/fs_resources.dart`). `GET /api/3` los lista.
- Las facturas de ticket se crean con **`POST /api/3/crearFacturaCliente`** (transaccional: totales, numeración, asiento, recibos y stock en una llamada) y los pedidos con **`crearPedidoProveedor`**; los recursos de modelo "en crudo" no recalculan totales ni son atómicos. Idempotencia propia: `numero2` (facturas), `numproveedor` (pedidos), `documento` (asientos).
- Cada factura genera automáticamente su asiento (430 → 700/477) y cada cobro el suyo (570/572 → 430). Por eso el asiento del Cierre Z es, por defecto, solo el **descuadre de caja** (659/759 contra 570); el modo "resumen completo" (570/572/700/477) existe pero duplicaría la contabilidad si las facturas tienen asiento.
- Los totales del ticket se calculan con una réplica del `Calculator` de FS (`lib/core/fiscal/`): redondeo por tipo de IVA, no por línea; precios netos con 5 decimales.
- No existe la tabla `articulos`: el maestro es `productos` + `variantes` (clave de negocio `variantes.referencia`, UNIQUE); el stock por almacén está en `stocks` (`UNIQUE (codalmacen, referencia)`). `tpv_escandallos` tiene FK a `variantes(referencia)` con `ON UPDATE CASCADE`; el diario `tpv_movimientos_stock` no tiene FK (sobrevive a los borrados; el plugin le propaga los renombrados). Al descontar stock por SQL hay que mantener `stocks.disponible`, `variantes.stockfis` y `productos.stockfis`.
- Los platos deben tener `nostock = 1` en FS (FS no les lleva stock y no bloquea la venta); las materias primas `nostock = 0`, y las descuenta el TPV según el escandallo.
- Estado de impresión de la factura simplificada (RD 1619/2012, art. 14) en `Ticket.impresion` (`ImpresionTicket`): un solo ORIGINAL (`facturaOriginalEn` y su QR, que los DUPLICADOS reutilizan aunque cambien los ajustes o el NIF) y después DUPLICADOS numerados. La marca se escribe de forma atómica en el diario (dentro de `HostStateStore.update`) antes de encolar y las facturas de un ticket se imprimen de una en una: nunca salen dos originales. Se deshace si falla la generación o el encolado y se conserva si falla después la impresora (`tickets_impresion.dart`).
- Emisor de los tickets: la última empresa buena leída de FS (`EmpresaEmisora`) se guarda en el diario (`HostSnapshot.empresa`), así que la cabecera se imprime aunque el ERP no responda; se lee al arrancar y con `HostRuntime.refrescarEmpresa()`. Sin NIF del emisor no se imprimen facturas simplificadas (aviso una vez por sesión).
- Precuentas: registro autocontenido en la comanda (`SalaService.emitirPrecuenta`). Al cobrar viajan con el ticket y en las observaciones de la factura; al vaciar la mesa se archivan en `HostSnapshot.precuentasSinCobro`, y el Cierre Z las pasa a `ResumenCierre.precuentasSinCobro` y las imprime en el informe («PRECUENTAS SIN COBRO»).

## Contrato con el plugin `Hosteleria` de FacturaScripts
- **`familias.tpv_destino`** `VARCHAR(10) NULL`: `'cocina'` | `'barra'` | `NULL` (hereda de la madre; si nadie lo define, destino por defecto de la app). Sale en `GET /api/3/familias`. `FsCatalogService` lo lee en `FamiliaCatalogo.destino` de forma tolerante (ausente, vacío o desconocido = `null`; `FamiliaCatalogo.normalizarDestino`). El plugin lo usa también para partir el stock en cocina y barra (`erp/Hosteleria/Lib/TpvStockDestino.php`, misma normalización y herencia por la clave exacta de la madre): si cambia la regla aquí, hay que cambiarla allí.
- **Precedencia** (`EnrutamientoComandas.origenDe`): se recorre la jerarquía desde la familia del artículo hacia sus madres y en cada nivel manda la regla del TPV y después el ERP; si ningún nivel define nada, `porDefecto`. Los ajustes guardan solo las reglas del TPV; el host publica a los comanderos en `SalaSnapshot.enrutamiento` el **efectivo** (`conDestinosErp`, con el ERP aplanado como reglas), que da el mismo destino con o sin catálogo.
- **Tablas `tpv_escandallos` / `tpv_movimientos_stock`**: el DDL de referencia es el de la app (`sql/tpv_schema.sql`, `lib/core/database/schema/tpv_schema.dart`); el plugin genera el mismo (`Lib/TpvSchema.php`) y su XML debe ser equivalente (columnas, tipos, nulos, PK, UNIQUE, FK de `tpv_escandallos` a `variantes(referencia)` con `ON UPDATE CASCADE`, collation de `variantes.referencia`). Sin `CHECK` sobre columnas con `ON UPDATE CASCADE` (MySQL 8, errno 3823). Ningún nombre de índice `tpv_*` puede contener la subcadena `fs_` (el DbUpdater de FS borra esos índices).
- **Lo que el plugin asume de la app** (si cambia aquí, hay que cambiarlo allí): `tpv_movimientos_stock.cantidad` es la variación sumada a `stocks.cantidad` (consumo **negativo**, anulación positiva; motivos `comanda` / `anulacion`); `EscandalloRequest.maxProfundidad = 20` (el plugin rechaza al guardar ciclos y cadenas de más de 20 platos con receta, y lo comprueba en el asistente); coste teórico = hojas × `variantes.coste` (un semielaborado se expande siempre); claves `numero2 = 'TPV-…'` (sus rectificativas pasan a `'RTPV-…'`), `numproveedor = 'TPV-REPO-…'` y `documento = 'Z-…'`; observaciones del ticket «TPV ticket N · Mesa X · Camarero Y · Precuentas nº n hh:mm importe, …» (`BillingService._observacionesDe`; el camarero solo si lo hay y el sufijo de precuentas solo si se emitió alguna, con número, hora y total de cada una; el formato se amplía por el final y lo documentan `XMLView/ListTpvTicket.xml` y `Controller/ListTpvTicket.php`).
- **Permisos que configura el plugin**: la clave de API de producción concede solo los 23 recursos que usa `lib/`: no `lineafacturaclientes` ni `stocks`, que solo usan los tests de integración (los añade el perfil «pruebas»), ni `cuentas`, `proveedores` y `productoproveedores`, que no usa nadie (solo figuran en `FsResources.requeridosPorElTpv`; el diagnóstico no los echa en falta porque `GET /api/3` lista todos los recursos sin mirar los permisos de la clave). El usuario de MySQL tiene `SELECT, INSERT, UPDATE (cantidad, disponible)` en `stocks`, `SELECT, UPDATE (stockfis)` en `variantes`, `SELECT, UPDATE (stockfis, actualizado)` en `productos`, `SELECT` en `productosprov` y `proveedores`, `SELECT, INSERT, UPDATE, DELETE` en `tpv_escandallos` y solo `SELECT, INSERT` en `tpv_movimientos_stock`; sin `CREATE` ni `REFERENCES` (MySQL 8 exige `REFERENCES` de tabla para la FK): las tablas las crea el plugin. Si la app añade una llamada a la API o una sentencia SQL nueva, hay que añadir el permiso en `erp/Hosteleria/Lib/TpvApiPermisos.php` / `TpvMysqlUsuario.php`.
- **Códigos del asistente**, valores por defecto de `FiscalSettings`: serie `S`, cliente `TPV` ("CLIENTES VARIOS (TPV)"), formas de pago `TPVEFE` (Efectivo TPV) y `TPVTAR` (Tarjeta TPV). Los ajustes ya guardados conservan los suyos.
- Cobro mixto (efectivo + tarjeta): `crearFacturaCliente` genera **un** recibo por el total y `pagarFacturaCliente` con `codpago` se lo pone a **todos** los recibos (el tramo de tarjeta acabaría en la 570). El cobro mixto se reconcilia a mano sobre `reciboclientes`: PUT de importe/`codpago` en los recibos abiertos, DELETE de los pagados que no encajan (borra su pago y su asiento), POST de los que faltan ya pagados y cierre con `pagarFacturaCliente` **sin** `codpago`; se divide y cobra antes de emitir. Cada recibo pagado genera su `pagoclientes` y su asiento 570/572 → 430. Lógica en `FsCobroMixto` (`lib/core/facturascripts/documents/`).
- Si la forma de pago tiene `pagado = 0`, la factura nace sin cobrar: `FsInvoiceService` decide el `ModoPago` por `FsFormaPago.pagado` y, si hace falta, llama a `pagarFacturaCliente/{id}` (idempotente) con `fechapago` y `codpago`.
- MySQL 8.4 autentica con `caching_sha2_password` y `mysql_client` 0.0.27 solo lo consigue con TLS (`MysqlConfig.secure = true`; acepta cualquier certificado); sin TLS falla con "supported only with secure connections" salvo que el usuario use `mysql_native_password`. MySQL 8 rechaza (errno 3823) un `CHECK` sobre columnas con `ON UPDATE CASCADE`: la regla `ref_plato <> ref_ingrediente` la valida `EscandalloRepository`, no el DDL.
- Los tests de `test/integration/**` solo se ejecutan con las variables `TPV_FS_BASE_URL`, `TPV_FS_TOKEN` y `TPV_MYSQL_*` (ver README); sin ellas se omiten. Nunca apuntarlos a la instalación real de FS.
