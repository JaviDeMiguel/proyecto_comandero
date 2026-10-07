/// Pruebas de conexión de la pantalla de ajustes: API de FacturaScripts,
/// MySQL directo e impresoras.
///
/// Se prueban los valores ESCRITOS en el formulario (aún sin guardar), con
/// conexiones propias e independientes del runtime del host. En tests se
/// sustituye [settingsDiagnosticsProvider] por un doble.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/mysql_database.dart';
import '../../../core/database/schema/tpv_schema.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/accounting/accounting_models.dart';
import '../../../core/facturascripts/accounting/fs_accounting_service.dart';
import '../../../core/facturascripts/fs_http_api.dart';
import '../../../core/facturascripts/fs_values.dart' show fsFormatDateTime;
import '../../../core/facturascripts/master_data/fs_master_data_service.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/printing/raw_printer_transport.dart';
import '../domain/app_settings.dart';
import 'pagina_prueba_impresora.dart';

export '../../../core/database/schema/tpv_schema.dart' show SchemaInspection;
export '../../../core/facturascripts/accounting/accounting_models.dart'
    show SubcuentasCierre;
export '../../../core/facturascripts/fs_http_guard.dart';
export '../../../core/facturascripts/master_data/fs_master_models.dart'
    show
        DiagnosticoConfig,
        DiagnosticoItem,
        DiagnosticoNivel,
        FsAlmacen,
        FsCliente,
        FsFormaPago;

final Logger _log = appLogger('settings.diagnostics');

/// Resultado de "Probar conexión" con FacturaScripts.
final class PruebaErp extends Equatable {
  const PruebaErp({
    required this.items,
    this.formasPago = const [],
    this.almacenes = const [],
  });

  /// Comprobaciones de `FsMasterDataService.diagnosticar` (API, serie,
  /// formas de pago, almacén, cliente).
  final List<DiagnosticoItem> items;

  /// Formas de pago activas reales (vacío si la API no respondió).
  final List<FsFormaPago> formasPago;

  /// Almacenes activos reales (vacío si la API no respondió).
  final List<FsAlmacen> almacenes;

  /// La API respondió y la clave es válida.
  bool get accesible => items.any(
    (item) => item.codigo == 'api' && item.nivel != DiagnosticoNivel.error,
  );

  @override
  List<Object?> get props => [items, formasPago, almacenes];
}

/// Operaciones de diagnóstico. Salvo [probarErp] (que nunca lanza: los
/// fallos son items de error), todas lanzan [AppException].
///
/// Las tres acciones del ERP ([probarErp], [crearClienteGenerico] y
/// [resolverSubcuentas]) pasan por una sola puerta anti-baneo: tras un
/// 401/403 con una clave, ninguna vuelve a enviarla hasta que el usuario lo
/// pida de forma explícita ([desbloquearClave]); tras un 429 (IP bloqueada)
/// ninguna sale a la red, con ninguna clave, hasta que caduque el bloqueo.
abstract interface class SettingsDiagnostics {
  /// Estado del cortafuegos para [config]: [FsGuardAuthLocked] si esa clave
  /// ya fue rechazada, [FsGuardCooldown] si la IP está bloqueada (afecta a
  /// todas las claves) o [FsGuardOk]. No hace peticiones.
  FsGuardState estadoErp(FsApiConfig config);

  /// Reintento explícito: olvida el rechazo (401/403) de [config] para que
  /// la próxima acción del ERP vuelva a enviarla. No levanta un bloqueo de
  /// IP (429), que caduca solo. Cada intento fallido cuenta para el baneo.
  void desbloquearClave(FsApiConfig config);

  /// `GET /api/3` y comprobación de la configuración fiscal contra el ERP;
  /// si la API responde, también lee las formas de pago y los almacenes.
  Future<PruebaErp> probarErp(FsApiConfig config, DiagnosticoConfig fiscal);

  /// Crea (o devuelve, si existe) el cliente genérico de contado.
  Future<FsCliente> crearClienteGenerico(
    FsApiConfig config, {
    required String codcliente,
  });

  /// Subcuentas del Cierre Z para el ejercicio de [fecha].
  Future<SubcuentasCierre> resolverSubcuentas(
    FsApiConfig config, {
    required int idempresa,
    required DateTime fecha,
    Map<CuentaZ, String> overrides = const {},
  });

  /// Abre la conexión MySQL y hace `SELECT 1`.
  Future<void> probarMysql(MysqlConfig config);

  /// Informe de las tablas `tpv_*`; con [crear] crea las que falten.
  Future<SchemaInspection> verificarTablas(
    MysqlConfig config, {
    bool crear = false,
  });

  /// Envía una página de prueba a la impresora.
  Future<void> imprimirPrueba(PrinterEndpoint endpoint, PaginaPruebaData data);

  /// Cierra las conexiones abiertas. Idempotente.
  Future<void> dispose();
}

/// Construye la conexión MySQL de una prueba.
typedef MysqlDatabaseFactory = MysqlDatabase Function(MysqlConfig config);

/// Construye el cliente de la API de una prueba.
typedef FsHttpApiFactory = FsHttpApi Function(FsApiConfig config);

/// Implementación real.
///
/// Cada clave probada conserva su cliente de la API mientras esté bloqueada:
/// así, tras un 401/403, su cortafuegos impide reintentar con esa clave sin
/// volver a llamar al servidor aunque entre medias se haya probado otra
/// (cinco claves inválidas en diez minutos banean la IP del TPV en
/// FacturaScripts). Un 429 suspende todas las claves hasta que caduque.
final class DefaultSettingsDiagnostics implements SettingsDiagnostics {
  DefaultSettingsDiagnostics({
    this._runner = const SpawningIsolateRunner(),
    RawPrinterTransport? printer,
    MysqlDatabaseFactory? mysqlFactory,
    FsHttpApiFactory? apiFactory,
    DateTime Function()? now,
  }) : _printer = printer ?? EscPosSocketPrinter(),
       _mysqlFactory = mysqlFactory ?? MysqlDatabase.new,
       _apiFactory = apiFactory ?? FsHttpApi.new,
       _now = now ?? DateTime.now;

  final IsolateRunner _runner;
  final RawPrinterTransport _printer;
  final MysqlDatabaseFactory _mysqlFactory;
  final FsHttpApiFactory _apiFactory;
  final DateTime Function() _now;

  /// Cliente de la última configuración usada.
  FsHttpApi? _api;

  /// Clientes de configuraciones anteriores cuyo cortafuegos sigue cerrado
  /// (clave rechazada o IP bloqueada). Se reutilizan si vuelve esa clave.
  final Map<FsApiConfig, FsHttpApi> _bloqueados = {};

  bool _disposed = false;

  List<FsHttpApi> get _clientes => [?_api, ..._bloqueados.values];

  /// Bloqueo de IP vigente (429), que afecta a todas las claves.
  FsGuardCooldown? _suspension() {
    final ahora = _now();
    FsGuardCooldown? vigente;
    for (final api in _clientes) {
      if (api.guardState case final FsGuardCooldown cooldown
          when ahora.isBefore(cooldown.until)) {
        if (vigente == null || cooldown.until.isAfter(vigente.until)) {
          vigente = cooldown;
        }
      }
    }
    return vigente;
  }

  /// `true` si el cortafuegos de [api] no la deja salir a la red.
  bool _cerrado(FsHttpApi api) => switch (api.guardState) {
    FsGuardOk() => false,
    FsGuardAuthLocked() => true,
    FsGuardCooldown(:final until) => _now().isBefore(until),
  };

  FsHttpApi? _clientePara(FsApiConfig config) {
    final actual = _api;
    if (actual != null && actual.config == config) return actual;
    return _bloqueados[config];
  }

  /// Puerta única de las acciones del ERP: devuelve el cliente de [config]
  /// o lanza [ErpApiException] sin tocar la red si la IP está bloqueada.
  FsHttpApi _puerta(FsApiConfig config) {
    if (_disposed) throw StateError('Diagnósticos cerrados');
    final suspension = _suspension();
    if (suspension != null) {
      throw ErpApiException(
        'Acceso a FacturaScripts suspendido hasta '
        '${fsFormatDateTime(suspension.until)} por bloqueo de IP; no se '
        'reintenta automáticamente',
        statusCode: 429,
      );
    }
    final actual = _api;
    if (actual != null && actual.config == config) return actual;
    if (actual != null) {
      if (_cerrado(actual)) {
        _bloqueados[actual.config] = actual;
      } else {
        unawaited(_cerrarApi(actual));
      }
    }
    // Los bloqueos de IP caducados ya no hace falta recordarlos.
    _bloqueados.removeWhere((clave, api) {
      if (clave == config || _cerrado(api)) return false;
      unawaited(_cerrarApi(api));
      return true;
    });
    return _api = _bloqueados.remove(config) ?? _apiFactory(config);
  }

  static Future<void> _cerrarApi(FsHttpApi api) async {
    try {
      await api.close();
    } on Object catch (error, stackTrace) {
      _log.fine('Error al cerrar el cliente de diagnóstico', error, stackTrace);
    }
  }

  @override
  FsGuardState estadoErp(FsApiConfig config) {
    if (_disposed) return const FsGuardOk();
    final suspension = _suspension();
    if (suspension != null) return suspension;
    return switch (_clientePara(config)?.guardState) {
      final FsGuardAuthLocked rechazo => rechazo,
      _ => const FsGuardOk(),
    };
  }

  @override
  void desbloquearClave(FsApiConfig config) {
    final api = _clientePara(config);
    if (api != null && api.guardState is FsGuardAuthLocked) {
      _log.info('Reintento explícito con una clave rechazada');
      api.resetGuard();
    }
  }

  @override
  Future<PruebaErp> probarErp(
    FsApiConfig config,
    DiagnosticoConfig fiscal,
  ) async {
    final FsHttpApi api;
    try {
      api = _puerta(config);
    } on ErpApiException catch (error) {
      return PruebaErp(
        items: [
          DiagnosticoItem(
            codigo: 'api',
            nivel: DiagnosticoNivel.error,
            titulo: 'API de FacturaScripts no accesible',
            detalle: error.message,
          ),
        ],
      );
    }
    final servicio = FsMasterDataService(api);
    final items = await servicio.diagnosticar(fiscal);
    final prueba = PruebaErp(items: items);
    // Si el diagnóstico acabó en un 401/403/429, no se insiste.
    if (!prueba.accesible || _cerrado(api)) return prueba;
    try {
      final formas = await servicio.formasPago();
      final almacenes = await servicio.almacenes();
      return PruebaErp(
        items: items,
        formasPago: [
          for (final forma in formas)
            if (forma.activa) forma,
        ],
        almacenes: [
          for (final almacen in almacenes)
            if (almacen.activo) almacen,
        ],
      );
    } on AppException catch (error) {
      _log.info('Sin formas de pago ni almacenes: ${error.message}');
      return prueba;
    }
  }

  @override
  Future<FsCliente> crearClienteGenerico(
    FsApiConfig config, {
    required String codcliente,
  }) async =>
      FsMasterDataService(_puerta(config))
          .crearClienteGenerico(codcliente: codcliente);

  @override
  Future<SubcuentasCierre> resolverSubcuentas(
    FsApiConfig config, {
    required int idempresa,
    required DateTime fecha,
    Map<CuentaZ, String> overrides = const {},
  }) async => FsAccountingService(_puerta(config))
      .resolverSubcuentas(fecha, idempresa: idempresa, overrides: overrides);

  @override
  Future<void> probarMysql(MysqlConfig config) =>
      _conMysql(config, (db) => db.ping());

  @override
  Future<SchemaInspection> verificarTablas(
    MysqlConfig config, {
    bool crear = false,
  }) => _conMysql(config, (db) {
    final migrator = TpvSchemaMigrator(db);
    return crear ? migrator.ensure() : migrator.inspect();
  });

  Future<T> _conMysql<T>(
    MysqlConfig config,
    Future<T> Function(MysqlDatabase db) body,
  ) async {
    if (_disposed) throw StateError('Diagnósticos cerrados');
    final db = _mysqlFactory(config);
    try {
      return await body(db);
    } finally {
      try {
        await db.close();
      } on Object catch (error, stackTrace) {
        _log.fine('Error al cerrar la conexión de prueba', error, stackTrace);
      }
    }
  }

  @override
  Future<void> imprimirPrueba(
    PrinterEndpoint endpoint,
    PaginaPruebaData data,
  ) async {
    if (_disposed) throw StateError('Diagnósticos cerrados');
    final Uint8List bytes;
    try {
      bytes = await _runner.run(
        generarPaginaPrueba,
        data,
        debugName: 'escpos-prueba',
      );
    } on AppException {
      rethrow;
    } on Object catch (error) {
      throw PrinterException(
        'No se pudo generar la página de prueba',
        cause: error,
      );
    }
    await _printer.send(endpoint, bytes);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final clientes = _clientes;
    _api = null;
    _bloqueados.clear();
    for (final api in clientes) {
      await _cerrarApi(api);
    }
  }
}

/// Diagnósticos de la pantalla de ajustes.
final settingsDiagnosticsProvider = Provider<SettingsDiagnostics>((ref) {
  final diagnostics = DefaultSettingsDiagnostics();
  ref.onDispose(() => unawaited(diagnostics.dispose()));
  return diagnostics;
});
