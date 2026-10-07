/// Contabilidad del Cierre Z sobre la API: resolución de subcuentas por
/// ejercicio y asiento idempotente cabecera + partidas.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../money/money.dart';
import '../fs_api.dart';
import '../fs_values.dart';
import 'accounting_models.dart';

/// Servicio contable del Cierre Z.
///
/// Los recursos `asientos` y `partidas` no tienen transacción por petición
/// ni validan el cuadre, y `asientos.importe` no se recalcula al añadir
/// partidas: todo eso lo garantiza este servicio (DESIGN_BRIEF §5).
final class FsAccountingService {
  /// [now] permite caducar la caché de subcuentas en tests; por defecto la
  /// caché de un ejercicio dura [cacheTtl].
  FsAccountingService(this._api, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const String _asientos = 'asientos';
  static const String _partidas = 'partidas';
  static const String _subcuentas = 'subcuentas';
  static const String _ejercicios = 'ejercicios';
  static const String _impuestos = 'impuestos';
  static const String _facturas = 'facturaclientes';

  /// Tiempo tras el que se vuelve a resolver un ejercicio (el gestor puede
  /// cargar o cambiar el plan contable sin reiniciar el TPV).
  static const Duration cacheTtl = Duration(hours: 12);

  final FsApi _api;
  final DateTime Function() _now;
  final Logger _log = appLogger('facturascripts.accounting');

  final List<_Ejercicio> _ejerciciosConocidos = [];
  final Map<String, _CacheSubcuentas> _cache = {};
  final Set<String> _subcuentasVerificadas = {};

  /// Olvida todo lo resuelto (cambio de servidor o de configuración).
  void invalidarCache() {
    _ejerciciosConocidos.clear();
    _cache.clear();
    _subcuentasVerificadas.clear();
  }

  /// Resuelve las subcuentas del Cierre Z en el ejercicio abierto que
  /// contiene [fecha] para la empresa [idempresa].
  ///
  /// Cada papel se resuelve como la primera subcuenta (`codsubcuenta ASC`) de
  /// la cuenta `570/572/700/477/659/759`; el IVA por tipo sale de
  /// `impuestos.codsubcuentarep`. [overrides] fuerza un `codsubcuenta`
  /// concreto por papel (ajustes del TPV); se comprueba que exista en el
  /// ejercicio. Lanza [ConfigException] detallando qué falta.
  Future<SubcuentasCierre> resolverSubcuentas(
    DateTime fecha, {
    required int idempresa,
    Map<CuentaZ, String> overrides = const {},
  }) async {
    try {
      final ejercicio = await _ejercicioPara(fecha, idempresa);
      final base = await _subcuentasBase(ejercicio.codejercicio);
      if (overrides.isEmpty) return base;

      final porCuenta = Map<CuentaZ, String>.of(base.porCuenta);
      for (final MapEntry(key: cuenta, value: codsubcuenta)
          in overrides.entries) {
        await _comprobarSubcuenta(ejercicio.codejercicio, cuenta, codsubcuenta);
        porCuenta[cuenta] = codsubcuenta;
      }
      return SubcuentasCierre(
        codejercicio: base.codejercicio,
        porCuenta: Map.unmodifiable(porCuenta),
        ivaPorCodimpuesto: base.ivaPorCodimpuesto,
      );
    } on FormatException catch (error) {
      throw ErpApiException(
        'Respuesta de FacturaScripts no interpretable al resolver '
        'subcuentas: ${error.message}',
        statusCode: 200,
        cause: error,
      );
    }
  }

  /// Contabiliza el asiento o lo reanuda. Protocolo (sin transacción en el
  /// servidor):
  ///
  /// 1. `GET asientos?filter[documento]=clave`. Si existe y sus partidas
  ///    coinciden en número y sumas → hecho (`yaExistia`). Si existe pero
  ///    está a medias → `DELETE asientos/{id}` (borra las partidas en
  ///    cascada) y se recrea.
  /// 2. `POST asientos` con `importe` = suma del Debe.
  /// 3. `POST partidas` por línea. Si una falla se intenta `DELETE` del
  ///    asiento (compensación) y se relanza el error indicando el
  ///    `idasiento` y si la compensación funcionó.
  /// 4. `GET partidas` para verificar.
  ///
  /// Lanza [ValidationException] si el asiento no cuadra, [ErpApiException]
  /// ante fallos de la API.
  Future<ResultadoAsiento> contabilizarOReanudar(AsientoZ asiento) async {
    if (!asiento.cuadrado) {
      throw ValidationException(
        "Asiento '${asiento.clave}' descuadrado: Debe "
        '${formatCents(asiento.debeTotalCents)} ≠ Haber '
        '${formatCents(asiento.haberTotalCents)}',
      );
    }
    try {
      return await _contabilizarOReanudar(asiento);
    } on FormatException catch (error) {
      throw ErpApiException(
        'Respuesta de FacturaScripts no interpretable al contabilizar '
        "'${asiento.clave}': ${error.message}",
        statusCode: 200,
        cause: error,
      );
    }
  }

  /// ¿Hay facturas de la serie en esa fecha que ya generaron asiento? Si las
  /// hay, un asiento Z de "resumen completo" duplicaría ventas e IVA.
  ///
  /// El filtro `fecha` acepta tanto `yyyy-MM-dd` como `dd-MM-yyyy`
  /// (comprobado en el sandbox); se envía ISO, la forma más segura.
  Future<bool> hayFacturasConAsiento({
    required DateTime fecha,
    required String codserie,
  }) async {
    final page = await _api.list(
      _facturas,
      filters: {
        'fecha': fsFormatIsoDate(fecha),
        'codserie': codserie,
        'idasiento_notnull': 1,
      },
      limit: 1,
    );
    return (page.totalCount ?? page.items.length) > 0;
  }

  // ---------------------------------------------------------------------------
  // Asiento

  Future<ResultadoAsiento> _contabilizarOReanudar(AsientoZ asiento) async {
    final existente = await _buscarAsiento(asiento.clave);
    if (existente != null) {
      final idasiento = existente.fsRequireInt('idasiento');
      final partidas = await _partidasDe(idasiento);
      if (_coinciden(asiento, partidas)) {
        _log.info('Asiento ${asiento.clave} ya existía completo ($idasiento)');
        return ResultadoAsiento(
          idasiento: idasiento,
          numero: existente.fsInt('numero'),
          yaExistia: true,
          partidasCreadas: 0,
          verificado: true,
        );
      }
      _log.warning(
        'Asiento ${asiento.clave} ($idasiento) a medias: '
        '${partidas.length}/${asiento.lineas.length} partidas; se recrea',
      );
      await _api.delete(_asientos, idasiento);
    }

    final cabecera = await _api.create(_asientos, {
      'fecha': fsFormatDate(asiento.fecha),
      'concepto': asiento.concepto,
      'documento': asiento.clave,
      'importe': _importe(asiento.debeTotalCents),
    });
    final idasiento = cabecera.fsRequireInt('idasiento');
    _log.fine('Asiento ${asiento.clave} creado con id $idasiento');

    var creadas = 0;
    for (final linea in asiento.lineas) {
      try {
        await _api.create(_partidas, {
          'idasiento': idasiento,
          'codsubcuenta': linea.codsubcuenta,
          'concepto': linea.concepto,
          'documento': asiento.clave,
          'debe': _importe(linea.debeCents),
          'haber': _importe(linea.haberCents),
          'baseimponible': ?_importeOpcional(linea.baseCents),
          'iva': ?linea.ivaPct,
        });
        creadas++;
      } on ErpApiException catch (error) {
        throw await _compensar(asiento, idasiento, creadas, error);
      } on FormatException catch (error) {
        throw await _compensar(
          asiento,
          idasiento,
          creadas,
          ErpApiException(
            'Respuesta no interpretable al crear la partida '
            '${linea.codsubcuenta}: ${error.message}',
            statusCode: 200,
            cause: error,
          ),
        );
      }
    }

    final List<FsRecord> partidas;
    try {
      partidas = await _partidasDe(idasiento);
    } on ErpApiException catch (error) {
      if (!error.isTransient) rethrow;
      // Todo se creó; solo falló la lectura de comprobación. La próxima
      // reanudación la repetirá.
      _log.warning('Asiento $idasiento creado pero sin verificar: $error');
      return ResultadoAsiento(
        idasiento: idasiento,
        numero: cabecera.fsInt('numero'),
        yaExistia: false,
        partidasCreadas: creadas,
        verificado: false,
      );
    }
    if (!_coinciden(asiento, partidas)) {
      throw await _compensar(
        asiento,
        idasiento,
        creadas,
        ErpApiException(
          'El asiento $idasiento no coincide con lo enviado tras crearlo '
          '(${partidas.length} partidas en FS, ${asiento.lineas.length} '
          'enviadas)',
          statusCode: 200,
        ),
      );
    }
    return ResultadoAsiento(
      idasiento: idasiento,
      numero: cabecera.fsInt('numero'),
      yaExistia: false,
      partidasCreadas: creadas,
      verificado: true,
    );
  }

  Future<FsRecord?> _buscarAsiento(String clave) async {
    final page = await _api.list(
      _asientos,
      filters: {'documento': clave},
      sort: const {'idasiento': FsSortOrder.asc},
      limit: 2,
    );
    if (page.items.length > 1) {
      final ids = [for (final item in page.items) item.fsString('idasiento')];
      throw ValidationException(
        "Clave '$clave' duplicada en FacturaScripts: asientos $ids. "
        'Hay que resolverlo a mano antes de continuar',
      );
    }
    return page.items.isEmpty ? null : page.items.first;
  }

  Future<List<FsRecord>> _partidasDe(int idasiento) => _api.listAll(
    _partidas,
    filters: {'idasiento': idasiento},
    sortBy: 'idpartida',
  );

  /// Mismo número de partidas y mismas sumas de Debe y Haber (en céntimos).
  static bool _coinciden(AsientoZ asiento, List<FsRecord> partidas) {
    if (partidas.length != asiento.lineas.length) return false;
    var debe = 0;
    var haber = 0;
    for (final partida in partidas) {
      debe += centsFromDecimal(partida.fsDouble('debe') ?? 0);
      haber += centsFromDecimal(partida.fsDouble('haber') ?? 0);
    }
    return debe == asiento.debeTotalCents && haber == asiento.haberTotalCents;
  }

  Future<ErpApiException> _compensar(
    AsientoZ asiento,
    int idasiento,
    int creadas,
    ErpApiException original,
  ) async {
    String compensacion;
    try {
      final borrado = await _api.delete(_asientos, idasiento);
      compensacion = borrado
          ? 'asiento $idasiento borrado'
          : 'asiento $idasiento ya no existía';
    } on ErpApiException catch (error) {
      compensacion =
          'NO se pudo borrar el asiento $idasiento (${error.message}); '
          'la próxima reanudación lo recreará';
    }
    _log.severe(
      "Fallo al contabilizar '${asiento.clave}' tras $creadas partidas: "
      '${original.message}. Compensación: $compensacion',
    );
    return ErpApiException(
      "Fallo al crear las partidas del asiento '${asiento.clave}' "
      '(idasiento $idasiento, $creadas/${asiento.lineas.length} creadas): '
      '${original.message}. Compensación: $compensacion',
      statusCode: original.statusCode,
      responseBody: original.responseBody,
      cause: original,
    );
  }

  /// Importe con punto y dos decimales (`3.20`): la API inserta el texto tal
  /// cual en una columna `double`.
  static String _importe(int cents) => (cents / 100).toStringAsFixed(2);

  static String? _importeOpcional(int? cents) =>
      cents == null ? null : _importe(cents);

  // ---------------------------------------------------------------------------
  // Subcuentas

  Future<_Ejercicio> _ejercicioPara(DateTime fecha, int idempresa) async {
    final dia = DateTime(fecha.year, fecha.month, fecha.day);
    for (final conocido in _ejerciciosConocidos) {
      if (conocido.contiene(dia, idempresa)) return conocido;
    }
    final iso = fsFormatIsoDate(dia);
    final page = await _api.list(
      _ejercicios,
      filters: {
        'idempresa': idempresa,
        'estado': 'ABIERTO',
        'fechainicio_lte': iso,
        'fechafin_gte': iso,
      },
      sort: const {'codejercicio': FsSortOrder.asc},
      limit: 1,
    );
    if (page.items.isEmpty) {
      throw ConfigException(
        'No hay ningún ejercicio ABIERTO que contenga la fecha $iso para la '
        'empresa $idempresa. Hay que crearlo (y cargar su plan contable) en '
        'FacturaScripts',
      );
    }
    final record = page.items.first;
    final ejercicio = _Ejercicio(
      codejercicio: record.fsRequireString('codejercicio'),
      idempresa: record.fsInt('idempresa') ?? idempresa,
      inicio: record.fsDate('fechainicio') ?? dia,
      fin: record.fsDate('fechafin') ?? dia,
    );
    _ejerciciosConocidos.add(ejercicio);
    return ejercicio;
  }

  Future<SubcuentasCierre> _subcuentasBase(String codejercicio) async {
    final cached = _cache[codejercicio];
    if (cached != null && _now().difference(cached.resueltoEn) < cacheTtl) {
      return cached.subcuentas;
    }

    final porCuenta = <CuentaZ, String>{};
    final faltan = <String>[];
    for (final cuenta in CuentaZ.values) {
      final page = await _api.list(
        _subcuentas,
        filters: {'codejercicio': codejercicio, 'codcuenta': cuenta.codcuenta},
        sort: const {'codsubcuenta': FsSortOrder.asc},
        limit: 1,
      );
      final codsubcuenta = page.items.isEmpty
          ? null
          : page.items.first.fsNonEmptyString('codsubcuenta');
      if (codsubcuenta == null) {
        faltan.add('${cuenta.codcuenta} (${cuenta.descripcion})');
      } else {
        porCuenta[cuenta] = codsubcuenta;
      }
    }
    if (faltan.isNotEmpty) {
      throw ConfigException(
        'El ejercicio $codejercicio no tiene subcuenta para las cuentas '
        '${faltan.join(', ')}. ¿Está cargado el plan contable?',
      );
    }

    final impuestos = await _api.listAll(_impuestos, sortBy: 'codimpuesto');
    final ivaPorCodimpuesto = <String, String>{
      for (final impuesto in impuestos)
        ?impuesto.fsNonEmptyString('codimpuesto'): ?impuesto.fsNonEmptyString(
          'codsubcuentarep',
        ),
    };

    final subcuentas = SubcuentasCierre(
      codejercicio: codejercicio,
      porCuenta: Map.unmodifiable(porCuenta),
      ivaPorCodimpuesto: Map.unmodifiable(ivaPorCodimpuesto),
    );
    _cache[codejercicio] = _CacheSubcuentas(subcuentas, _now());
    _log.info('Subcuentas del ejercicio $codejercicio: $porCuenta');
    return subcuentas;
  }

  Future<void> _comprobarSubcuenta(
    String codejercicio,
    CuentaZ cuenta,
    String codsubcuenta,
  ) async {
    final key = '$codejercicio/$codsubcuenta';
    if (_subcuentasVerificadas.contains(key)) return;
    final page = await _api.list(
      _subcuentas,
      filters: {'codejercicio': codejercicio, 'codsubcuenta': codsubcuenta},
      limit: 1,
    );
    if (page.items.isEmpty) {
      throw ConfigException(
        "La subcuenta '$codsubcuenta' configurada para ${cuenta.codcuenta} "
        '(${cuenta.descripcion}) no existe en el ejercicio $codejercicio',
      );
    }
    _subcuentasVerificadas.add(key);
  }
}

final class _Ejercicio {
  const _Ejercicio({
    required this.codejercicio,
    required this.idempresa,
    required this.inicio,
    required this.fin,
  });

  final String codejercicio;
  final int idempresa;
  final DateTime inicio;
  final DateTime fin;

  bool contiene(DateTime dia, int empresa) =>
      empresa == idempresa && !dia.isBefore(inicio) && !dia.isAfter(fin);
}

final class _CacheSubcuentas {
  const _CacheSubcuentas(this.subcuentas, this.resueltoEn);

  final SubcuentasCierre subcuentas;
  final DateTime resueltoEn;
}
