import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/errors/app_exception.dart';
import '../data/shared_prefs_settings_repository.dart';
import '../domain/app_settings.dart';
import 'pagina_prueba_impresora.dart';
import 'settings_diagnostics.dart';
import 'settings_form.dart';
import 'settings_providers.dart';
import 'settings_widgets.dart';

/// Anchura máxima del formulario en pantallas grandes.
const double kAnchoAjustes = 840;

/// Tiempo máximo que se espera a que terminen las animaciones de salida en
/// [cerrarPantallasApiladas].
const Duration kEsperaCierrePantallas = Duration(seconds: 2);

/// Cierra todas las pantallas apiladas sobre la raíz de [navigator] y espera
/// a que se desmonten (fin de la animación de salida y un frame más).
///
/// Mientras una ruta anima su salida sigue montada y sus widgets siguen
/// escuchando proveedores: si en ese intervalo se libera el modo anterior,
/// lo reconstruirían. Por eso un cambio de modo cierra primero las
/// pantallas y aplica el cambio después.
Future<void> cerrarPantallasApiladas(NavigatorState navigator) async {
  final cerradas = <Route<dynamic>>[];
  navigator.popUntil((route) {
    if (route.isFirst) return true;
    cerradas.add(route);
    return false;
  });
  final pendientes = [
    for (final route in cerradas)
      if (route is TransitionRoute<dynamic>) route.completed,
  ];
  if (pendientes.isEmpty) return;
  try {
    await Future.wait(pendientes).timeout(kEsperaCierrePantallas);
  } on TimeoutException {
    // Se sigue igualmente: el shell libera el modo anterior tras el frame.
  }
  await WidgetsBinding.instance.endOfFrame;
}

/// Pantalla de configuración del dispositivo.
///
/// Edita una copia de los ajustes vigentes; nada se guarda hasta pulsar
/// "Guardar", que valida todo el formulario. Las pruebas de conexión usan
/// los valores escritos (aunque no estén guardados). En modo host los
/// cambios guardados se aplican en caliente al runtime; en modo comandero
/// solo se muestran el dispositivo y la red.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key, this.mesasOcupadas, this.onAbrirEnrutamiento});

  /// Ids de las mesas con comanda abierta (las aporta el shell del host).
  /// No se permite guardar una configuración de mesas que las quite.
  final Set<String> Function()? mesasOcupadas;

  /// Abre la pantalla de enrutamiento de comandas por familias (la aporta el
  /// shell del host: esta feature no depende de `host/`). Si es nulo, no se
  /// muestra el acceso.
  final void Function(BuildContext context)? onAbrirEnrutamiento;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

/// Una zona editable del salón.
final class _ZonaEditable {
  _ZonaEditable(String zona, this.cantidad)
    : nombre = TextEditingController(text: zona);

  final TextEditingController nombre;
  int cantidad;

  ZonaMesas get valor =>
      ZonaMesas(zona: nombre.text.trim(), cantidad: cantidad);
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final List<TextEditingController> _controllers = [];

  bool _inicializado = false;
  bool _modificado = false;
  bool _guardando = false;
  final Set<String> _ocupado = {};

  // Dispositivo y red.
  DeviceRole _rol = DeviceRole.host;
  late final _nombre = _ctrl();
  late final _nombreTpv = _ctrl();
  late final _tcpPort = _ctrl();
  late final _discoveryPort = _ctrl();
  late final _pairing = _ctrl();
  late final _hostManual = _ctrl();

  // ERP.
  bool _erpActivo = false;
  bool _verToken = false;
  late final _erpUrl = _ctrl();
  late final _erpToken = _ctrl();
  PruebaErp? _pruebaErp;

  /// Acción del ERP en curso ('probar', 'cliente' o 'subcuentas'). Las tres
  /// comparten la clave 'erp' de [_ocupado]: mientras una trabaja, las demás
  /// están desactivadas para que no salgan varias peticiones con una clave
  /// que puede estar mal (cada 401/403 cuenta para el bloqueo de IP).
  String? _accionErp;
  String? _resultadoCliente;
  DiagnosticoNivel _nivelCliente = DiagnosticoNivel.ok;

  // MySQL.
  bool _mysqlActivo = false;
  bool _mysqlTls = false;
  bool _verPassword = false;
  late final _myHost = _ctrl();
  late final _myPort = _ctrl();
  late final _myUser = _ctrl();
  late final _myPassword = _ctrl();
  late final _myDatabase = _ctrl();
  String? _resultadoMysql;
  DiagnosticoNivel _nivelMysql = DiagnosticoNivel.ok;
  SchemaInspection? _informeTablas;

  // Fiscal.
  late final _serie = _ctrl();
  late final _cliente = _ctrl();
  late final _almacen = _ctrl();
  late final _pagoEfectivo = _ctrl();
  late final _pagoTarjeta = _ctrl();
  late final _idempresa = _ctrl();
  bool _emitirFacturas = true;
  ModoAsientoZ _modoAsientoZ = ModoAsientoZ.soloDescuadre;
  late final Map<CuentaZ, TextEditingController> _subcuentas = {
    for (final cuenta in CuentaZ.values) cuenta: _ctrl(),
  };
  SubcuentasCierre? _subcuentasResueltas;
  String? _errorSubcuentas;

  // Impresoras.
  late final _impTickets = _ctrl();
  late final _impCocina = _ctrl();
  late final _impBarra = _ctrl();
  PaperWidth _paper = PaperWidth.mm80;
  bool _abrirCajon = true;
  bool _imprimirTicket = true;
  bool _imprimirComanda = true;

  // Mesas.
  final List<_ZonaEditable> _zonas = [];
  String? _errorMesas;

  // Reposición y caja.
  bool _repoAutomatica = true;
  bool _repoEnCierre = true;
  bool _repoSinMinimo = false;
  late final _factor = _ctrl();
  late final _multiplo = _ctrl();
  late final _fondoCaja = _ctrl();

  TextEditingController _ctrl() {
    final controller = TextEditingController();
    _controllers.add(controller);
    return controller;
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    for (final zona in _zonas) {
      zona.nombre.dispose();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Carga y volcado del formulario
  // ---------------------------------------------------------------------------

  void _cargar(AppSettings s) {
    _rol = s.rol ?? DeviceRole.host;
    _nombre.text = s.deviceName;
    _nombreTpv.text = s.fiscal.nombreTpv;
    _tcpPort.text = '${s.red.tcpPort}';
    _discoveryPort.text = '${s.red.discoveryPort}';
    _pairing.text = s.red.pairingCode ?? '';
    _hostManual.text = s.red.hostManual ?? '';

    final erp = s.fsApi;
    _erpActivo = erp != null;
    _erpUrl.text = erp?.baseUrl ?? '';
    _erpToken.text = erp?.token ?? '';

    final mysql = s.mysql;
    _mysqlActivo = mysql != null;
    _myHost.text = mysql?.host ?? '';
    _myPort.text = '${mysql?.port ?? 3306}';
    _myUser.text = mysql?.user ?? '';
    _myPassword.text = mysql?.password ?? '';
    _myDatabase.text = mysql?.database ?? '';
    _mysqlTls = mysql?.secure ?? false;

    final fiscal = s.fiscal;
    _serie.text = fiscal.codserie;
    _cliente.text = fiscal.codcliente;
    _almacen.text = fiscal.codalmacen ?? '';
    _pagoEfectivo.text = fiscal.codpagoEfectivo;
    _pagoTarjeta.text = fiscal.codpagoTarjeta;
    _idempresa.text = fiscal.idempresa?.toString() ?? '';
    _emitirFacturas = fiscal.emitirFacturas;
    _modoAsientoZ = fiscal.modoAsientoZ;
    for (final MapEntry(key: cuenta, value: controller)
        in _subcuentas.entries) {
      controller.text = fiscal.subcuentasOverride[cuenta] ?? '';
    }

    final imp = s.impresion;
    _impTickets.text = formatImpresora(imp.tickets);
    _impCocina.text = formatImpresora(imp.cocina);
    _impBarra.text = formatImpresora(imp.barra);
    _paper = imp.paper;
    _abrirCajon = imp.abrirCajon;
    _imprimirTicket = imp.imprimirTicketAlCobrar;
    _imprimirComanda = imp.imprimirComandaCocina;

    _zonas
      ..clear()
      ..addAll([
        for (final zona in zonasDe(s.mesas))
          _ZonaEditable(zona.zona, zona.cantidad),
      ]);
    for (final zona in _zonas) {
      zona.nombre.addListener(_marcar);
    }

    _repoAutomatica = s.reposicion.automatica;
    _repoEnCierre = s.reposicion.enCierre;
    _repoSinMinimo = s.reposicion.politica.incluirSinMinimo;
    _factor.text = formatDecimalEditable(s.reposicion.politica.factorSinMaximo);
    _multiplo.text = formatDecimalEditable(
      s.reposicion.politica.multiploPedido,
    );
    _fondoCaja.text = formatImporteEditable(s.fondoCajaCents);

    for (final controller in _controllers) {
      controller.addListener(_marcar);
    }
  }

  void _marcar() {
    if (!_modificado && mounted) setState(() => _modificado = true);
  }

  void _cambiar(VoidCallback cambio) {
    setState(() {
      cambio();
      _modificado = true;
    });
  }

  String? _texto(TextEditingController c) {
    final limpio = c.text.trim();
    return limpio.isEmpty ? null : limpio;
  }

  FsApiConfig _erpConfig(FsApiConfig? anterior) => FsApiConfig(
    baseUrl: _erpUrl.text,
    token: _erpToken.text.trim(),
    connectTimeout:
        anterior?.connectTimeout ?? FsApiConfig.defaultConnectTimeout,
    requestTimeout:
        anterior?.requestTimeout ?? FsApiConfig.defaultRequestTimeout,
  );

  MysqlConfig _mysqlConfig(MysqlConfig? anterior) {
    final base = MysqlConfig(
      host: _myHost.text.trim(),
      port: int.parse(_myPort.text.trim()),
      user: _myUser.text.trim(),
      password: _myPassword.text,
      database: _myDatabase.text.trim(),
      secure: _mysqlTls,
    );
    return anterior == null
        ? base
        : base.copyWith(
            connectTimeout: anterior.connectTimeout,
            queryTimeout: anterior.queryTimeout,
          );
  }

  Map<CuentaZ, String> get _overrides => {
    for (final MapEntry(key: cuenta, value: controller) in _subcuentas.entries)
      if (controller.text.trim().isNotEmpty) cuenta: controller.text.trim(),
  };

  List<ZonaMesas> get _zonasValor => [for (final z in _zonas) z.valor];

  /// Vuelca el formulario (ya validado) sobre [s]. Solo toca las secciones
  /// visibles para el rol elegido.
  AppSettings _aplicar(AppSettings s) {
    var r = s.copyWith(rol: _rol, deviceName: _nombre.text.trim());
    final pairing = _texto(_pairing);
    if (_rol == DeviceRole.comandero) {
      final hostManual = _texto(_hostManual);
      return r.copyWith(
        red: s.red.copyWith(
          discoveryPort: int.parse(_discoveryPort.text.trim()),
          pairingCode: pairing,
          borrarPairingCode: pairing == null,
          hostManual: hostManual == null
              ? null
              : normalizarDireccionHost(hostManual),
          borrarHostManual: hostManual == null,
        ),
      );
    }
    final almacen = _texto(_almacen);
    final idempresa = _texto(_idempresa);
    final tickets = parseImpresora(_impTickets.text);
    final cocina = parseImpresora(_impCocina.text);
    final barra = parseImpresora(_impBarra.text);
    r = r.copyWith(
      red: s.red.copyWith(
        tcpPort: int.parse(_tcpPort.text.trim()),
        discoveryPort: int.parse(_discoveryPort.text.trim()),
        pairingCode: pairing,
        borrarPairingCode: pairing == null,
      ),
      fsApi: _erpActivo ? _erpConfig(s.fsApi) : null,
      borrarFsApi: !_erpActivo,
      mysql: _mysqlActivo ? _mysqlConfig(s.mysql) : null,
      borrarMysql: !_mysqlActivo,
      fiscal: s.fiscal.copyWith(
        nombreTpv: _nombreTpv.text.trim(),
        codserie: _serie.text.trim(),
        codcliente: _cliente.text.trim(),
        codalmacen: almacen,
        borrarCodalmacen: almacen == null,
        codpagoEfectivo: _pagoEfectivo.text.trim(),
        codpagoTarjeta: _pagoTarjeta.text.trim(),
        idempresa: idempresa == null ? null : int.parse(idempresa),
        borrarIdempresa: idempresa == null,
        emitirFacturas: _emitirFacturas,
        modoAsientoZ: _modoAsientoZ,
        subcuentasOverride: _overrides,
      ),
      impresion: s.impresion.copyWith(
        tickets: tickets,
        borrarTickets: tickets == null,
        cocina: cocina,
        borrarCocina: cocina == null,
        barra: barra,
        borrarBarra: barra == null,
        paper: _paper,
        abrirCajon: _abrirCajon,
        imprimirTicketAlCobrar: _imprimirTicket,
        imprimirComandaCocina: _imprimirComanda,
      ),
      reposicion: s.reposicion.copyWith(
        automatica: _repoAutomatica,
        enCierre: _repoEnCierre,
        politica: PoliticaReposicion(
          factorSinMaximo: parseDecimal(_factor.text)!,
          multiploPedido: parseDecimal(_multiplo.text)!,
          incluirSinMinimo: _repoSinMinimo,
        ),
      ),
      fondoCajaCents: parseImporteCents(_fondoCaja.text),
      mesas: mesasDesdeZonas(_zonasValor, s.mesas),
    );
    return r;
  }

  // ---------------------------------------------------------------------------
  // Guardar
  // ---------------------------------------------------------------------------

  Future<void> _guardar() async {
    if (_guardando) return;
    final valido = _formKey.currentState?.validate() ?? false;
    final errorMesas = _rol == DeviceRole.host
        ? validarZonas(_zonasValor)
        : null;
    setState(() => _errorMesas = errorMesas);
    if (!valido || errorMesas != null) {
      _mensaje('Revisa los campos marcados en rojo', error: true);
      return;
    }
    final antes = ref.read(appSettingsProvider).value;
    if (antes == null) return;
    if (_rol == DeviceRole.host) {
      final ocupadas = widget.mesasOcupadas?.call() ?? const <String>{};
      final quitadas = mesasQuitadas(
        antes.mesas,
        mesasDesdeZonas(_zonasValor, antes.mesas),
      ).where((mesa) => ocupadas.contains(mesa.id)).toList();
      if (quitadas.isNotEmpty) {
        final nombres = quitadas.map((m) => m.nombre).join(', ');
        setState(
          () => _errorMesas =
              'No se pueden quitar mesas con comanda abierta: $nombres',
        );
        _mensaje('Hay mesas ocupadas que se quitarían: $nombres', error: true);
        return;
      }
    }

    if (!await _confirmarClaveRechazada()) return;
    if (!mounted) return;
    if (_rol != antes.rol) {
      await _guardarCambioDeModo(antes);
      return;
    }

    setState(() => _guardando = true);
    final AppSettings despues;
    try {
      despues = await ref
          .read(appSettingsProvider.notifier)
          .actualizar(_aplicar);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _guardando = false);
        _mensaje('No se pudieron guardar: ${textoDeError(error)}', error: true);
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _guardando = false;
      _modificado = false;
    });
    final resumen = resumirCambios(antes, despues);
    if (resumen.avisos.isEmpty && !resumen.requiereReinicio) {
      _mensaje('Ajustes guardados y aplicados');
    } else {
      await _mostrarResumen(resumen);
    }
  }

  /// Si se va a guardar una clave del ERP que FacturaScripts acaba de
  /// rechazar (401/403), pide confirmación: el runtime del host la usaría
  /// enseguida y cada rechazo cuenta para el bloqueo de IP.
  Future<bool> _confirmarClaveRechazada() async {
    if (_rol != DeviceRole.host || !_erpActivo) return true;
    final config = _erpEscrito();
    if (config == null) return true;
    if (_diagnostics.estadoErp(config) is! FsGuardAuthLocked) return true;
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clave del ERP rechazada'),
        content: const Text(
          'FacturaScripts acaba de rechazar esta clave (o uno de sus '
          'permisos). Si la guardas, el TPV la usará enseguida para '
          'sincronizar, y cada intento fallido cuenta para el bloqueo de IP '
          '(5 en 10 minutos deja sin ERP a todo el local durante 10 '
          'minutos).\n\n¿Guardar de todos modos?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('ajustes-guardar-clave-rechazada'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Guardar igualmente'),
          ),
        ],
      ),
    );
    return confirmado ?? false;
  }

  /// Guarda un cambio de modo. Primero se confirma, después se cierran
  /// TODAS las pantallas apiladas (también esta) y se espera a que se
  /// desmonten; solo entonces se persiste el rol. Así ninguna pantalla del
  /// modo anterior sigue escuchando sus proveedores y los reconstruye
  /// (sondeo UDP y sesión TCP del comandero, runtime del host) cuando el
  /// shell los libera.
  Future<void> _guardarCambioDeModo(AppSettings antes) async {
    // El formulario se vuelca ahora: la página se desmonta antes de guardar.
    final AppSettings nuevos;
    final ResumenCambios resumen;
    try {
      nuevos = _aplicar(antes);
      resumen = resumirCambios(antes, nuevos);
    } on Object catch (error) {
      _mensaje('No se pudieron guardar: ${textoDeError(error)}', error: true);
      return;
    }
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambiar de modo'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Se cerrarán las pantallas abiertas y el dispositivo cambiará '
              'de modo.',
            ),
            for (final aviso in resumen.avisos)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('• $aviso'),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('ajustes-confirmar-cambio-modo'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cambiar de modo'),
          ),
        ],
      ),
    );
    if (confirmado != true || !mounted) return;
    final notifier = ref.read(appSettingsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final colorError = Theme.of(context).colorScheme.error;
    setState(() {
      _guardando = true;
      _modificado = false;
    });
    await cerrarPantallasApiladas(Navigator.of(context));
    try {
      await notifier.actualizar((actuales) {
        if (actuales != antes) {
          throw const ConfigException(
            'Los ajustes cambiaron mientras se guardaban; vuelve a intentarlo',
          );
        }
        return nuevos;
      });
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudo cambiar de modo: ${textoDeError(error)}'),
          backgroundColor: colorError,
        ),
      );
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _mostrarResumen(ResumenCambios resumen) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Ajustes guardados'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            resumen.requiereReinicio
                ? 'Algunos cambios necesitan reiniciar la aplicación para '
                      'aplicarse.'
                : 'Los cambios se han aplicado sin reiniciar.',
          ),
          const SizedBox(height: 8),
          for (final aviso in resumen.avisos)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• $aviso'),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Entendido'),
        ),
      ],
    ),
  );

  Future<void> _restablecer() async {
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restablecer ajustes'),
        content: const Text(
          'Se borrarán todos los ajustes (conexiones, impresoras, mesas...) y '
          'el dispositivo volverá al selector de modo. Se conserva su '
          'identificador.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restablecer'),
          ),
        ],
      ),
    );
    if (confirmado != true || !mounted) return;
    // Como en un cambio de modo: primero se cierran las pantallas apiladas
    // (también esta) y después se borra el rol.
    final notifier = ref.read(appSettingsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final colorError = Theme.of(context).colorScheme.error;
    setState(() => _modificado = false);
    await cerrarPantallasApiladas(Navigator.of(context));
    try {
      await notifier.restablecer();
    } on Object catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudieron restablecer: ${textoDeError(error)}'),
          backgroundColor: colorError,
        ),
      );
    }
  }

  Future<void> _confirmarSalida() async {
    final descartar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cambios sin guardar'),
        content: const Text('¿Salir sin guardar los cambios?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Seguir editando'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (descartar != true || !mounted) return;
    setState(() => _modificado = false);
    Navigator.of(context).pop();
  }

  void _mensaje(String texto, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context)..removeCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(texto),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Diagnósticos
  // ---------------------------------------------------------------------------

  SettingsDiagnostics get _diagnostics => ref.read(settingsDiagnosticsProvider);

  Future<void> _tarea(String clave, Future<void> Function() body) async {
    if (_ocupado.contains(clave)) return;
    setState(() => _ocupado.add(clave));
    try {
      await body();
    } finally {
      if (mounted) setState(() => _ocupado.remove(clave));
    }
  }

  /// Configuración del ERP escrita, o `null` (con aviso) si no es válida.
  FsApiConfig? _erpParaProbar() {
    if (validarUrlErp(_erpUrl.text) != null ||
        validarRequerido(_erpToken.text, maximo: 200) != null) {
      _mensaje('Escribe una URL válida y el token de la API', error: true);
      return null;
    }
    return _erpConfig(ref.read(appSettingsProvider).value?.fsApi);
  }

  /// Puerta única de las acciones del ERP (ver [_accionErp]).
  Future<void> _tareaErp(String accion, Future<void> Function() body) async {
    if (_ocupado.contains('erp')) return;
    _accionErp = accion;
    await _tarea('erp', body);
    _accionErp = null;
  }

  bool get _erpOcupado => _ocupado.contains('erp');

  /// Configuración del ERP escrita si es válida, sin avisos (para mostrar el
  /// estado del cortafuegos mientras se edita).
  FsApiConfig? _erpEscrito() {
    if (validarUrlErp(_erpUrl.text) != null ||
        validarRequerido(_erpToken.text, maximo: 200) != null) {
      return null;
    }
    try {
      return _erpConfig(ref.read(appSettingsProvider).value?.fsApi);
    } on AppException {
      return null;
    }
  }

  Future<void> _probarErp() async {
    final config = _erpParaProbar();
    if (config == null) return;
    if (_diagnostics.estadoErp(config) is FsGuardAuthLocked) {
      // La clave ya fue rechazada: solo se reenvía con confirmación.
      await _reintentarErp();
      return;
    }
    await _lanzarPruebaErp(config);
  }

  /// Reintento explícito tras un 401/403: avisa del bloqueo de IP y, si el
  /// usuario confirma, olvida el rechazo y vuelve a probar.
  Future<void> _reintentarErp() async {
    final config = _erpParaProbar();
    if (config == null || _erpOcupado) return;
    final confirmado = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Probar de nuevo esta clave'),
        content: const Text(
          'FacturaScripts ya rechazó esta clave (o uno de sus permisos). '
          'Cada intento fallido cuenta para el bloqueo de IP: con 5 en 10 '
          'minutos, el ERP deja sin servicio durante 10 minutos a todos los '
          'dispositivos del local, también la facturación.\n\n'
          'Corrige antes la clave o sus permisos en FacturaScripts.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            key: const Key('ajustes-erp-reintentar-confirmar'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Probar de nuevo'),
          ),
        ],
      ),
    );
    if (confirmado != true || !mounted) return;
    _diagnostics.desbloquearClave(config);
    await _lanzarPruebaErp(config);
  }

  Future<void> _lanzarPruebaErp(FsApiConfig config) async {
    await _tareaErp('probar', () async {
      final prueba = await _diagnostics.probarErp(
        config,
        DiagnosticoConfig(
          codserie: _serie.text.trim(),
          codpagoEfectivo: _pagoEfectivo.text.trim(),
          codpagoTarjeta: _pagoTarjeta.text.trim(),
          codalmacen: _almacen.text.trim(),
          codcliente: _cliente.text.trim(),
        ),
      );
      if (mounted) setState(() => _pruebaErp = prueba);
    });
  }

  Future<void> _crearCliente() async {
    final config = _erpParaProbar();
    if (config == null) return;
    final codcliente = _cliente.text.trim();
    if (validarCodigo(codcliente) != null) {
      _mensaje('Escribe el código del cliente genérico', error: true);
      return;
    }
    await _tareaErp('cliente', () async {
      String resultado;
      DiagnosticoNivel nivel;
      try {
        final cliente = await _diagnostics.crearClienteGenerico(
          config,
          codcliente: codcliente,
        );
        resultado =
            'Cliente ${cliente.codcliente} (${cliente.nombre}) disponible';
        nivel = DiagnosticoNivel.ok;
      } on AppException catch (error) {
        resultado = 'No se pudo crear el cliente: ${error.message}';
        nivel = DiagnosticoNivel.error;
      }
      if (mounted) {
        setState(() {
          _resultadoCliente = resultado;
          _nivelCliente = nivel;
        });
      }
    });
  }

  Future<void> _resolverSubcuentas() async {
    final config = _erpParaProbar();
    if (config == null) return;
    final idempresa = int.tryParse(_idempresa.text.trim()) ?? 1;
    await _tareaErp('subcuentas', () async {
      SubcuentasCierre? resueltas;
      String? error;
      try {
        resueltas = await _diagnostics.resolverSubcuentas(
          config,
          idempresa: idempresa,
          fecha: DateTime.now(),
          overrides: {
            for (final MapEntry(:key, :value) in _overrides.entries)
              if (validarSubcuenta(value) == null) key: value,
          },
        );
      } on AppException catch (e) {
        error = e.message;
      }
      if (mounted) {
        setState(() {
          _subcuentasResueltas = resueltas;
          _errorSubcuentas = error;
        });
      }
    });
  }

  MysqlConfig? _mysqlParaProbar() {
    if (validarRequerido(_myHost.text) != null ||
        validarPuerto(_myPort.text) != null ||
        validarRequerido(_myUser.text) != null ||
        validarRequerido(_myDatabase.text) != null) {
      _mensaje('Completa host, puerto, usuario y base de datos', error: true);
      return null;
    }
    return _mysqlConfig(ref.read(appSettingsProvider).value?.mysql);
  }

  Future<void> _probarMysql() async {
    final config = _mysqlParaProbar();
    if (config == null) return;
    await _tarea('mysql', () async {
      String resultado;
      DiagnosticoNivel nivel;
      try {
        await _diagnostics.probarMysql(config);
        resultado = 'Conexión correcta con ${config.database}';
        nivel = DiagnosticoNivel.ok;
      } on AppException catch (error) {
        resultado = error.message;
        nivel = DiagnosticoNivel.error;
      }
      if (mounted) {
        setState(() {
          _resultadoMysql = resultado;
          _nivelMysql = nivel;
        });
      }
    });
  }

  Future<void> _verificarTablas() async {
    final config = _mysqlParaProbar();
    if (config == null) return;
    await _tarea('tablas', () async {
      try {
        final informe = await _diagnostics.verificarTablas(config, crear: true);
        if (mounted) {
          setState(() {
            _informeTablas = informe;
            _resultadoMysql = informe.isComplete
                ? 'Tablas del TPV verificadas'
                : 'El esquema no está completo';
            _nivelMysql = informe.isComplete
                ? DiagnosticoNivel.ok
                : DiagnosticoNivel.aviso;
          });
        }
      } on AppException catch (error) {
        if (mounted) {
          setState(() {
            _informeTablas = null;
            _resultadoMysql = error.message;
            _nivelMysql = DiagnosticoNivel.error;
          });
        }
      }
    });
  }

  Future<void> _imprimirPrueba(
    String destino,
    TextEditingController campo,
  ) async {
    final PrinterEndpoint? endpoint;
    try {
      endpoint = parseImpresora(campo.text);
    } on ValidationException catch (error) {
      _mensaje(error.message, error: true);
      return;
    }
    if (endpoint == null) {
      _mensaje('Escribe la dirección de la impresora de $destino', error: true);
      return;
    }
    final nombre = _nombreTpv.text.trim().isEmpty
        ? _nombre.text.trim()
        : _nombreTpv.text.trim();
    await _tarea('imp-$destino', () async {
      try {
        await _diagnostics.imprimirPrueba(
          endpoint!,
          PaginaPruebaData(
            paper: _paper,
            destino: destino,
            impresora: formatImpresora(endpoint),
            dispositivo: nombre,
            fechaHora: DateFormat('dd/MM/yyyy HH:mm:ss').format(DateTime.now()),
          ),
        );
        if (mounted) _mensaje('Página de prueba enviada a $destino');
      } on AppException catch (error) {
        if (mounted) _mensaje(error.message, error: true);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Interfaz
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final ajustes = ref.watch(appSettingsProvider).value;
    if (ajustes == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ajustes')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_inicializado) {
      _inicializado = true;
      _cargar(ajustes);
    }
    final esHost = _rol == DeviceRole.host;
    final repositorio = ref.watch(settingsRepositoryProvider).value;
    final avisoAlmacen = repositorio is SharedPrefsSettingsRepository
        ? repositorio.avisoAlmacenamiento
        : null;

    return PopScope(
      canPop: !_modificado,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_confirmarSalida());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Ajustes'),
          actions: [
            PopupMenuButton<String>(
              key: const Key('ajustes-menu'),
              onSelected: (_) => unawaited(_restablecer()),
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'restablecer',
                  child: Text('Restablecer ajustes'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                key: const Key('ajustes-guardar'),
                onPressed: _guardando ? null : () => unawaited(_guardar()),
                icon: _guardando
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: const Text('Guardar'),
              ),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: SingleChildScrollView(
            key: const Key('ajustes-scroll'),
            padding: const EdgeInsets.all(16),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kAnchoAjustes),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (avisoAlmacen != null) ...[
                      AvisoDestacado(texto: avisoAlmacen, peligro: true),
                      const SizedBox(height: 16),
                    ],
                    for (final (i, seccion) in [
                      _seccionDispositivo(ajustes, esHost),
                      _seccionRed(esHost),
                      if (esHost) ...[
                        _seccionErp(),
                        _seccionMysql(),
                        _seccionFiscal(),
                        _seccionImpresoras(),
                        _seccionMesas(),
                        _seccionReposicion(),
                        _seccionCaja(),
                      ],
                    ].indexed) ...[
                      if (i > 0) const SizedBox(height: 16),
                      seccion,
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _campo(
    TextEditingController controller, {
    required String clave,
    required String etiqueta,
    String? ayuda,
    String? sufijo,
    FormFieldValidator<String>? validator,
    TextInputType? teclado,
    List<TextInputFormatter>? formatos,
    bool oculto = false,
    Widget? icono,
  }) {
    return TextFormField(
      key: Key('ajustes-$clave'),
      controller: controller,
      decoration: InputDecoration(
        labelText: etiqueta,
        helperText: ayuda,
        helperMaxLines: 3,
        suffixText: sufijo,
        suffixIcon: icono,
      ),
      validator: validator,
      keyboardType: teclado,
      inputFormatters: formatos,
      obscureText: oculto,
      autocorrect: !oculto,
      enableSuggestions: !oculto,
      autovalidateMode: AutovalidateMode.onUserInteraction,
    );
  }

  Widget _numero(
    TextEditingController controller, {
    required String clave,
    required String etiqueta,
    String? ayuda,
    FormFieldValidator<String>? validator,
  }) => _campo(
    controller,
    clave: clave,
    etiqueta: etiqueta,
    ayuda: ayuda,
    validator: validator ?? validarPuerto,
    teclado: TextInputType.number,
    formatos: [FilteringTextInputFormatter.digitsOnly],
  );

  Widget _fila(List<Widget> campos) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 520) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, campo) in campos.indexed) ...[
              if (i > 0) const SizedBox(height: 12),
              campo,
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, campo) in campos.indexed) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: campo),
          ],
        ],
      );
    },
  );

  Widget _interruptor({
    required String clave,
    required String titulo,
    String? subtitulo,
    required bool valor,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    key: Key('ajustes-$clave'),
    contentPadding: EdgeInsets.zero,
    title: Text(titulo),
    subtitle: subtitulo == null ? null : Text(subtitulo),
    value: valor,
    onChanged: (v) => _cambiar(() => onChanged(v)),
  );

  // --- Dispositivo ------------------------------------------------------------

  Widget _seccionDispositivo(AppSettings ajustes, bool esHost) {
    return SeccionAjustes(
      titulo: 'Dispositivo',
      icono: Icons.tablet_android,
      descripcion: 'Identificador: ${ajustes.deviceId}',
      children: [
        SegmentedButton<DeviceRole>(
          key: const Key('ajustes-rol'),
          segments: const [
            ButtonSegment(
              value: DeviceRole.host,
              icon: Icon(Icons.point_of_sale),
              label: Text('Servidor TPV'),
            ),
            ButtonSegment(
              value: DeviceRole.comandero,
              icon: Icon(Icons.phone_android),
              label: Text('Comandero'),
            ),
          ],
          selected: {_rol},
          onSelectionChanged: (seleccion) =>
              _cambiar(() => _rol = seleccion.first),
        ),
        if (ajustes.rol != null && _rol != ajustes.rol)
          const AvisoDestacado(
            texto:
                'Al guardar, el dispositivo cambiará de modo. En modo '
                'servidor se cierran las conexiones de los comanderos.',
          ),
        _campo(
          _nombre,
          clave: 'nombre',
          etiqueta: 'Nombre del dispositivo',
          ayuda: 'Visible en la red local ("Tablet caja", "Camarero 2"...)',
          validator: (v) => validarRequerido(v, maximo: 40),
        ),
        if (esHost)
          _campo(
            _nombreTpv,
            clave: 'nombre-tpv',
            etiqueta: 'Nombre del TPV',
            ayuda:
                'Cabecera de tickets e informes. Vacío = nombre del '
                'dispositivo.',
            validator: (v) =>
                (v?.trim().length ?? 0) > 40 ? 'Máximo 40 caracteres' : null,
          ),
      ],
    );
  }

  // --- Red ----------------------------------------------------------------------

  Widget _seccionRed(bool esHost) {
    return SeccionAjustes(
      titulo: 'Red local',
      icono: Icons.wifi,
      descripcion: esHost
          ? 'Los comanderos encuentran este servidor por broadcast UDP y se '
                'conectan por TCP.'
          : 'El comandero busca el servidor por broadcast UDP; si la red lo '
                'bloquea, indica su dirección a mano.',
      children: [
        _fila([
          if (esHost)
            _numero(
              _tcpPort,
              clave: 'tcp',
              etiqueta: 'Puerto TCP (sesiones)',
              validator: (v) =>
                  validarPuerto(v) ??
                  (v?.trim() == _discoveryPort.text.trim()
                      ? 'Debe ser distinto del puerto UDP'
                      : null),
            ),
          _numero(
            _discoveryPort,
            clave: 'udp',
            etiqueta: 'Puerto UDP (descubrimiento)',
          ),
        ]),
        _campo(
          _pairing,
          clave: 'pairing',
          etiqueta: 'Código de emparejamiento',
          ayuda: esHost
              ? 'Opcional. Si lo fijas, solo se aceptan comanderos que lo '
                    'conozcan.'
              : 'El que exija el servidor (vacío si no exige ninguno).',
          validator: validarPairingCode,
        ),
        if (!esHost)
          _campo(
            _hostManual,
            clave: 'host-manual',
            etiqueta: 'Servidor manual (ip:puerto)',
            ayuda: 'Opcional. Vacío = descubrimiento automático.',
            validator: validarHostManual,
            teclado: TextInputType.url,
          ),
      ],
    );
  }

  // --- ERP ----------------------------------------------------------------------

  Widget _seccionErp() {
    final prueba = _pruebaErp;
    return SeccionAjustes(
      titulo: 'ERP FacturaScripts',
      icono: Icons.cloud_sync_outlined,
      descripcion:
          'API REST v3: facturas de ticket, asientos y pedidos a proveedor. '
          'Cinco claves erróneas en 10 minutos bloquean la IP del TPV en el '
          'ERP: comprueba el token antes de probar.',
      children: [
        _interruptor(
          clave: 'erp-activo',
          titulo: 'Conectar con FacturaScripts',
          valor: _erpActivo,
          onChanged: (v) => _erpActivo = v,
        ),
        if (_erpActivo) ...[
          _campo(
            _erpUrl,
            clave: 'erp-url',
            etiqueta: 'URL base',
            ayuda: 'Por ejemplo http://192.168.1.10/facturascripts',
            validator: validarUrlErp,
            teclado: TextInputType.url,
          ),
          _campo(
            _erpToken,
            clave: 'erp-token',
            etiqueta: 'Token de la API',
            validator: (v) => validarRequerido(v, maximo: 200),
            oculto: !_verToken,
            icono: IconButton(
              tooltip: _verToken ? 'Ocultar' : 'Mostrar',
              icon: Icon(_verToken ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _verToken = !_verToken),
            ),
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              BotonDiagnostico(
                key: const Key('ajustes-erp-probar'),
                texto: 'Probar conexión',
                icono: Icons.network_check,
                ocupado: _erpOcupado && _accionErp == 'probar',
                onPressed: _erpOcupado ? null : () => unawaited(_probarErp()),
              ),
              BotonDiagnostico(
                key: const Key('ajustes-erp-cliente'),
                texto: 'Crear cliente genérico',
                icono: Icons.person_add_alt,
                ocupado: _erpOcupado && _accionErp == 'cliente',
                onPressed: _erpOcupado
                    ? null
                    : () => unawaited(_crearCliente()),
              ),
            ],
          ),
          ?_avisoCortafuegos(),
          if (prueba != null) ListaDiagnostico(items: prueba.items),
          if (_resultadoCliente != null)
            ResultadoLinea(nivel: _nivelCliente, titulo: _resultadoCliente!),
        ],
      ],
    );
  }

  /// Estado del cortafuegos anti-baneo para la clave escrita: si ya fue
  /// rechazada, ofrece el reintento explícito; si la IP está bloqueada,
  /// indica hasta cuándo. `null` si no hay restricciones.
  Widget? _avisoCortafuegos() {
    final config = _erpEscrito();
    if (config == null) return null;
    final hora = DateFormat('dd/MM/yyyy HH:mm');
    return switch (_diagnostics.estadoErp(config)) {
      FsGuardOk() => null,
      FsGuardCooldown(:final until) => AvisoDestacado(
        key: const Key('ajustes-erp-bloqueo-ip'),
        peligro: true,
        texto:
            'FacturaScripts ha bloqueado la IP de este TPV hasta las '
            '${hora.format(until)}. Hasta entonces no se envía ninguna '
            'petición al ERP.',
      ),
      FsGuardAuthLocked(:final since, :final error) => Column(
        key: const Key('ajustes-erp-clave-rechazada'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AvisoDestacado(
            peligro: true,
            texto:
                'FacturaScripts rechazó esta clave '
                '${error.statusCode == 403 ? '(o uno de sus permisos) ' : ''}'
                'el ${hora.format(since)}. No se vuelve a enviar sin tu '
                'confirmación: cada intento fallido cuenta para el bloqueo '
                'de IP (5 en 10 minutos).',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: BotonDiagnostico(
              key: const Key('ajustes-erp-reintentar'),
              texto: 'Probar de nuevo',
              icono: Icons.refresh,
              ocupado: false,
              onPressed: _erpOcupado ? null : () => unawaited(_reintentarErp()),
            ),
          ),
        ],
      ),
    };
  }

  // --- MySQL --------------------------------------------------------------------

  Widget _seccionMysql() {
    return SeccionAjustes(
      titulo: 'MySQL (stock y escandallos)',
      icono: Icons.storage,
      descripcion:
          'Conexión directa a la base de datos de FacturaScripts para '
          'descontar materias primas y leer los escandallos.',
      children: [
        _interruptor(
          clave: 'mysql-activo',
          titulo: 'Conectar con MySQL',
          valor: _mysqlActivo,
          onChanged: (v) => _mysqlActivo = v,
        ),
        if (_mysqlActivo) ...[
          _fila([
            _campo(
              _myHost,
              clave: 'mysql-host',
              etiqueta: 'Servidor',
              validator: validarRequerido,
              teclado: TextInputType.url,
            ),
            _numero(_myPort, clave: 'mysql-puerto', etiqueta: 'Puerto'),
          ]),
          _fila([
            _campo(
              _myUser,
              clave: 'mysql-usuario',
              etiqueta: 'Usuario',
              validator: validarRequerido,
            ),
            _campo(
              _myPassword,
              clave: 'mysql-password',
              etiqueta: 'Contraseña',
              oculto: !_verPassword,
              icono: IconButton(
                tooltip: _verPassword ? 'Ocultar' : 'Mostrar',
                icon: Icon(
                  _verPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _verPassword = !_verPassword),
              ),
            ),
          ]),
          _campo(
            _myDatabase,
            clave: 'mysql-bd',
            etiqueta: 'Base de datos',
            validator: validarRequerido,
          ),
          _interruptor(
            clave: 'mysql-tls',
            titulo: 'Usar TLS',
            subtitulo:
                'Necesario en MySQL 8 la primera vez que un usuario se '
                'autentica con caching_sha2_password.',
            valor: _mysqlTls,
            onChanged: (v) => _mysqlTls = v,
          ),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              BotonDiagnostico(
                key: const Key('ajustes-mysql-probar'),
                texto: 'Probar conexión',
                icono: Icons.network_check,
                ocupado: _ocupado.contains('mysql'),
                onPressed: () => unawaited(_probarMysql()),
              ),
              BotonDiagnostico(
                key: const Key('ajustes-mysql-tablas'),
                texto: 'Crear/verificar tablas tpv_*',
                icono: Icons.table_chart_outlined,
                ocupado: _ocupado.contains('tablas'),
                onPressed: () => unawaited(_verificarTablas()),
              ),
            ],
          ),
          if (_resultadoMysql != null)
            ResultadoLinea(nivel: _nivelMysql, titulo: _resultadoMysql!),
          if (_informeTablas != null) InformeEsquema(informe: _informeTablas!),
        ],
      ],
    );
  }

  // --- Fiscal -------------------------------------------------------------------

  Widget _seccionFiscal() {
    final formas = _pruebaErp?.formasPago ?? const <FsFormaPago>[];
    final almacenes = _pruebaErp?.almacenes ?? const <FsAlmacen>[];
    return SeccionAjustes(
      titulo: 'Fiscal',
      icono: Icons.receipt_long,
      descripcion:
          'Datos con los que se crea la factura simplificada de cada ticket. '
          'Pulsa "Probar conexión" en el ERP para elegir entre los valores '
          'reales.',
      children: [
        _fila([
          _campo(
            _serie,
            clave: 'serie',
            etiqueta: 'Serie',
            ayuda: 'Serie simplificada (p. ej. S)',
            validator: (v) => validarCodigo(v, maximo: 4),
          ),
          _campo(
            _cliente,
            clave: 'cliente',
            etiqueta: 'Cliente genérico',
            validator: validarCodigo,
          ),
        ]),
        _fila([
          if (almacenes.isEmpty)
            _campo(
              _almacen,
              clave: 'almacen',
              etiqueta: 'Almacén',
              ayuda: 'Necesario para facturar y descontar stock',
              validator: (v) => validarCodigo(v, maximo: 4, opcional: true),
            )
          else
            _desplegable(
              clave: 'almacen',
              etiqueta: 'Almacén',
              controller: _almacen,
              opciones: {
                for (final a in almacenes)
                  a.codalmacen:
                      '${a.codalmacen} · '
                      '${a.nombre}',
              },
              obligatorio: false,
            ),
          _numero(
            _idempresa,
            clave: 'idempresa',
            etiqueta: 'Empresa (idempresa)',
            ayuda: 'Vacío = 1',
            validator: validarEnteroPositivoOpcional,
          ),
        ]),
        _fila([
          _formaPago(
            'pago-efectivo',
            'Forma de pago efectivo',
            _pagoEfectivo,
            formas,
          ),
          _formaPago(
            'pago-tarjeta',
            'Forma de pago tarjeta',
            _pagoTarjeta,
            formas,
          ),
        ]),
        _interruptor(
          clave: 'emitir',
          titulo: 'Emitir las facturas',
          subtitulo:
              'Pasa cada factura al estado no editable "Emitida" tras crearla.',
          valor: _emitirFacturas,
          onChanged: (v) => _emitirFacturas = v,
        ),
        Text(
          'Asiento del Cierre Z',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        SegmentedButton<ModoAsientoZ>(
          key: const Key('ajustes-modo-z'),
          segments: const [
            ButtonSegment(
              value: ModoAsientoZ.soloDescuadre,
              label: Text('Solo descuadre'),
            ),
            ButtonSegment(
              value: ModoAsientoZ.resumenCompleto,
              label: Text('Resumen completo'),
            ),
          ],
          selected: {_modoAsientoZ},
          onSelectionChanged: (s) => _cambiar(() => _modoAsientoZ = s.first),
        ),
        if (_modoAsientoZ == ModoAsientoZ.soloDescuadre)
          const AvisoDestacado(
            texto:
                'Recomendado. FacturaScripts ya contabiliza cada factura '
                '(430 → 700/477) y cada cobro (570/572 → 430); el Cierre Z '
                'solo asienta el descuadre de caja (659/759 contra 570). '
                'Sin descuadre no se crea asiento.',
          )
        else
          const AvisoDestacado(
            peligro: true,
            texto:
                'Riesgo de duplicidad: el resumen completo (570/572 contra '
                '700/477) duplica la contabilidad si las facturas ya generan '
                'su asiento, que es lo normal en FacturaScripts. Antes de '
                'contabilizar, el TPV busca facturas del día con asiento y, '
                'si hay alguna, bloquea el asiento Z.',
          ),
        Text('Subcuentas', style: Theme.of(context).textTheme.titleSmall),
        Text(
          'Se resuelven solas en el ejercicio abierto. Escribe una subcuenta '
          'solo para forzarla.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        for (final cuenta in CuentaZ.values) _filaSubcuenta(cuenta),
        Align(
          alignment: Alignment.centerLeft,
          child: BotonDiagnostico(
            key: const Key('ajustes-subcuentas-resolver'),
            texto: 'Resolver automáticamente',
            icono: Icons.account_tree_outlined,
            ocupado: _erpOcupado && _accionErp == 'subcuentas',
            onPressed: _erpActivo && !_erpOcupado
                ? () => unawaited(_resolverSubcuentas())
                : null,
          ),
        ),
        if (_errorSubcuentas != null)
          ResultadoLinea(
            nivel: DiagnosticoNivel.error,
            titulo: 'No se pudieron resolver las subcuentas',
            detalle: _errorSubcuentas,
          ),
        if (_subcuentasResueltas != null)
          ResultadoLinea(
            nivel: DiagnosticoNivel.ok,
            titulo:
                'Ejercicio ${_subcuentasResueltas!.codejercicio}: subcuentas '
                'resueltas',
            detalle: _subcuentasResueltas!.ivaPorCodimpuesto.isEmpty
                ? null
                : 'IVA: ${_subcuentasResueltas!.ivaPorCodimpuesto.entries.map((e) => '${e.key} → ${e.value}').join(', ')}',
          ),
      ],
    );
  }

  Widget _filaSubcuenta(CuentaZ cuenta) {
    final resuelta = _subcuentasResueltas?.porCuenta[cuenta];
    return _campo(
      _subcuentas[cuenta]!,
      clave: 'subcuenta-${cuenta.codcuenta}',
      etiqueta: '${cuenta.codcuenta} · ${cuenta.descripcion}',
      ayuda: resuelta == null ? 'Vacío = automática' : 'Automática: $resuelta',
      validator: validarSubcuenta,
      teclado: TextInputType.number,
      formatos: [FilteringTextInputFormatter.digitsOnly],
    );
  }

  Widget _formaPago(
    String clave,
    String etiqueta,
    TextEditingController controller,
    List<FsFormaPago> formas,
  ) {
    if (formas.isEmpty) {
      return _campo(
        controller,
        clave: clave,
        etiqueta: etiqueta,
        validator: validarCodigo,
      );
    }
    final elegida = formas
        .where((f) => f.codpago == controller.text.trim())
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _desplegable(
          clave: clave,
          etiqueta: etiqueta,
          controller: controller,
          opciones: {
            for (final f in formas)
              f.codpago: '${f.codpago} · ${f.descripcion}',
          },
          obligatorio: true,
        ),
        if (elegida != null)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text(
              elegida.pagado
                  ? 'La factura nace cobrada.'
                  : 'No marca la factura como pagada: el TPV registrará el '
                        'cobro tras crearla.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _desplegable({
    required String clave,
    required String etiqueta,
    required TextEditingController controller,
    required Map<String, String> opciones,
    required bool obligatorio,
  }) {
    final actual = controller.text.trim();
    return DropdownButtonFormField<String>(
      key: Key('ajustes-$clave-${opciones.length}'),
      initialValue: opciones.containsKey(actual) ? actual : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: etiqueta),
      items: [
        for (final MapEntry(:key, :value) in opciones.entries)
          DropdownMenuItem(
            value: key,
            child: Text(value, overflow: TextOverflow.ellipsis),
          ),
      ],
      validator: (v) =>
          obligatorio && (v == null || v.isEmpty) ? 'Elige una opción' : null,
      onChanged: (v) => _cambiar(() => controller.text = v ?? ''),
    );
  }

  // --- Impresoras ---------------------------------------------------------------

  Widget _seccionImpresoras() {
    return SeccionAjustes(
      titulo: 'Impresoras',
      icono: Icons.print_outlined,
      descripcion:
          'Impresoras térmicas ESC/POS en red (puerto 9100 por defecto). '
          'Vacío = sin impresora para ese destino.',
      children: [
        _filaImpresora('tickets', 'Tickets', _impTickets),
        _filaImpresora('cocina', 'Cocina', _impCocina),
        _filaImpresora('barra', 'Barra', _impBarra),
        SegmentedButton<PaperWidth>(
          key: const Key('ajustes-papel'),
          segments: const [
            ButtonSegment(value: PaperWidth.mm58, label: Text('Papel 58 mm')),
            ButtonSegment(value: PaperWidth.mm80, label: Text('Papel 80 mm')),
          ],
          selected: {_paper},
          onSelectionChanged: (s) => _cambiar(() => _paper = s.first),
        ),
        _interruptor(
          clave: 'imprimir-ticket',
          titulo: 'Imprimir el ticket al cobrar',
          valor: _imprimirTicket,
          onChanged: (v) => _imprimirTicket = v,
        ),
        _interruptor(
          clave: 'imprimir-comanda',
          titulo: 'Imprimir las comandas en cocina/barra',
          valor: _imprimirComanda,
          onChanged: (v) => _imprimirComanda = v,
        ),
        _interruptor(
          clave: 'abrir-cajon',
          titulo: 'Abrir el cajón al cobrar en efectivo',
          valor: _abrirCajon,
          onChanged: (v) => _abrirCajon = v,
        ),
        if (_rol == DeviceRole.host && widget.onAbrirEnrutamiento != null)
          _accesoEnrutamiento(widget.onAbrirEnrutamiento!),
      ],
    );
  }

  /// Acceso a la pantalla de enrutamiento por familias. Esa pantalla lee las
  /// impresoras guardadas, así que avisa si hay cambios sin guardar aquí.
  Widget _accesoEnrutamiento(void Function(BuildContext) abrir) {
    final reglas = ref
        .watch(appSettingsProvider)
        .value
        ?.impresion
        .enrutamiento
        .porFamilia
        .length;
    return ListTile(
      key: const Key('ajustes-enrutamiento'),
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.alt_route),
      title: const Text('Enrutamiento por familias'),
      subtitle: Text(
        '${switch (reglas) {
          null || 0 => 'Todas las familias van al destino por defecto',
          1 => '1 familia con destino propio',
          final n => '$n familias con destino propio',
        }}. Elige qué familias salen por cocina y cuáles por barra.',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        if (_modificado) {
          _mensaje(
            'Guarda antes los cambios de esta pantalla: el enrutamiento usa '
            'las impresoras guardadas',
          );
        }
        abrir(context);
      },
    );
  }

  Widget _filaImpresora(
    String clave,
    String destino,
    TextEditingController controller,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _campo(
            controller,
            clave: 'impresora-$clave',
            etiqueta: 'Impresora de $destino (ip:puerto)',
            validator: validarImpresora,
            teclado: TextInputType.url,
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _ocupado.contains('imp-$destino')
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.outlined(
                  key: Key('ajustes-prueba-$clave'),
                  tooltip: 'Ticket de prueba',
                  icon: const Icon(Icons.receipt),
                  onPressed: () =>
                      unawaited(_imprimirPrueba(destino, controller)),
                ),
        ),
      ],
    );
  }

  // --- Mesas --------------------------------------------------------------------

  Widget _seccionMesas() {
    final total = _zonas.fold<int>(0, (suma, z) => suma + z.cantidad);
    final theme = Theme.of(context);
    return SeccionAjustes(
      titulo: 'Mesas',
      icono: Icons.table_restaurant,
      descripcion:
          'Zonas del salón y número de mesas de cada una ($total en total). '
          'Las mesas que ya existen conservan su nombre.',
      children: [
        for (final (i, zona) in _zonas.indexed)
          Row(
            key: ObjectKey(zona),
            children: [
              Expanded(
                child: TextFormField(
                  key: Key('ajustes-zona-$i'),
                  controller: zona.nombre,
                  decoration: const InputDecoration(labelText: 'Zona'),
                  validator: (v) => validarRequerido(v, maximo: 30),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: Key('ajustes-zona-$i-menos'),
                tooltip: 'Una mesa menos',
                onPressed: zona.cantidad > 0
                    ? () => _cambiar(() => zona.cantidad--)
                    : null,
                icon: const Icon(Icons.remove_circle_outline),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${zona.cantidad}',
                  key: Key('ajustes-zona-$i-cantidad'),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: Key('ajustes-zona-$i-mas'),
                tooltip: 'Una mesa más',
                onPressed: zona.cantidad < kMaxMesasPorZona
                    ? () => _cambiar(() => zona.cantidad++)
                    : null,
                icon: const Icon(Icons.add_circle_outline),
              ),
              IconButton(
                tooltip: 'Quitar zona',
                onPressed: () {
                  _cambiar(() => _zonas.removeAt(i));
                  // El campo aún usa el controlador en este frame.
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => zona.nombre.dispose(),
                  );
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('ajustes-zona-nueva'),
            onPressed: () => _cambiar(() {
              final zona = _ZonaEditable('Zona ${_zonas.length + 1}', 1);
              zona.nombre.addListener(_marcar);
              _zonas.add(zona);
            }),
            icon: const Icon(Icons.add),
            label: const Text('Añadir zona'),
          ),
        ),
        if (_errorMesas != null)
          Text(
            _errorMesas!,
            key: const Key('ajustes-mesas-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }

  // --- Reposición ---------------------------------------------------------------

  Widget _seccionReposicion() {
    return SeccionAjustes(
      titulo: 'Reposición',
      icono: Icons.inventory_2_outlined,
      descripcion:
          'Pedidos automáticos a proveedor cuando el stock de una materia '
          'prima cae por debajo de su mínimo.',
      children: [
        _interruptor(
          clave: 'repo-automatica',
          titulo: 'Auditar tras cada descuento de stock',
          valor: _repoAutomatica,
          onChanged: (v) => _repoAutomatica = v,
        ),
        _interruptor(
          clave: 'repo-cierre',
          titulo: 'Auditar y pedir al hacer el Cierre Z',
          valor: _repoEnCierre,
          onChanged: (v) => _repoEnCierre = v,
        ),
        _interruptor(
          clave: 'repo-sin-minimo',
          titulo: 'Reponer también el stock negativo sin mínimo',
          valor: _repoSinMinimo,
          onChanged: (v) => _repoSinMinimo = v,
        ),
        _fila([
          _campo(
            _factor,
            clave: 'repo-factor',
            etiqueta: 'Factor sin máximo',
            ayuda: 'Objetivo = mínimo × factor si no hay máximo útil',
            validator: validarFactor,
            teclado: const TextInputType.numberWithOptions(decimal: true),
          ),
          _campo(
            _multiplo,
            clave: 'repo-multiplo',
            etiqueta: 'Múltiplo de pedido',
            ayuda: 'Se redondea hacia arriba (cajas, sacos...)',
            validator: validarMultiplo,
            teclado: const TextInputType.numberWithOptions(decimal: true),
          ),
        ]),
      ],
    );
  }

  // --- Caja ---------------------------------------------------------------------

  Widget _seccionCaja() {
    return SeccionAjustes(
      titulo: 'Caja',
      icono: Icons.payments_outlined,
      children: [
        _campo(
          _fondoCaja,
          clave: 'fondo',
          etiqueta: 'Fondo de caja',
          ayuda: 'Se propone al abrir el turno',
          sufijo: '€',
          validator: validarImporte,
          teclado: const TextInputType.numberWithOptions(decimal: true),
        ),
      ],
    );
  }
}
