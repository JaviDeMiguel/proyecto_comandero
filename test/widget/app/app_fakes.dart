/// Dobles compartidos por los tests del shell y de la pantalla de ajustes.
library;

import 'dart:async';

import 'package:proyecto_comandero/app/platform/host_platform_hooks.dart';
import 'package:proyecto_comandero/core/database/schema/tpv_schema.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/application/settings_service.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/pagina_prueba_impresora.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';

/// Registra activaciones y liberaciones de los recursos de plataforma.
final class FakeHostPlatformHooks implements HostPlatformHooks {
  final List<String> llamadas = [];
  bool activo = false;

  @override
  Future<void> activar() async {
    llamadas.add('activar');
    activo = true;
  }

  @override
  Future<void> liberar() async {
    llamadas.add('liberar');
    activo = false;
  }
}

/// Repositorio cuyos datos están "corruptos" hasta que se borran.
///
/// Con [identidad], la identidad sigue siendo legible en el JSON en crudo
/// (solo otra sección está corrupta).
final class CorruptSettingsRepository
    implements SettingsRepository, IdentidadRescatable {
  CorruptSettingsRepository({this.identidad});

  final IdentidadDispositivo? identidad;
  bool corrupto = true;
  AppSettings? guardados;
  int clears = 0;

  @override
  Future<IdentidadDispositivo?> leerIdentidad() async =>
      corrupto ? identidad : null;

  @override
  Future<AppSettings?> load() async {
    if (corrupto) {
      throw const ConfigException("Ajustes 'red': puerto fuera de rango");
    }
    return guardados;
  }

  @override
  Future<void> save(AppSettings settings) async {
    corrupto = false;
    guardados = settings;
  }

  @override
  Future<void> clear() async {
    clears++;
    corrupto = false;
    guardados = null;
  }
}

/// Formas de pago del ERP: la de efectivo es la que crea el asistente del
/// plugin de hostelería (`TPVEFE`, valor por defecto de los ajustes).
const List<FsFormaPago> kFormasPrueba = [
  FsFormaPago(codpago: 'TPVEFE', descripcion: 'Efectivo TPV', pagado: true),
  FsFormaPago(codpago: 'TARJ', descripcion: 'Tarjeta'),
  FsFormaPago(codpago: 'TRANS', descripcion: 'Transferencia'),
];

/// Diagnósticos en memoria.
final class FakeSettingsDiagnostics implements SettingsDiagnostics {
  final List<String> llamadas = [];
  final List<(PrinterEndpoint, PaginaPruebaData)> impresiones = [];
  FsApiConfig? ultimoErp;
  MysqlConfig? ultimoMysql;

  PruebaErp pruebaErp = const PruebaErp(
    items: [
      DiagnosticoItem(
        codigo: 'api',
        nivel: DiagnosticoNivel.ok,
        titulo: 'API accesible',
        detalle: 'La clave es válida.',
      ),
      DiagnosticoItem(
        codigo: 'cliente',
        nivel: DiagnosticoNivel.error,
        titulo: 'Cliente genérico',
        detalle: "El cliente 'TPV' no existe.",
      ),
    ],
    formasPago: kFormasPrueba,
    almacenes: [FsAlmacen(codalmacen: 'ALG', nombre: 'Almacén general')],
  );

  /// Error que lanzarán las operaciones de MySQL e impresora.
  AppException? fallo;

  SchemaInspection informe = SchemaInspection(
    variantesExists: true,
    referencia: const ReferenciaColumnInfo(
      columnType: 'varchar(30)',
      charset: 'utf8mb4',
      collation: 'utf8mb4_unicode_520_ci',
      hasUniqueIndex: true,
    ),
    existingTables: TpvSchema.tables.toSet(),
    schema: const TpvSchema(),
  );

  bool disposed = false;

  /// Si no es `null`, las acciones del ERP esperan a que se complete (para
  /// comprobar que no se lanzan varias a la vez).
  Completer<void>? esperaErp;

  Future<void> _esperarErp() async {
    final espera = esperaErp;
    if (espera != null) await espera.future;
  }

  /// Estado del cortafuegos que devuelve [estadoErp] para cada clave.
  final Map<FsApiConfig, FsGuardState> estados = {};

  @override
  FsGuardState estadoErp(FsApiConfig config) =>
      estados[config] ?? const FsGuardOk();

  @override
  void desbloquearClave(FsApiConfig config) {
    llamadas.add('desbloquear');
    estados.remove(config);
  }

  @override
  Future<PruebaErp> probarErp(
    FsApiConfig config,
    DiagnosticoConfig fiscal,
  ) async {
    llamadas.add('probarErp');
    ultimoErp = config;
    await _esperarErp();
    return pruebaErp;
  }

  @override
  Future<FsCliente> crearClienteGenerico(
    FsApiConfig config, {
    required String codcliente,
  }) async {
    llamadas.add('crearCliente:$codcliente');
    await _esperarErp();
    final error = fallo;
    if (error != null) throw error;
    return FsCliente(codcliente: codcliente, nombre: 'CLIENTES VARIOS (TPV)');
  }

  @override
  Future<SubcuentasCierre> resolverSubcuentas(
    FsApiConfig config, {
    required int idempresa,
    required DateTime fecha,
    Map<CuentaZ, String> overrides = const {},
  }) async {
    llamadas.add('subcuentas:$idempresa');
    await _esperarErp();
    return SubcuentasCierre(
      codejercicio: '2026',
      porCuenta: {
        for (final cuenta in CuentaZ.values)
          cuenta: overrides[cuenta] ?? '${cuenta.codcuenta}0000000',
      },
      ivaPorCodimpuesto: const {'IVA10': '4770000010'},
    );
  }

  @override
  Future<void> probarMysql(MysqlConfig config) async {
    llamadas.add('probarMysql');
    ultimoMysql = config;
    final error = fallo;
    if (error != null) throw error;
  }

  @override
  Future<SchemaInspection> verificarTablas(
    MysqlConfig config, {
    bool crear = false,
  }) async {
    llamadas.add('tablas:$crear');
    final error = fallo;
    if (error != null) throw error;
    return informe;
  }

  @override
  Future<void> imprimirPrueba(
    PrinterEndpoint endpoint,
    PaginaPruebaData data,
  ) async {
    llamadas.add('imprimir');
    final error = fallo;
    if (error != null) throw error;
    impresiones.add((endpoint, data));
  }

  @override
  Future<void> dispose() async => disposed = true;
}
