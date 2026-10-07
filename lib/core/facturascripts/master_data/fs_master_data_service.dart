/// Lectura de datos maestros de FacturaScripts y diagnóstico de la
/// configuración del TPV contra el ERP.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../fs_api.dart';
import '../fs_resources.dart';
import 'fs_master_models.dart';

export 'fs_master_models.dart';

/// Servicio de datos maestros. Depende solo de [FsApi] para poder probarse
/// con un doble en memoria.
///
/// Todos los métodos lanzan [ErpApiException]: los fallos de transporte vienen
/// del cliente y los registros ininterpretables se traducen aquí (código 200,
/// `kind` = `unexpected`) para que la capa superior no vea `FormatException`.
final class FsMasterDataService {
  FsMasterDataService(this._api);

  final FsApi _api;
  final Logger _log = appLogger('facturascripts.master');

  /// `GET settings/default`. `properties` llega como texto JSON.
  Future<FsDefaultSettings> settingsDefault() async {
    final record = await _api.get(FsResources.settings, 'default');
    if (record == null) {
      throw const ErpApiException(
        "No existe el registro 'default' de ajustes en FacturaScripts",
        statusCode: 200,
      );
    }
    return _parse('settings/default', record, FsDefaultSettings.fromRecord);
  }

  /// `GET empresas/{idempresa}`.
  Future<FsEmpresa> empresa(int idempresa) async {
    final record = await _api.get(FsResources.empresas, idempresa);
    if (record == null) {
      throw ErpApiException(
        'No existe la empresa $idempresa en FacturaScripts',
        statusCode: 200,
      );
    }
    return _parse('empresas/$idempresa', record, FsEmpresa.fromRecord);
  }

  Future<List<FsSerie>> series() => _listAll(
    FsResources.series,
    sortBy: 'codserie',
    build: FsSerie.fromRecord,
  );

  Future<List<FsFormaPago>> formasPago() => _listAll(
    FsResources.formaPagos,
    sortBy: 'codpago',
    build: FsFormaPago.fromRecord,
  );

  Future<List<FsAlmacen>> almacenes() => _listAll(
    FsResources.almacenes,
    sortBy: 'codalmacen',
    build: FsAlmacen.fromRecord,
  );

  /// Estados posibles de una factura de cliente
  /// (`estadodocumentos?filter[tipodoc]=FacturaCliente`).
  Future<List<FsEstadoDocumento>> estadosFactura() => _listAll(
    FsResources.estadoDocumentos,
    filters: const {'tipodoc': 'FacturaCliente'},
    sortBy: 'idestado',
    build: FsEstadoDocumento.fromRecord,
  );

  /// `GET clientes/{codcliente}`; `null` si no existe.
  Future<FsCliente?> cliente(String codcliente) async {
    final record = await _api.get(FsResources.clientes, codcliente);
    if (record == null) return null;
    return _parse('clientes/$codcliente', record, FsCliente.fromRecord);
  }

  /// Crea el cliente genérico de contado del TPV. Es idempotente: si ya
  /// existe lo devuelve sin tocarlo.
  ///
  /// `cifnif` se envía vacío a propósito: la columna es NOT NULL sin defecto
  /// y el modelo rechaza el nulo, pero acepta la cadena vacía y entonces no
  /// valida el NIF. No se envía `riesgomax`: con riesgo máximo FacturaScripts
  /// rechazaría las facturas al superarlo.
  Future<FsCliente> crearClienteGenerico({
    String codcliente = 'TPV',
    String nombre = 'CLIENTES VARIOS (TPV)',
  }) async {
    final existing = await cliente(codcliente);
    if (existing != null) return existing;

    final FsRecord data;
    try {
      data = await _api.create(FsResources.clientes, {
        'codcliente': codcliente,
        'nombre': nombre,
        'cifnif': '',
      });
    } on ErpApiException catch (error) {
      // Carrera con otro dispositivo: FacturaScripts responde 400
      // "Registro duplicado". Si ya existe, el objetivo está cumplido.
      if (error.kind == ErpApiErrorKind.validation) {
        final created = await cliente(codcliente);
        if (created != null) return created;
      }
      rethrow;
    }
    _log.info('Cliente genérico $codcliente creado en FacturaScripts');
    // La respuesta del POST trae los tipos como texto; se vuelve a leer para
    // devolver el registro canónico (y comprobar que quedó guardado).
    final created = await cliente(codcliente);
    return created ??
        _parse('clientes/$codcliente', data, FsCliente.fromRecord);
  }

  /// Comprueba la configuración del TPV contra el ERP. Nunca lanza: cada
  /// fallo de la API se convierte en un item de nivel `error`.
  ///
  /// Si la API no responde o rechaza la clave, el resto de comprobaciones no
  /// se intenta (cada intento con una clave mala es una incidencia más).
  Future<List<DiagnosticoItem>> diagnosticar(DiagnosticoConfig config) async {
    final items = <DiagnosticoItem>[];

    final List<String> resources;
    try {
      resources = await _api.resources();
    } on ErpApiException catch (error) {
      items.add(
        DiagnosticoItem(
          codigo: 'api',
          nivel: DiagnosticoNivel.error,
          titulo: 'API de FacturaScripts no accesible',
          detalle: error.message,
        ),
      );
      return items;
    }
    final missing = FsResources.requeridosPorElTpv
        .where((resource) => !resources.contains(resource))
        .toList(growable: false);
    if (missing.isEmpty) {
      items.add(
        const DiagnosticoItem(
          codigo: 'api',
          nivel: DiagnosticoNivel.ok,
          titulo: 'API accesible',
          detalle:
              'La clave es válida y todos los recursos necesarios están '
              'disponibles.',
        ),
      );
    } else {
      items.add(
        DiagnosticoItem(
          codigo: 'api',
          nivel: DiagnosticoNivel.error,
          titulo: 'Faltan recursos en la API',
          detalle:
              'La clave no da acceso a: ${missing.join(', ')}. Revisa los '
              'permisos de la clave (marca GET además de POST) o la versión '
              'de FacturaScripts.',
        ),
      );
    }

    await _check(items, 'serie', 'Serie de facturación', () async {
      final series = await this.series();
      final serie = series.where((s) => s.codserie == config.codserie);
      if (serie.isEmpty) {
        return (
          DiagnosticoNivel.error,
          "La serie '${config.codserie}' no existe en FacturaScripts.",
        );
      }
      if (!serie.first.esSimplificada) {
        return (
          DiagnosticoNivel.aviso,
          "La serie '${config.codserie}' no es de tipo S (simplificada): las "
              'facturas de los tickets no serán facturas simplificadas.',
        );
      }
      return (
        DiagnosticoNivel.ok,
        "Serie '${config.codserie}' (${serie.first.descripcion}), tipo S.",
      );
    });

    List<FsFormaPago>? formasPago;
    try {
      formasPago = await this.formasPago();
    } on ErpApiException catch (error) {
      items.add(
        DiagnosticoItem(
          codigo: 'pago',
          nivel: DiagnosticoNivel.error,
          titulo: 'Formas de pago',
          detalle: error.message,
        ),
      );
    }
    if (formasPago != null) {
      _checkFormaPago(
        items,
        formasPago,
        codigo: 'pago_efectivo',
        titulo: 'Forma de pago en efectivo',
        codpago: config.codpagoEfectivo,
      );
      _checkFormaPago(
        items,
        formasPago,
        codigo: 'pago_tarjeta',
        titulo: 'Forma de pago con tarjeta',
        codpago: config.codpagoTarjeta,
      );
    }

    await _check(items, 'almacen', 'Almacén', () async {
      final almacenes = await this.almacenes();
      if (config.codalmacen.trim().isEmpty) {
        final activos = [
          for (final a in almacenes)
            if (a.activo) "'${a.codalmacen}' (${a.nombre})",
        ];
        return (
          DiagnosticoNivel.error,
          'No hay almacén configurado en el TPV: sin él no se facturan los '
              'tickets ni se descuenta el stock. Elige uno en Ajustes → '
              'Fiscal${activos.isEmpty ? '' : ' (disponibles: ${activos.join(', ')})'}.',
        );
      }
      final almacen = almacenes.where((a) => a.codalmacen == config.codalmacen);
      if (almacen.isEmpty) {
        return (
          DiagnosticoNivel.error,
          "El almacén '${config.codalmacen}' no existe en FacturaScripts.",
        );
      }
      if (!almacen.first.activo) {
        return (
          DiagnosticoNivel.aviso,
          "El almacén '${config.codalmacen}' está desactivado.",
        );
      }
      return (
        DiagnosticoNivel.ok,
        "Almacén '${config.codalmacen}' (${almacen.first.nombre}).",
      );
    });

    await _check(items, 'cliente', 'Cliente genérico', () async {
      final cliente = await this.cliente(config.codcliente);
      if (cliente == null) {
        return (
          DiagnosticoNivel.error,
          "El cliente '${config.codcliente}' no existe en FacturaScripts. "
              'Créalo desde la configuración del TPV.',
        );
      }
      if (cliente.debaja) {
        return (
          DiagnosticoNivel.error,
          "El cliente '${config.codcliente}' está dado de baja.",
        );
      }
      if (cliente.riesgomax != null && cliente.riesgomax! > 0) {
        return (
          DiagnosticoNivel.aviso,
          "El cliente '${config.codcliente}' tiene riesgo máximo "
              '${cliente.riesgomax}: FacturaScripts rechazará las facturas '
              'cuando lo supere.',
        );
      }
      return (
        DiagnosticoNivel.ok,
        "Cliente '${config.codcliente}' (${cliente.nombre}).",
      );
    });

    return items;
  }

  // ---------------------------------------------------------------------------

  void _checkFormaPago(
    List<DiagnosticoItem> items,
    List<FsFormaPago> formasPago, {
    required String codigo,
    required String titulo,
    required String codpago,
  }) {
    final match = formasPago.where((f) => f.codpago == codpago);
    if (match.isEmpty) {
      items.add(
        DiagnosticoItem(
          codigo: codigo,
          nivel: DiagnosticoNivel.error,
          titulo: titulo,
          detalle: "La forma de pago '$codpago' no existe en FacturaScripts.",
        ),
      );
      return;
    }
    final forma = match.first;
    if (!forma.activa) {
      items.add(
        DiagnosticoItem(
          codigo: codigo,
          nivel: DiagnosticoNivel.error,
          titulo: titulo,
          detalle: "La forma de pago '$codpago' está desactivada.",
        ),
      );
      return;
    }
    items.add(
      DiagnosticoItem(
        codigo: codigo,
        nivel: DiagnosticoNivel.ok,
        titulo: titulo,
        detalle: "Forma de pago '$codpago' (${forma.descripcion}) activa.",
      ),
    );
    if (!forma.pagado) {
      items.add(
        DiagnosticoItem(
          codigo: '${codigo}_pagado',
          nivel: DiagnosticoNivel.aviso,
          titulo: '$titulo: no marca las facturas como pagadas',
          detalle:
              "La forma de pago '$codpago' tiene pagado=false: la factura "
              'nacerá pendiente de cobro; se usará pagarFacturaCliente.',
        ),
      );
    }
    if (forma.codcuentabanco == null) {
      items.add(
        DiagnosticoItem(
          codigo: '${codigo}_cuenta',
          nivel: DiagnosticoNivel.aviso,
          titulo: '$titulo: sin cuenta bancaria',
          detalle:
              "La forma de pago '$codpago' no tiene cuenta bancaria asociada: "
              'el cobro se contabilizará en 572 y no en 570.',
        ),
      );
    }
  }

  Future<void> _check(
    List<DiagnosticoItem> items,
    String codigo,
    String titulo,
    Future<(DiagnosticoNivel, String)> Function() probe,
  ) async {
    try {
      final (nivel, detalle) = await probe();
      items.add(
        DiagnosticoItem(
          codigo: codigo,
          nivel: nivel,
          titulo: titulo,
          detalle: detalle,
        ),
      );
    } on ErpApiException catch (error) {
      items.add(
        DiagnosticoItem(
          codigo: codigo,
          nivel: DiagnosticoNivel.error,
          titulo: titulo,
          detalle: error.message,
        ),
      );
    }
  }

  Future<List<T>> _listAll<T>(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    required T Function(FsRecord) build,
  }) async {
    final records = await _api.listAll(
      resource,
      filters: filters,
      sortBy: sortBy,
    );
    return [for (final record in records) _parse(resource, record, build)];
  }

  T _parse<T>(String what, FsRecord record, T Function(FsRecord) build) {
    try {
      return build(record);
    } on FormatException catch (error) {
      throw ErpApiException(
        'Registro de $what no interpretable: ${error.message}',
        statusCode: 200,
        cause: error,
      );
    }
  }
}
