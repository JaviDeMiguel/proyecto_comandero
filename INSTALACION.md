# Guía de instalación de TPV Comandero 1.0.0

Guía práctica para quien instala TPV Comandero en un local. Cubre el ERP (FacturaScripts con el plugin **Hosteleria**), el **servidor TPV** (host: la caja, en un PC o tablet Windows o en una tablet Android) y los **comanderos** (móviles Android de los camareros).

> **Fuera de esta guía:** las **impresoras** (tickets, cocina y barra, cajón) y **VeriFactu**. La app funciona sin impresoras: las comandas y los cobros se registran igual. Para las impresoras, ver [Primer arranque, paso 4, en el README](README.md#primer-arranque).

## Índice

1. [Qué se entrega](#1-qué-se-entrega)
2. [Requisitos](#2-requisitos)
3. [Plugin Hosteleria en FacturaScripts](#3-plugin-hosteleria-en-facturascripts)
4. [Servidor TPV en Windows](#4-servidor-tpv-en-windows)
5. [Servidor TPV en una tablet Android](#5-servidor-tpv-en-una-tablet-android)
6. [Comanderos (móviles)](#6-comanderos-móviles)
7. [Primer arranque y ajustes del servidor](#7-primer-arranque-y-ajustes-del-servidor)
8. [Red del local](#8-red-del-local)
9. [Copias de seguridad](#9-copias-de-seguridad)
10. [Actualizar a una versión nueva](#10-actualizar-a-una-versión-nueva)
11. [Solución de problemas](#11-solución-de-problemas)
12. [Para el desarrollador: generar los paquetes](#12-para-el-desarrollador-generar-los-paquetes)

---

## 1. Qué se entrega

Los genera `tool/empaquetar.ps1` en la carpeta `dist/` (ver [apartado 12](#12-para-el-desarrollador-generar-los-paquetes)):

| Fichero | Para qué |
|---|---|
| `TPV-Comandero-Setup-1.0.0.exe` | Instalador del servidor TPV para Windows 10/11 de 64 bits |
| `tpv-comandero-1.0.0.apk` | App Android firmada: la misma app sirve de servidor (tablet) o de comandero (móvil) |
| `Hosteleria-1.1.zip` | Plugin de FacturaScripts |
| `SHA256SUMS.txt` | Sumas SHA-256 para comprobar que los ficheros llegan íntegros |

Para comprobar un fichero en Windows: `Get-FileHash -Algorithm SHA256 .\tpv-comandero-1.0.0.apk` (PowerShell) y comparar con `SHA256SUMS.txt`.

## 2. Requisitos

**ERP**

- **FacturaScripts 2026.5** o superior con base de datos **MySQL 8** o **MariaDB** (el plugin no funciona con PostgreSQL).
- **PHP 8.1** o superior. La extensión `mysqli` solo hace falta para el botón «Ejecutar ahora» del asistente (crear el usuario de MySQL); sin ella se copian las sentencias SQL y se ejecutan a mano.
- Un ejercicio contable abierto con el plan contable cargado.
- El servidor de FacturaScripts debe ser accesible **desde la red local** por HTTP (puerto 80 o el que use) y, si se usan escandallos y stock, por MySQL (puerto 3306). Si está en un PC con Windows, su cortafuegos debe permitir esas entradas, y MySQL no debe escuchar solo en `127.0.0.1` (`bind-address`).

**Servidor TPV (uno por local)**

- PC o tablet con **Windows 10/11 de 64 bits**, o tablet **Android** (recomendado Android 8 o superior y pantalla de 10").
- Debe estar siempre encendido durante el servicio y con **IP fija** en la red local (ver [Red](#8-red-del-local)).

**Comanderos**

- Móviles **Android** conectados a la **misma red Wi-Fi** que el servidor.

**Red**

- Una red local donde el servidor y los comanderos se vean entre sí: TCP **4040** (comandas) y UDP **4041** (descubrimiento). Las redes Wi-Fi de invitados con «aislamiento de clientes» no sirven.

## 3. Plugin Hosteleria en FacturaScripts

### 3.1. Instalar

1. Entra en FacturaScripts como **administrador**.
2. **Administrador → Plugins → Añadir** y sube `Hosteleria-1.1.zip` (el botón no aparece si la instalación tiene `disable_add_plugins` en su configuración).
3. Activa el plugin **Hosteleria**. Aparece el menú **Hostelería**.

> También se puede copiar la carpeta `Hosteleria` del zip dentro de `Plugins/` de FacturaScripts y activarla. Si se actualiza así (copiando la carpeta), hay que pulsar **Reconstruir** en *Plugins* y después **Reparar el rol** en el asistente: FacturaScripts solo ejecuta la actualización del plugin al activarlo o al subir su ZIP.

### 3.2. Pasar el asistente («Hostelería → Configurar TPV»)

Solo lo ve un administrador. Tiene 22 comprobaciones en cuatro grupos, cada una con estado *Correcto*, *Aviso* o *Error* y un botón para corregirla:

| Grupo | Comprobaciones |
|---|---|
| Conexión con el TPV | API REST · Clave de API «TPV Comandero» · Tablas del TPV · Rol «Hosteleria» |
| Contabilidad y facturación | Ejercicio contable vigente · Cuentas de caja (570) y banco (572) · Subcuentas del cierre Z · Forma de pago en efectivo (TPVEFE) · Forma de pago con tarjeta (TPVTAR) · Cliente genérico (TPV) · Serie de facturas simplificadas (S) · Almacén por defecto |
| Recetas y stock | Recetas válidas para el TPV · Platos con escandallo sin control de stock · Materias primas con control de stock · Productos que son plato y materia prima a la vez · Venta sin stock · Costes de los escandallos · Reposición automática · Stock de cocina y barra |
| Carta y documentos del TPV | Carta y destinos de impresión · Claves del TPV duplicadas |

Pasos:

1. Pulsa **«Crear todo lo que falta»**. Activa la API y crea lo que no exista, sin modificar nada de lo existente:
   - la API REST de FacturaScripts, activada;
   - las tablas `tpv_escandallos` y `tpv_movimientos_stock`;
   - las cuentas bancarias *Caja* (570) y *Banco TPV* (572) y las subcuentas del cierre Z (570, 572, 700, 477, 659 y 759);
   - las formas de pago **`TPVEFE`** «Efectivo TPV» (cuenta 570) y **`TPVTAR`** «Tarjeta TPV» (cuenta 572), las dos marcadas como *pagadas* y con vencimiento a 0 días;
   - el cliente genérico **`TPV`** «CLIENTES VARIOS (TPV)»;
   - la serie **`S`** «Simplificadas»;
   - la **clave de API** con descripción «TPV Comandero»;
   - el rol **Hosteleria**, que da acceso a las pantallas de escandallos, stock, tickets, cierres Z y reposición para asignarlo a los usuarios del local.
2. La **clave de API** es de 32 caracteres, **sin acceso total**: solo los 23 recursos y métodos que usa la app (facturas, recibos, pagos, asientos, catálogo, formas de pago, series, almacenes…). Se ve en su comprobación con un botón **Copiar**. No uses el perfil «Permisos de pruebas» en un local real.
3. Revisa los *Avisos* y *Errores* que queden (recetas, control de stock de platos y materias primas, venta sin stock…) y corrígelos con su botón. Algunos piden confirmación porque modifican datos.
4. **Usuario de MySQL para el TPV** (solo si se van a usar escandallos y descuento de stock):
   - **Usuario**: por defecto `tpv_comandero`.
   - **Desde (patrón de host)**: por defecto `192.168.1.%` (toda la red local). Mejor la IP exacta del servidor TPV, p. ej. `192.168.1.20`.
   - **Exigir conexión cifrada (TLS)**: déjalo marcado.
   - Pulsa **«Generar sentencias»**. Se muestra **una sola vez** una contraseña aleatoria: **cópiala ahora**, no se guarda en ningún sitio.
   - Ejecuta las sentencias con **«Ejecutar ahora»** (necesita que el usuario de MySQL de FacturaScripts tenga `CREATE USER` y `GRANT OPTION`) o cópialas y ejecútalas como `root` de MySQL.
   - Privilegios mínimos que se conceden: `SELECT, INSERT, UPDATE (cantidad, disponible)` en `stocks`; `SELECT, UPDATE (stockfis)` en `variantes`; `SELECT, UPDATE (stockfis, actualizado)` en `productos`; `SELECT` en `productosprov` y `proveedores`; `SELECT, INSERT, UPDATE, DELETE` en `tpv_escandallos`; `SELECT, INSERT` en `tpv_movimientos_stock`. No puede crear ni borrar tablas.
5. La tarjeta **«Valores para la app del TPV»** resume lo que hay que poner en los Ajustes del servidor: URL base, token de la API, serie, cliente genérico, almacén, empresa, formas de pago y los datos de MySQL. Si la URL o el servidor MySQL salen como `localhost`, usa en su lugar la **IP del servidor de FacturaScripts en la red local** (p. ej. `http://192.168.1.10/facturascripts`): desde la tablet `localhost` es la propia tablet.

Opcional: **«Cargar carta de ejemplo»** crea una carta de demostración (restaurante manchego: familias con destino cocina/barra, platos, bebidas, materias primas, proveedores y escandallos). Úsala solo para pruebas o formación: no modifica nada existente, pero añade productos.

Recomendaciones de configuración del ERP: ver [Configuración recomendada en FacturaScripts](README.md#configuración-recomendada-en-facturascripts) en el README.

## 4. Servidor TPV en Windows

1. Ejecuta `TPV-Comandero-Setup-1.0.0.exe` y acepta el aviso de administrador.
2. El asistente (en español) instala en `C:\Program Files\TPV Comandero`, crea el acceso en el menú Inicio y, si marcas la casilla, en el escritorio.
3. El instalador:
   - incluye el runtime de Visual C++ junto al ejecutable (no hay que instalar nada más);
   - añade dos reglas al **cortafuegos de Windows** para `tpv_comandero.exe`: entrada **TCP 4040** y **UDP 4041**, perfiles **privado y dominio**. Por eso la red del local debe estar marcada como **red privada** en Windows (*Configuración → Red e Internet → Wi-Fi/Ethernet → Tipo de perfil de red: Privada*). En una red *pública* los comanderos no lo encontrarán.
4. Abre **TPV Comandero** y sigue el [primer arranque](#7-primer-arranque-y-ajustes-del-servidor).

Instalación desatendida (opcional): `TPV-Comandero-Setup-1.0.0.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART` (añade `/TASKS="desktopicon"` para el acceso del escritorio).

Desinstalar: *Configuración → Aplicaciones → TPV Comandero → Desinstalar*. Quita el programa y las reglas del cortafuegos, pero **conserva los datos** (diario, ajustes y secretos) por si se reinstala. Para borrarlos del todo, elimina a mano la carpeta de datos (ver [Copias de seguridad](#9-copias-de-seguridad)).

Consejos: desactiva la suspensión del equipo durante el horario del local (la app impide que la pantalla se apague mientras está abierta) y evita que Windows Update reinicie en horas de servicio.

## 5. Servidor TPV en una tablet Android

1. Copia `tpv-comandero-1.0.0.apk` a la tablet (cable USB, enlace de descarga o pendrive).
2. Ábrelo desde el gestor de archivos. Android pedirá permiso para **instalar aplicaciones de orígenes desconocidos** para esa app (gestor de archivos o navegador): concédelo e instala. Si Google Play Protect avisa de que la app no es conocida, elige «Instalar de todas formas».
3. Abre **TPV Comandero** y elige **Servidor TPV (tablet)** en el primer arranque.
4. En los ajustes de Android, **desactiva la optimización de batería** para TPV Comandero (*Ajustes → Aplicaciones → TPV Comandero → Batería → Sin restricciones*), para que el sistema no la cierre en segundo plano.

Ten en cuenta que en Android los datos del servidor no se pueden copiar a mano (ver [Copias de seguridad](#9-copias-de-seguridad)). Si el local necesita copias del diario, es preferible el servidor en Windows.

## 6. Comanderos (móviles)

1. Instala el mismo `tpv-comandero-1.0.0.apk` en cada móvil (igual que en el [apartado 5](#5-servidor-tpv-en-una-tablet-android), pasos 1 y 2).
2. En el primer arranque elige **Comandero (móvil)**.
3. En **Ajustes → Dispositivo**, pon como **Nombre del dispositivo** el del camarero (p. ej. «Camarero 2» o «Lucía»): es el nombre que el servidor usa como camarero en los tickets.
4. Con el móvil en la **misma Wi-Fi** que el servidor, la pantalla **Conexión con el host** busca los servidores de la red («Hosts en la red», botón **Buscar de nuevo**). Si hay uno solo, se conecta solo.
5. Si el servidor tiene **código de emparejamiento**, el comandero lo pide («Requiere código»; está en los Ajustes de la caja).
6. Si la red bloquea el descubrimiento (broadcast UDP), usa **Conexión manual**: «Dirección del host» = `IP-del-servidor:4040` (p. ej. `192.168.1.20:4040`), o fíjala en **Ajustes → Red local → Servidor manual (ip:puerto)**.

Las comandas enviadas sin conexión quedan en cola y salen al reconectar; si se cierra la app con envíos pendientes, esas líneas se pierden (el contador de pendientes lo indica).

## 7. Primer arranque y ajustes del servidor

Al abrir la app por primera vez pregunta **«¿Cómo va a funcionar este dispositivo?»**: **Servidor TPV (tablet)** o **Comandero (móvil)**. Solo debe haber **un servidor por local**. El rol se puede cambiar después en *Ajustes → Dispositivo*.

En el servidor, abre **Ajustes** y rellena las secciones en este orden; pulsa **Guardar** al terminar:

1. **Dispositivo**: *Nombre del dispositivo* (p. ej. «Caja») y *Nombre del TPV*, que sale en la cabecera de tickets e informes (por defecto «TPV 1»).
2. **Red local**: puertos *TCP 4040* y *UDP 4041* (no los cambies salvo necesidad: el cortafuegos del instalador abre esos dos) y, opcional, un **Código de emparejamiento** (4 a 32 caracteres sin espacios). Con él solo se conectan los comanderos que lo conozcan: recomendable si la Wi-Fi la usan también clientes.
3. **ERP FacturaScripts**: activa *Conectar con FacturaScripts*, escribe la *URL base* (p. ej. `http://192.168.1.10/facturascripts`, sin `/api/3`) y pega el *Token de la API* del asistente. Pulsa **Probar conexión**: muestra el diagnóstico (serie, formas de pago, almacén, cliente) y carga los almacenes y formas de pago reales. **Cada token incorrecto cuenta para el bloqueo de IP** de FacturaScripts (5 en 10 minutos): cópialo y pégalo, no lo teclees. Si falta el cliente genérico, **Crear cliente genérico**.
4. **MySQL (stock y escandallos)**, opcional: activa *Conectar con MySQL*; *Servidor* (IP del servidor de FacturaScripts, nunca `localhost` desde una tablet), *Puerto* 3306, *Usuario* `tpv_comandero`, la *Contraseña* que mostró el asistente, la *Base de datos* de FacturaScripts y deja **«Usar TLS»** activado (viene así de fábrica: con MySQL 8 y con el usuario creado por el asistente es obligatorio). Pulsa **Probar conexión** («Conexión correcta con …») y **Crear/verificar tablas tpv_\*** («Tablas del TPV verificadas»).
5. **Fiscal**: comprueba *Serie* `S`, *Cliente genérico* `TPV`, *Almacén*, *Empresa* (vacío = 1), formas de pago `TPVEFE` y `TPVTAR`, *Emitir las facturas* activado y *Asiento del Cierre Z* en **«Solo descuadre»** (recomendado: cada factura y cada cobro ya generan su asiento; «Resumen completo» duplicaría la contabilidad). Pulsa **Resolver automáticamente** en *Subcuentas*.
6. **Impresoras**: fuera de esta guía. Si se dejan vacías, no se imprime nada y el resto funciona.
7. **Mesas**: zonas y número de mesas (por defecto «Barra» y «Salón» con las mesas 1 a 12; hasta 99 por zona).
8. **Reposición**: auditoría de mínimos y pedidos automáticos a proveedor (por defecto activada tras cada descuento y en el Cierre Z).
9. **Caja**: *Fondo de caja* que se propone al abrir el turno.

La sala funciona aunque el ERP o MySQL no estén disponibles: facturas, descuentos de stock, pedidos y asientos esperan en la cola (**Sincronización**) y se envían en orden y sin duplicados cuando vuelven.

Prueba final recomendada: desde un comandero, abre una mesa, envía un plato y una bebida, cóbrala en la caja y comprueba en FacturaScripts que aparece la factura de la serie `S` con su recibo pagado (y, con MySQL, el consumo en *Hostelería → Movimientos de stock TPV*).

## 8. Red del local

- **IP fija del servidor TPV**: crea una **reserva DHCP** en el router para la MAC del servidor (preferible) o configura una IP estática fuera del rango DHCP. Si el servidor cambia de IP, los comanderos lo vuelven a buscar solos tras tres fallos de conexión, pero una conexión manual o el patrón de host del usuario de MySQL dejarían de valer.
- Para saber la IP del servidor (la app no la muestra): en Windows, `ipconfig` en una consola (dirección IPv4 del adaptador Wi-Fi o Ethernet); en Android, *Ajustes → Wi-Fi → (red conectada) → Dirección IP*.
- **Puertos**: TCP **4040** (comandas, comandero → servidor) y UDP **4041** (descubrimiento: el comandero envía un sondeo de broadcast a `255.255.255.255:4041` y el servidor le responde). El servidor, además, sale hacia FacturaScripts por HTTP (80/443) y hacia MySQL (3306).
- **Misma Wi-Fi**: servidor y comanderos en la misma red y subred. No uses la red de invitados ni redes con aislamiento de clientes («AP isolation»). Si hay repetidores o malla, deben estar en modo puente (misma subred).
- Si el router o los puntos de acceso filtran el broadcast, el descubrimiento no funciona: usa la conexión manual `IP:4040` en los comanderos.

## 9. Copias de seguridad

**Qué es importante**: el **diario del servidor** (`host_state.json`) guarda las mesas abiertas, los tickets del turno y la **cola de sincronización** (facturas, stock, pedidos y asientos pendientes de enviar a FacturaScripts). Lo que ya se ha sincronizado está en FacturaScripts y se copia con las copias de seguridad del ERP (base de datos MySQL y carpeta de FacturaScripts), que son las que más importan.

**Servidor en Windows**: todos los datos están en

```
%APPDATA%\TPV Comandero\TPV Comandero\
(C:\Users\<usuario>\AppData\Roaming\TPV Comandero\TPV Comandero\)
```

| Fichero | Contenido |
|---|---|
| `host_state.json` (y `host_state.json.bak`) | Diario del servidor: mesas, tickets y cola de sincronización |
| `shared_preferences.json` | Ajustes (sin secretos) |
| `flutter_secure_storage.dat` | Token de la API, contraseña de MySQL y código de emparejamiento, cifrados con la cuenta de Windows (DPAPI): solo se pueden leer con el **mismo usuario en el mismo equipo** |
| `comandero\catalogo_cache.json` | Caché del catálogo (solo en modo comandero; prescindible) |
| `logs\tpv_comandero.log` (y `.1` … `.4`) | Registro para soporte (prescindible en la copia) |

Copia la carpeta entera **con la app cerrada** (por ejemplo, al terminar el día tras el Cierre Z) a un disco externo o a la nube. Para restaurar en otro equipo: instala la app, ciérrala, copia la carpeta en la misma ruta y vuelve a introducir en Ajustes el token de la API, la contraseña de MySQL y el código de emparejamiento (el `.dat` de otro equipo no se puede descifrar).

**Servidor en Android**: los datos están en el almacenamiento privado de la app (`/data/user/0/es.tpvcomandero.app/files/host_state.json` y las preferencias), que **no es accesible** sin herramientas de desarrollador, y **se borran al desinstalar la app o borrar sus datos**. En ese caso la protección es que la cola de sincronización quede vacía al cerrar el día (pantalla *Sincronización*): así todo está ya en FacturaScripts.

**Comanderos**: no guardan nada importante (solo ajustes y la caché del catálogo).

## 10. Actualizar a una versión nueva

- **Windows**: ejecuta el instalador nuevo encima del anterior, sin desinstalar. Cierra la app antes (el instalador la cierra si está abierta). Se conservan los datos y los ajustes.
- **Android** (servidor y comanderos): instala el APK nuevo encima, sin desinstalar. Se conservan los datos. **El APK nuevo debe estar firmado con la misma clave** que el anterior (la de publicación de TPV Comandero, alias `tpv_comandero`): si no, Android dice que la app «no se ha instalado» o que entra en conflicto, y la única salida sería desinstalar, **perdiendo los datos del dispositivo**. Una APK de pruebas firmada con la clave de depuración tampoco se puede instalar encima.
- **Plugin**: sube el ZIP nuevo en *Administrador → Plugins* y vuelve a pasar por el asistente.
- **Orden recomendado**: plugin → servidor → comanderos, fuera del horario de servicio y con la cola de *Sincronización* vacía. Si una versión nueva cambia el protocolo, un comandero antiguo verá «La versión de este comandero no es compatible con la del host. Actualiza la aplicación.»

> Las builds de desarrollo anteriores a la 1.0.0 usaban el identificador `com.example.proyecto_comandero` (y en Windows la carpeta de datos `%APPDATA%\com.example\proyecto_comandero`). La 1.0.0 (`es.tpvcomandero.app`) se instala como una app distinta y **no hereda sus datos**: desinstala la de desarrollo y configura la nueva desde cero.

## 11. Solución de problemas

**Registro para soporte (`tpv_comandero.log`)**

La app escribe un registro de texto (avisos, errores con su traza, sincronización con el ERP; sin tokens ni contraseñas). Se rota al llegar a 2 MB y se conservan 5 ficheros (`tpv_comandero.log`, `.1` … `.4`, el `.4` el más antiguo). Para enviarlo a soporte, copia la carpeta `logs` entera:

- **Windows**: `%APPDATA%\TPV Comandero\TPV Comandero\logs\` (escríbelo en la barra del Explorador).
- **Android**: `Android/data/es.tpvcomandero.app/files/logs/` en el almacenamiento interno. Se ve conectando el dispositivo por USB a un PC (modo *Transferencia de archivos*); en Android 11 o superior los gestores de archivos del propio dispositivo no suelen poder abrir `Android/data`. Se borra al desinstalar la app.

**El comandero no encuentra al servidor** («No se ha encontrado ningún host…» / «No ha respondido ningún host»)

1. ¿El servidor está encendido, con la app abierta y en modo *Servidor TPV*?
2. ¿Están en la **misma Wi-Fi**? (No la de invitados; sin aislamiento de clientes.)
3. Servidor en Windows: ¿la red está marcada como **privada**? ¿Existen las reglas «TPV Comandero - comandas (TCP 4040)» y «TPV Comandero - descubrimiento (UDP 4041)» en *Firewall de Windows Defender → Configuración avanzada → Reglas de entrada*? (Reinstalar las crea de nuevo.) Un antivirus con cortafuegos propio puede bloquearlas: añade una excepción para `C:\Program Files\TPV Comandero\tpv_comandero.exe`.
4. Prueba la **conexión manual** `IP-del-servidor:4040`. Si así conecta, el problema es el broadcast UDP de la red: deja la conexión manual fija (con IP fija del servidor).
5. Si dice que el host exige código, introduce el **código de emparejamiento** de *Ajustes → Red local* del servidor.

**Credenciales del ERP** («FacturaScripts rechazó esta clave…», «FacturaScripts ha bloqueado la IP de este TPV hasta las …»)

- FacturaScripts **bloquea la IP** tras **5 claves inválidas en 10 minutos**. La app no reintenta sola una clave rechazada: corrige el token (cópialo del asistente; comprueba que la clave «TPV Comandero» está activa) y pulsa **Probar de nuevo** solo cuando estés seguro.
- Si la IP está bloqueada, espera a la hora indicada; no sirve insistir.
- Tras un fallo de credenciales la cola se pone en pausa (chip **«Sincronización en pausa»** en la pantalla principal). Corrige los ajustes —al guardar un cambio del ERP o de MySQL la cola se reanuda sola— o abre *Sincronización* y pulsa **Reanudar**.
- «Faltan recursos en la API» o errores de permisos en una operación concreta: en el asistente, **Restablecer permisos** de la clave.
- Una factura en error detiene las siguientes (FacturaScripts exige orden en la serie): revísala en *Sincronización* y reinténtala o descártala.

**MySQL** («…caching_sha2_password completa, que mysql_client solo admite con TLS…», «Fallo TLS…», «Error de red…»)

- Comprueba que **«Usar TLS»** sigue activado en *Ajustes → MySQL* (lo está de fábrica; unos ajustes de una versión anterior conservan el valor con que se guardaron): con MySQL 8 es obligatorio, y siempre si el usuario se creó con «Exigir conexión cifrada». MySQL trae certificados autogenerados; no hay que instalar nada.
- «Error de red» / «Tiempo de espera agotado»: comprueba la IP del servidor (no `localhost`), que MySQL escuche en la red (`bind-address`) y que el cortafuegos del servidor permita el puerto 3306.
- Acceso denegado: el *patrón de host* del usuario (`192.168.1.%` o la IP exacta) debe incluir la IP del servidor TPV. Si se ha perdido la contraseña, genera otra en el asistente marcando «Restablecer la contraseña si la cuenta ya existe».

**«El almacenamiento seguro del dispositivo no está disponible…»**: el token y las contraseñas se están guardando sin cifrar. En Windows suele deberse a un perfil de usuario temporal o con permisos rotos; en Android, a una restauración de copia de otro dispositivo. Borra los datos de la app y vuelve a configurarla.

**La app no arranca en Windows**: reinstala con el instalador. Si persiste, comprueba que el equipo es de 64 bits y Windows 10 o superior.

## 12. Para el desarrollador: generar los paquetes

En el equipo de desarrollo (Windows, con Flutter, Android SDK, Visual Studio con C++ de escritorio e Inno Setup 6: `winget install --id JRSoftware.InnoSetup -e`):

```powershell
powershell -ExecutionPolicy Bypass -File tool\empaquetar.ps1
```

Hace `flutter pub get`, `flutter analyze`, `flutter test`, el APK release, el build de Windows, el instalador (`windows/installer/tpv_comandero.iss`) y el zip del plugin, y deja todo en `dist/` con `SHA256SUMS.txt`. La versión sale de `pubspec.yaml` (`version:`) y la del plugin de `erp/Hosteleria/facturascripts.ini`. Antes de publicar una versión nueva, sube `version:` (el número tras `+` debe crecer siempre para Android).

**Firma de Android**: el APK release se firma con la clave de publicación indicada en `android/key.properties` (ignorado por git; `storePassword`, `keyPassword`, `keyAlias`, `storeFile` con la ruta absoluta del `.jks`). Sin ese fichero la compilación release **falla** a propósito: nunca se firma con la clave de depuración. El almacén y sus contraseñas se guardan **fuera del repositorio**; haz copia de seguridad del `.jks` y de sus contraseñas: sin ellos no se pueden publicar actualizaciones.
