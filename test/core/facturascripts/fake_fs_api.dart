/// Doble en memoria de la API REST v3 de FacturaScripts para los tests de los
/// servicios de documentos y contabilidad.
///
/// Reproduce lo que importa para esos servicios: tablas por recurso con
/// clave primaria autoincremental, filtros con sufijos, orden, paginación con
/// `X-Total-Count`, el 404 de FacturaScripts, el POST que devuelve los campos
/// enviados como TEXTO, y los endpoints `crearFacturaCliente` (totales con el
/// algoritmo `classic`, numeración, asiento y recibo según `formapagos.pagado`),
/// `pagarFacturaCliente/{id}` y `crearPedidoProveedor` (suma `pterecibir`).
/// Los recibos (`reciboclientes`) y pagos (`pagoclientes`) siguen las reglas
/// de FS 2026.5 verificadas en el sandbox: un recibo n.º 1 al crear, pago y
/// asiento 57x/430 al cobrar cada recibo, 400 al cambiar el importe de un
/// recibo pagado, `pagado` reenviado = pago duplicado, borrado en cascada y
/// `pagarFacturaCliente` con `codpago` que reescribe todos los recibos.
/// Registra todas las llamadas y permite programar fallos y "pérdidas de
/// respuesta" (el efecto se aplica pero el cliente recibe un error de red) para
/// probar la idempotencia.
library;

import 'dart:convert';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:proyecto_comandero/core/money/money.dart';

/// Una llamada registrada por [FakeFsApi].
final class FakeFsCall {
  const FakeFsCall({
    required this.method,
    required this.resource,
    this.id,
    this.fields = const {},
    this.filters = const {},
    this.limit,
  });

  /// `LIST`, `GET`, `POST`, `PUT`, `DELETE` o `CALL` (endpoints `crear*`...).
  final String method;
  final String resource;
  final Object? id;
  final Map<String, Object?> fields;
  final Map<String, Object?> filters;
  final int? limit;

  @override
  String toString() =>
      '$method $resource${id == null ? '' : '/$id'}'
      '${filters.isEmpty ? '' : ' ?$filters'}'
      '${fields.isEmpty ? '' : ' $fields'}';
}

enum _FaultKind { fail, loseResponse }

final class _Fault {
  _Fault({
    required this.resource,
    required this.method,
    required this.nth,
    required this.kind,
    required this.error,
  });

  final String resource;
  final String? method;
  final int nth;
  final _FaultKind kind;
  final ErpApiException error;
  bool consumed = false;
}

final class FakeFsApi implements FsApi {
  FakeFsApi();

  /// Instancia con datos maestros parecidos a los del sandbox: cliente
  /// `TPVVARIOS`, almacén `ALG`, formas de pago `TPVEFE` (nace pagada),
  /// `TPVTAR` y `CONT` (no), impuestos `IVA0/4/10/21`, estados 10 Boceto y 11
  /// Emitida, ejercicio `2026` con subcuentas del plan por defecto, productos
  /// `CANA`, `CAFE`, `PAELLA` (carta, `nostock`), `ARROZ`, `POLLO`, `PATATA`
  /// (materias primas con stock) y proveedores `PROV1`, `PROV2`.
  factory FakeFsApi.conDatosBasicos() {
    final api = FakeFsApi();
    api.seed('clientes', {
      'codcliente': 'TPVVARIOS',
      'nombre': 'CLIENTES VARIOS (TPV)',
      'cifnif': '',
    });
    api.seed('almacenes', {'codalmacen': 'ALG', 'nombre': 'Almacén'});
    api.seed('series', {'codserie': 'S', 'descripcion': 'Simplificadas'});
    for (final (codpago, pagado) in [
      ('TPVEFE', true),
      ('TPVTAR', false),
      ('CONT', false),
    ]) {
      api.seed('formapagos', {
        'codpago': codpago,
        'descripcion': codpago,
        'pagado': pagado,
        'activa': true,
      });
    }
    for (final (cod, iva, sub) in [
      ('IVA0', 0.0, ''),
      ('IVA4', 4.0, '4770000004'),
      ('IVA10', 10.0, '4770000010'),
      ('IVA21', 21.0, '4770000021'),
    ]) {
      api.seed('impuestos', {
        'codimpuesto': cod,
        'descripcion': 'IVA $iva%',
        'iva': iva,
        'recargo': 0.0,
        'codsubcuentarep': sub,
        'activo': true,
      });
    }
    api.seed('estadodocumentos', {
      'idestado': 10,
      'nombre': 'Boceto',
      'tipodoc': 'FacturaCliente',
      'predeterminado': true,
      'editable': true,
      'actualizastock': -1,
    });
    api.seed('estadodocumentos', {
      'idestado': 11,
      'nombre': 'Emitida',
      'tipodoc': 'FacturaCliente',
      'predeterminado': false,
      'editable': false,
      'actualizastock': -1,
    });
    api.seed('ejercicios', {
      'codejercicio': '2026',
      'nombre': '2026',
      'estado': 'ABIERTO',
      'fechainicio': '01-01-2026',
      'fechafin': '31-12-2026',
      'idempresa': 1,
      'longsubcuenta': 10,
    });
    for (final (codcuenta, codsubcuenta, descripcion) in [
      ('570', '5700000000', 'Caja, euros'),
      ('572', '5720000000', 'Bancos c/c vista, euros'),
      ('700', '7000000000', 'Ventas de mercaderías'),
      ('477', '4770000000', 'HP, IVA repercutido'),
      ('477', '4770000004', 'HP, IVA repercutido 4%'),
      ('477', '4770000010', 'HP, IVA repercutido 10%'),
      ('477', '4770000021', 'HP, IVA repercutido 21%'),
      ('659', '6590000000', 'Otras pérdidas en gestión corriente'),
      ('759', '7590000000', 'Ingresos por servicios diversos'),
      ('4300', '4300000000', 'Clientes'),
    ]) {
      api.seed('subcuentas', {
        'codejercicio': '2026',
        'codcuenta': codcuenta,
        'codsubcuenta': codsubcuenta,
        'descripcion': descripcion,
        'debe': 0.0,
        'haber': 0.0,
        'saldo': 0.0,
      });
    }
    for (final (ref, precio, codimpuesto, nostock, coste) in [
      ('CANA', 0.86364, 'IVA10', true, 0.3),
      ('CAFE', 1.18182, 'IVA10', true, 0.2),
      ('PAELLA', 10.90909, 'IVA10', true, 0.0),
      ('ARROZ', 0.0, 'IVA10', false, 1.2),
      ('POLLO', 0.0, 'IVA10', false, 5.5),
      ('PATATA', 0.0, 'IVA4', false, 0.9),
    ]) {
      final producto = api.seed('productos', {
        'referencia': ref,
        'descripcion': ref,
        'codimpuesto': codimpuesto,
        'nostock': nostock,
        'sevende': true,
        'secompra': !nostock,
        'bloqueado': false,
        'precio': precio,
      });
      api.seed('variantes', {
        'idproducto': producto['idproducto'],
        'referencia': ref,
        'precio': precio,
        'coste': coste,
      });
      if (!nostock) {
        api.seed('stocks', {
          'codalmacen': 'ALG',
          'referencia': ref,
          'idproducto': producto['idproducto'],
          'cantidad': 10.0,
          'disponible': 10.0,
          'reservada': 0.0,
          'pterecibir': 0.0,
          'stockmin': 5.0,
          'stockmax': 20.0,
        });
      }
    }
    for (final cod in ['PROV1', 'PROV2']) {
      api.seed('proveedores', {
        'codproveedor': cod,
        'nombre': 'Proveedor $cod',
      });
    }
    api.calls.clear();
    return api;
  }

  /// Clave primaria de cada recurso conocido. Un recurso que no esté aquí
  /// responde 404 como FacturaScripts ante un nombre inexistente.
  static const Map<String, String> primaryKeys = {
    'facturaclientes': 'idfactura',
    'lineafacturaclientes': 'idlinea',
    'pedidoproveedores': 'idpedido',
    'lineapedidoproveedores': 'idlinea',
    'asientos': 'idasiento',
    'partidas': 'idpartida',
    'subcuentas': 'idsubcuenta',
    'cuentas': 'idcuenta',
    'ejercicios': 'codejercicio',
    'impuestos': 'codimpuesto',
    'formapagos': 'codpago',
    'series': 'codserie',
    'almacenes': 'codalmacen',
    'estadodocumentos': 'idestado',
    'clientes': 'codcliente',
    'proveedores': 'codproveedor',
    'productos': 'idproducto',
    'variantes': 'idvariante',
    'stocks': 'idstock',
    'reciboclientes': 'idrecibo',
    'pagoclientes': 'idpago',
    'empresas': 'idempresa',
  };

  /// Subcuenta del Debe del asiento de cobro de cada forma de pago (en FS la
  /// da `formapagos.codcuentabanco` → `cuentasbanco.codsubcuenta`).
  final Map<String, String> subcuentaCobro = {
    'TPVEFE': '5700000000',
    'TPVTAR': '5720000000',
  };

  /// Subcuenta del cliente en los asientos de cobro.
  static const String subcuentaCliente = '4300000001';

  static const List<String> endpoints = [
    'crearFacturaCliente',
    'crearPedidoProveedor',
    'pagarFacturaCliente',
  ];

  /// Campos que `crearFacturaCliente` aceptaría pero rompen numeración o
  /// guardado: enviarlos es un error de programación y el doble lo delata.
  static const Set<String> camposProhibidosFactura = {
    'neto',
    'total',
    'totaliva',
    'totalrecargo',
    'totalirpf',
    'numero',
    'codigo',
    'idestado',
    'codejercicio',
    'idempresa',
    'idfactura',
    'editable',
    'idasiento',
  };

  final Map<String, List<FsRecord>> tables = {};
  final Map<String, int> _counters = {};
  final List<_Fault> _faults = [];

  /// Todas las llamadas, en orden.
  final List<FakeFsCall> calls = [];

  /// Si es `false`, `crearFacturaCliente` no genera asiento (ejercicio sin
  /// plan contable).
  bool generaAsientos = true;

  /// Año fijo para la numeración de los documentos creados sin fecha.
  int anioPorDefecto = 2026;

  // ---------------------------------------------------------------------------
  // Utilidades para los tests

  List<FsRecord> table(String resource) =>
      tables.putIfAbsent(resource, () => []);

  /// Inserta un registro; asigna la clave primaria si es entera y falta.
  FsRecord seed(String resource, FsRecord record) {
    final pk = _pkOf(resource);
    final copy = Map<String, Object?>.of(record);
    if (copy[pk] == null) {
      copy[pk] = _nextId(resource);
    } else if (copy[pk] case final int id) {
      final current = _counters[resource] ?? 0;
      _counters[resource] = id > current ? id : current;
    }
    table(resource).add(copy);
    return copy;
  }

  FsRecord? find(String resource, Object id) {
    final pk = _pkOf(resource);
    for (final record in table(resource)) {
      if (_equal(record[pk], id)) return record;
    }
    return null;
  }

  List<FakeFsCall> callsTo(String resource, {String? method}) => [
    for (final call in calls)
      if (call.resource == resource &&
          (method == null || call.method == method))
        call,
  ];

  /// La [nth]-ésima llamada (desde 1, contando desde ahora) a [resource]
  /// (opcionalmente solo con [method]) lanza [error] sin aplicar ningún
  /// efecto.
  void failOn(
    String resource, {
    required int nth,
    required ErpApiException error,
    String? method,
  }) {
    _faults.add(
      _Fault(
        resource: resource,
        method: method,
        nth: _countFrom(resource, method) + nth,
        kind: _FaultKind.fail,
        error: error,
      ),
    );
  }

  /// La [nth]-ésima llamada a [resource] aplica su efecto (el ERP la
  /// procesó) pero el cliente recibe un error de red: la respuesta se perdió.
  void loseResponseOn(String resource, {required int nth, String? method}) {
    _faults.add(
      _Fault(
        resource: resource,
        method: method,
        nth: _countFrom(resource, method) + nth,
        kind: _FaultKind.loseResponse,
        error: const ErpApiException(
          'Timeout esperando la respuesta (simulado)',
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // FsApi

  @override
  Future<List<String>> resources() async =>
      [...primaryKeys.keys, ...endpoints]..sort();

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) => _run(
    FakeFsCall(
      method: 'LIST',
      resource: resource,
      filters: filters,
      limit: limit,
    ),
    () {
      _requireResource(resource);
      final matching = [
        for (final record in table(resource))
          if (filters.entries.every((f) => _matches(record, f.key, f.value)))
            record,
      ];
      if (sort.isNotEmpty) {
        matching.sort((a, b) {
          for (final MapEntry(key: column, value: order) in sort.entries) {
            final cmp = _compare(a[column], b[column]);
            if (cmp != 0) return order == FsSortOrder.asc ? cmp : -cmp;
          }
          return 0;
        });
      }
      final page = matching.skip(offset).take(limit).toList();
      return FsPage(
        items: [for (final record in page) Map.of(record)],
        totalCount: matching.length,
      );
    },
  );

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) async {
    final all = <FsRecord>[];
    var offset = 0;
    while (true) {
      final page = await list(
        resource,
        filters: filters,
        sort: {sortBy: FsSortOrder.asc},
        limit: pageSize,
        offset: offset,
      );
      all.addAll(page.items);
      offset += page.items.length;
      if (page.items.length < pageSize || offset >= (page.totalCount ?? 0)) {
        return all;
      }
    }
  }

  @override
  Future<FsRecord?> get(String resource, Object id) =>
      _run(FakeFsCall(method: 'GET', resource: resource, id: id), () {
        _requireResource(resource);
        final record = find(resource, id);
        return record == null ? null : Map.of(record);
      });

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) =>
      _run(FakeFsCall(method: 'POST', resource: resource, fields: fields), () {
        _requireResource(resource);
        final pk = _pkOf(resource);
        if (fields.containsKey(pk) && find(resource, fields[pk]!) != null) {
          throw ErpApiException(
            'Registro duplicado',
            statusCode: 400,
            responseBody: '{"error":"Registro duplicado"}',
          );
        }
        if (resource == 'reciboclientes') return _altaRecibo(fields);
        final record = <String, Object?>{...fields};
        record.putIfAbsent(pk, () => _nextId(resource));
        switch (resource) {
          case 'asientos':
            _validarAsiento(record);
          case 'partidas':
            _validarPartida(record);
        }
        table(resource).add(record);
        return _textified(record, sent: fields.keys);
      });

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) => _run(
    FakeFsCall(method: 'PUT', resource: resource, id: id, fields: fields),
    () {
      _requireResource(resource);
      final record = find(resource, id);
      if (record == null) throw _notFound('Registro no encontrado');
      if (resource == 'reciboclientes') return _modificarRecibo(record, fields);
      record.addAll(fields);
      return _textified(record, sent: fields.keys);
    },
  );

  @override
  Future<bool> delete(String resource, Object id) =>
      _run(FakeFsCall(method: 'DELETE', resource: resource, id: id), () {
        _requireResource(resource);
        final record = find(resource, id);
        if (record == null) return false;
        table(resource).remove(record);
        if (resource == 'asientos') {
          table('partidas').removeWhere((p) => _equal(p['idasiento'], id));
        }
        if (resource == 'reciboclientes') {
          // ReciboCliente::delete borra antes sus pagos (y cada pago, su
          // asiento); onDelete recalcula `pagada`.
          for (final pago in [
            for (final p in table('pagoclientes'))
              if (_equal(p['idrecibo'], id)) p,
          ]) {
            _borrarPago(pago);
          }
          _actualizarPagada(record['idfactura']);
        }
        if (resource == 'pagoclientes') _borrarAsientoDe(record);
        return true;
      });

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) => _run(
    FakeFsCall(
      method: 'CALL',
      resource: endpoint,
      id: path.isEmpty ? null : path.join('/'),
      fields: fields,
    ),
    () => switch (endpoint) {
      'crearFacturaCliente' => _crearFacturaCliente(fields),
      'pagarFacturaCliente' => _pagarFacturaCliente(path, fields),
      'crearPedidoProveedor' => _crearPedidoProveedor(fields),
      _ => throw _notFound('Endpoint $endpoint inexistente', status: true),
    },
  );

  // ---------------------------------------------------------------------------
  // Endpoints

  FsRecord _crearFacturaCliente(Map<String, Object?> fields) {
    final prohibidos = fields.keys.where(camposProhibidosFactura.contains);
    if (prohibidos.isNotEmpty) {
      throw ArgumentError(
        'crearFacturaCliente: campos prohibidos enviados $prohibidos',
      );
    }
    if (fields['pagada'] case final String texto
        when texto.toLowerCase() == 'true' || texto.toLowerCase() == 'false') {
      throw ArgumentError(
        'pagada como texto "$texto": PHP lo evalúa como true',
      );
    }
    final codcliente = _text(fields['codcliente']);
    if (codcliente.isEmpty) {
      throw _endpointError(400, 'codcliente field is required');
    }
    if (find('clientes', codcliente) == null) {
      throw _endpointError(404, 'customer-not-found');
    }
    final codalmacen = _text(fields['codalmacen']);
    if (codalmacen.isNotEmpty && find('almacenes', codalmacen) == null) {
      throw _endpointError(404, 'warehouse-not-found');
    }
    final fecha = _fechaDe(fields['fecha']);
    final lineas = _lineasDe(fields['lineas']);

    final codserie = _text(fields['codserie'], orElse: 'A');
    final codpago = _text(fields['codpago'], orElse: 'CONT');
    final numero = _nextNumber('facturaclientes', codserie, fecha.year);
    final idfactura = _nextId('facturaclientes');
    final codigo = 'F${fecha.year}$codserie$numero';

    // Totales con el algoritmo classic: acumulación por grupo de IVA y
    // redondeo por grupo.
    final netoPorIva = <double, double>{};
    final lines = <FsRecord>[];
    for (final linea in lineas) {
      final referencia = _text(linea['referencia']);
      final variante = referencia.isEmpty ? null : _variante(referencia);
      final producto = variante == null
          ? null
          : find('productos', variante['idproducto']!);
      final codimpuesto = _text(
        linea['codimpuesto'],
        orElse: _text(producto?['codimpuesto'], orElse: 'IVA21'),
      );
      final iva = _ivaDe(codimpuesto);
      final cantidad = _num(linea['cantidad'], orElse: 1);
      final pvpunitario = _num(
        linea['pvpunitario'],
        orElse: _num(variante?['precio'], orElse: 0),
      );
      final pvptotal = cantidad * pvpunitario;
      netoPorIva[iva] = (netoPorIva[iva] ?? 0) + pvptotal;
      lines.add(
        seed('lineafacturaclientes', {
          'idfactura': idfactura,
          'referencia': referencia.isEmpty ? null : referencia,
          'idproducto': variante?['idproducto'],
          'descripcion': _text(
            linea['descripcion'],
            orElse: _text(producto?['descripcion']),
          ),
          'cantidad': cantidad,
          'pvpunitario': pvpunitario,
          'pvpsindto': pvptotal,
          'pvptotal': pvptotal,
          'codimpuesto': codimpuesto,
          'iva': iva,
          'recargo': 0.0,
          'irpf': 0.0,
        }),
      );
    }
    var netoCents = 0;
    var ivaCents = 0;
    for (final MapEntry(key: iva, value: neto) in netoPorIva.entries) {
      netoCents += roundHalfAwayFromZero(neto * 100);
      ivaCents += roundHalfAwayFromZero(neto * iva);
    }
    final totalCents = netoCents + ivaCents;

    final formaPago = find('formapagos', codpago);
    final nacePagado = formaPago?.fsBool('pagado') ?? false;
    // processInvoicePaid: `pagada` marca pagados todos los recibos.
    final pagadaPedida =
        fields.containsKey('pagada') &&
        !const {'0', ''}.contains(fsEncodeValue(fields['pagada']));
    final pagada = nacePagado || pagadaPedida;
    final estado = table('estadodocumentos').where(
      (e) => e['tipodoc'] == 'FacturaCliente' && e.fsBool('predeterminado'),
    );
    final idestado = estado.isEmpty ? 10 : estado.first['idestado'];

    final doc = seed('facturaclientes', {
      'idfactura': idfactura,
      'codigo': codigo,
      'numero': '$numero',
      'numero2': fields['numero2'],
      'codcliente': codcliente,
      'nombrecliente': find('clientes', codcliente)?['nombre'],
      'cifnif': '',
      'codserie': codserie,
      'codpago': codpago,
      'codalmacen': codalmacen.isEmpty ? 'ALG' : codalmacen,
      'coddivisa': 'EUR',
      'codejercicio': '${fecha.year}',
      'idempresa': 1,
      'fecha': fsFormatDate(fecha),
      'hora': _text(fields['hora'], orElse: '00:00:00'),
      'observaciones': fields['observaciones'],
      'idestado': idestado,
      'editable': true,
      'neto': netoCents / 100,
      'netosindto': netoCents / 100,
      'totaliva': ivaCents / 100,
      'totalrecargo': 0.0,
      'totalirpf': 0.0,
      'totalsuplidos': 0.0,
      'total': totalCents / 100,
      'pagada': pagada,
      'vencida': false,
      'idasiento': null,
      'dtopor1': 0.0,
      'dtopor2': 0.0,
    });
    if (generaAsientos && totalCents != 0) {
      final asiento = seed('asientos', {
        'fecha': fsFormatDate(fecha),
        'concepto': 'Factura de Cliente $codigo',
        'documento': codigo,
        'codejercicio': '${fecha.year}',
        'importe': totalCents / 100,
        'editable': true,
      });
      doc['idasiento'] = asiento['idasiento'];
    }
    if (totalCents != 0) {
      // ReceiptGenerator: un único recibo n.º 1 por el total con el codpago
      // de la cabecera; nace pagado (con su pago y asiento) si la forma de
      // pago tiene pagado=1.
      final recibo = seed('reciboclientes', {
        'idfactura': idfactura,
        'codcliente': codcliente,
        'coddivisa': 'EUR',
        'idempresa': 1,
        'numero': 1,
        'codpago': codpago,
        'importe': totalCents / 100,
        'fecha': fsFormatDate(fecha),
        'pagado': pagada,
        'fechapago': pagada ? fsFormatDate(fecha) : null,
      });
      if (pagada) _nuevoPago(recibo, positivo: true);
      _actualizarPagada(idfactura);
    }
    // Como FS: los campos enviados vuelven como texto; los calculados como
    // tipos nativos.
    return {
      'doc': _textified(doc, sent: fields.keys),
      'lines': [for (final line in lines) Map.of(line)],
    };
  }

  FsRecord _pagarFacturaCliente(
    List<Object> path,
    Map<String, Object?> fields,
  ) {
    if (path.isEmpty) throw _endpointError(400, 'missing-id-parameter');
    final factura = find('facturaclientes', path.first);
    if (factura == null) throw _endpointError(404, 'record-not-found');
    if (!fields.containsKey('pagada')) {
      throw _endpointError(400, 'missing-pagada-parameter');
    }
    // (bool) sobre la cadena recibida: cualquier texto salvo "0" y "" es true.
    final texto = fsEncodeValue(fields['pagada']);
    final pagar = texto != '0' && texto.isNotEmpty;
    if (pagar == factura.fsBool('pagada')) {
      return {'ok': 'Sin cambios', 'data': Map.of(factura)};
    }
    // payReceipts / unpayReceipts: TODOS los recibos pasan al estado pedido;
    // con codpago, todos reciben esa forma de pago (también los ya pagados).
    // Solo los que cambian de estado generan pago (o devolución).
    for (final recibo in _recibosDe(factura['idfactura'])) {
      final cambia = recibo.fsBool('pagado') != pagar;
      recibo['pagado'] = pagar;
      if (fields['fechapago'] case final fechapago?) {
        recibo['fechapago'] = fechapago;
      }
      if (fields['codpago'] case final codpago?) recibo['codpago'] = codpago;
      if (cambia) _nuevoPago(recibo, positivo: pagar);
    }
    _actualizarPagada(factura['idfactura']);
    return {'ok': 'Factura actualizada', 'data': Map.of(factura)};
  }

  // ---------------------------------------------------------------------------
  // Recibos y pagos de cliente (ReciboCliente / PagoCliente)

  List<FsRecord> _recibosDe(Object? idfactura) => [
    for (final recibo in table('reciboclientes'))
      if (_equal(recibo['idfactura'], idfactura)) recibo,
  ];

  /// `POST reciboclientes`: si llega pagado, `saveInsert` crea además el
  /// pago y su asiento. No valida la suma de los recibos (se puede cobrar de
  /// más) ni la unicidad de `(idfactura, numero)`.
  FsRecord _altaRecibo(Map<String, Object?> fields) {
    if (_text(fields['codcliente']).isEmpty) {
      throw _saveError('El campo codcliente no puede ser nulo');
    }
    final pagadoEnviado = fields.containsKey('pagado');
    final pagado =
        pagadoEnviado &&
        !const {'0', ''}.contains(fsEncodeValue(fields['pagado']));
    final fecha = _fechaDe(fields['fecha']);
    final record = <String, Object?>{
      'idrecibo': _nextId('reciboclientes'),
      'idfactura': _asNum(fields['idfactura'])?.toInt(),
      'codcliente': _text(fields['codcliente']),
      'coddivisa': _text(fields['coddivisa'], orElse: 'EUR'),
      'idempresa': _asNum(fields['idempresa'])?.toInt() ?? 1,
      'numero': _asNum(fields['numero'])?.toInt() ?? 1,
      'codpago': fields['codpago'] == null ? null : _text(fields['codpago']),
      'importe': _num(fields['importe'], orElse: 0),
      'fecha': fsFormatDate(fecha),
      'pagado': pagado,
      // test(): con pagado enviado (aunque sea "0") rellena fechapago.
      'fechapago': pagadoEnviado
          ? _text(fields['fechapago'], orElse: fsFormatDate(fecha))
          : null,
    };
    table('reciboclientes').add(record);
    if (pagado) _nuevoPago(record, positivo: true);
    _actualizarPagada(record['idfactura']);
    return _textified(record, sent: fields.keys);
  }

  /// `PUT reciboclientes/{id}`: cada campo enviado cuenta como modificado.
  /// `importe` en un recibo pagado hace fallar el guardado (400, sin
  /// cambios); `pagado` genera SIEMPRE un pago nuevo (+ o −).
  FsRecord _modificarRecibo(FsRecord record, Map<String, Object?> fields) {
    final estabaPagado = record.fsBool('pagado');
    if (fields.containsKey('importe') && estabaPagado) {
      throw ErpApiException(
        'Ha ocurrido un error mientras se guardaban los datos',
        statusCode: 400,
        responseBody:
            '{"error":"Ha ocurrido un error mientras se guardaban los datos"}',
      );
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      record[key] = switch (key) {
        'importe' => _num(value, orElse: 0),
        'numero' || 'idfactura' || 'idempresa' => _asNum(value)?.toInt(),
        'pagado' => !const {'0', ''}.contains(fsEncodeValue(value)),
        _ => value,
      };
    }
    if (fields.containsKey('pagado')) {
      final pagado = record.fsBool('pagado');
      if (pagado && record['fechapago'] == null) {
        record['fechapago'] = record['fecha'];
      }
      _nuevoPago(record, positivo: pagado);
    }
    _actualizarPagada(record['idfactura']);
    return _textified(record, sent: fields.keys);
  }

  /// `PagoCliente::saveInsert` + `PaymentToAccounting`: el pago con el
  /// codpago del recibo y su asiento 57x/430 (o 430/57x si es devolución).
  void _nuevoPago(FsRecord recibo, {required bool positivo}) {
    final importe = _num(recibo['importe'], orElse: 0);
    final codpago = _text(recibo['codpago']);
    final fecha = _text(recibo['fechapago'], orElse: _text(recibo['fecha']));
    final pago = seed('pagoclientes', {
      'idrecibo': recibo['idrecibo'],
      'codpago': codpago,
      'importe': positivo ? importe : -importe,
      'fecha': fecha,
      'idasiento': null,
    });
    if (!generaAsientos) return;
    final asiento = seed('asientos', {
      'fecha': fecha,
      'concepto':
          'Cobro del recibo ${recibo['numero']} de la factura '
          '${recibo['idfactura']}',
      'documento': null,
      'codejercicio': '${fsParseDate(fecha)?.year ?? anioPorDefecto}',
      'importe': importe,
      'editable': true,
    });
    pago['idasiento'] = asiento['idasiento'];
    final tesoreria = subcuentaCobro[codpago] ?? '5720000000';
    for (final (subcuenta, debe) in [
      (tesoreria, positivo),
      (subcuentaCliente, !positivo),
    ]) {
      seed('partidas', {
        'idasiento': asiento['idasiento'],
        'codsubcuenta': subcuenta,
        'concepto': asiento['concepto'],
        'debe': debe ? importe : 0.0,
        'haber': debe ? 0.0 : importe,
      });
    }
  }

  void _borrarPago(FsRecord pago) {
    table('pagoclientes').remove(pago);
    _borrarAsientoDe(pago);
  }

  void _borrarAsientoDe(FsRecord pago) {
    final idasiento = pago['idasiento'];
    if (idasiento == null) return;
    table('asientos').removeWhere((a) => _equal(a['idasiento'], idasiento));
    table('partidas').removeWhere((p) => _equal(p['idasiento'], idasiento));
  }

  /// `ReceiptGenerator::update`: pagada si lo cobrado cubre el total.
  void _actualizarPagada(Object? idfactura) {
    if (idfactura == null) return;
    final factura = find('facturaclientes', idfactura);
    if (factura == null) return;
    final totalCents = centsFromDecimal(_num(factura['total'], orElse: 0));
    var pagadoCents = 0;
    for (final recibo in _recibosDe(idfactura)) {
      if (recibo.fsBool('pagado')) {
        pagadoCents += centsFromDecimal(_num(recibo['importe'], orElse: 0));
      }
    }
    factura['pagada'] =
        totalCents == pagadoCents ||
        (totalCents > 0 && totalCents <= pagadoCents);
  }

  FsRecord _crearPedidoProveedor(Map<String, Object?> fields) {
    final codproveedor = _text(fields['codproveedor']);
    if (codproveedor.isEmpty) {
      throw _endpointError(400, 'codproveedor field is required');
    }
    if (find('proveedores', codproveedor) == null) {
      throw _endpointError(404, 'supplier-not-found');
    }
    final codalmacen = _text(fields['codalmacen'], orElse: 'ALG');
    if (find('almacenes', codalmacen) == null) {
      throw _endpointError(404, 'warehouse-not-found');
    }
    final fecha = _fechaDe(fields['fecha']);
    final lineas = _lineasDe(fields['lineas']);
    final numero = _nextNumber('pedidoproveedores', 'A', fecha.year);
    final idpedido = _nextId('pedidoproveedores');

    var totalCents = 0;
    final lines = <FsRecord>[];
    for (final linea in lineas) {
      final referencia = _text(linea['referencia']);
      final variante = referencia.isEmpty ? null : _variante(referencia);
      final producto = variante == null
          ? null
          : find('productos', variante['idproducto']!);
      final cantidad = _num(linea['cantidad'], orElse: 1);
      final pvpunitario = _num(
        linea['pvpunitario'],
        orElse: _num(variante?['coste'], orElse: 0),
      );
      totalCents += roundHalfAwayFromZero(cantidad * pvpunitario * 100);
      lines.add(
        seed('lineapedidoproveedores', {
          'idpedido': idpedido,
          'referencia': referencia.isEmpty ? null : referencia,
          'idproducto': variante?['idproducto'],
          'descripcion': _text(
            linea['descripcion'],
            orElse: _text(producto?['descripcion']),
          ),
          'cantidad': cantidad,
          'pvpunitario': pvpunitario,
          'pvptotal': cantidad * pvpunitario,
          'servido': 0.0,
          'actualizastock': 2,
        }),
      );
      if (producto != null && !producto.fsBool('nostock')) {
        final stock = table('stocks').where(
          (s) => s['codalmacen'] == codalmacen && s['referencia'] == referencia,
        );
        if (stock.isEmpty) {
          seed('stocks', {
            'codalmacen': codalmacen,
            'referencia': referencia,
            'idproducto': producto['idproducto'],
            'cantidad': 0.0,
            'disponible': 0.0,
            'reservada': 0.0,
            'pterecibir': cantidad,
            'stockmin': 0.0,
            'stockmax': 0.0,
          });
        } else {
          final row = stock.first;
          row['pterecibir'] = _num(row['pterecibir'], orElse: 0) + cantidad;
        }
      }
    }

    final doc = seed('pedidoproveedores', {
      'idpedido': idpedido,
      'codigo': 'PED${fecha.year}A$numero',
      'numero': '$numero',
      'numproveedor': fields['numproveedor'],
      'codproveedor': codproveedor,
      'nombre': find('proveedores', codproveedor)?['nombre'],
      'codalmacen': codalmacen,
      'codserie': 'A',
      'codejercicio': '${fecha.year}',
      'idempresa': 1,
      'fecha': fsFormatDate(fecha),
      'hora': _text(fields['hora'], orElse: '00:00:00'),
      'observaciones': fields['observaciones'],
      'idestado': 15,
      'editable': true,
      'neto': totalCents / 100,
      'totaliva': 0.0,
      'total': totalCents / 100,
    });
    return {
      'doc': _textified(doc, sent: fields.keys),
      'lines': [for (final line in lines) Map.of(line)],
    };
  }

  // ---------------------------------------------------------------------------
  // Validaciones de los recursos contables (las que hace FacturaScripts)

  void _validarAsiento(FsRecord record) {
    if (_text(record['concepto']).isEmpty) {
      throw _saveError('El campo concepto es obligatorio');
    }
    final fecha = _fechaDe(record['fecha']);
    record['fecha'] = fsFormatDate(fecha);
    record.putIfAbsent('codejercicio', () => '${fecha.year}');
    record.putIfAbsent('idempresa', () => 1);
    record.putIfAbsent('editable', () => true);
    record.putIfAbsent('importe', () => 0.0);
    final mismoEjercicio = table('asientos')
        .where((a) => a['codejercicio'] == record['codejercicio']);
    record['numero'] =
        mismoEjercicio.fold(0, (max, a) {
          final n = a['numero'];
          return n is int && n > max ? n : max;
        }) +
        1;
  }

  void _validarPartida(FsRecord record) {
    final asiento = find('asientos', record['idasiento'] ?? -1);
    if (asiento == null) {
      throw _saveError(
        'El campo idasiento de la tabla partidas no puede ser nulo',
      );
    }
    if (_text(record['concepto']).isEmpty) {
      throw _saveError('El campo concepto es obligatorio');
    }
    final codsubcuenta = _text(record['codsubcuenta']);
    final subcuenta = table('subcuentas').where(
      (s) =>
          s['codsubcuenta'] == codsubcuenta &&
          s['codejercicio'] == asiento['codejercicio'],
    );
    if (subcuenta.isEmpty) {
      throw _saveError(
        'El campo idsubcuenta de la tabla partidas no puede ser nulo',
      );
    }
    record['idsubcuenta'] = subcuenta.first['idsubcuenta'];
    record.putIfAbsent('debe', () => 0.0);
    record.putIfAbsent('haber', () => 0.0);
  }

  // ---------------------------------------------------------------------------
  // Infraestructura

  Future<T> _run<T>(FakeFsCall call, T Function() effect) async {
    calls.add(call);
    final fault = _faultFor(call);
    if (fault != null) fault.consumed = true;
    if (fault?.kind == _FaultKind.fail) throw fault!.error;
    final result = effect();
    if (fault?.kind == _FaultKind.loseResponse) throw fault!.error;
    return result;
  }

  _Fault? _faultFor(FakeFsCall call) {
    for (final fault in _faults) {
      if (fault.consumed || fault.resource != call.resource) continue;
      if (fault.method != null && fault.method != call.method) continue;
      if (_countFrom(fault.resource, fault.method) == fault.nth) return fault;
    }
    return null;
  }

  int _countFrom(String resource, String? method) =>
      callsTo(resource, method: method).length;

  static String _pkOf(String resource) =>
      primaryKeys[resource] ??
      (throw ArgumentError.value(resource, 'resource', 'Recurso desconocido'));

  static void _requireResource(String resource) {
    if (!primaryKeys.containsKey(resource)) {
      throw ErpApiException(
        'Recurso $resource no encontrado',
        statusCode: 404,
        responseBody: '{"status":"error","message":"resource-not-found"}',
      );
    }
  }

  int _nextId(String resource) {
    final next = (_counters[resource] ?? 0) + 1;
    _counters[resource] = next;
    return next;
  }

  int _nextNumber(String resource, String codserie, int year) {
    var max = 0;
    for (final record in table(resource)) {
      if (record['codserie'] == codserie && record['codejercicio'] == '$year') {
        final numero = int.tryParse(_text(record['numero'])) ?? 0;
        if (numero > max) max = numero;
      }
    }
    return max + 1;
  }

  FsRecord? _variante(String referencia) {
    for (final variante in table('variantes')) {
      if (variante['referencia'] == referencia ||
          variante['codbarras'] == referencia) {
        return variante;
      }
    }
    return null;
  }

  double _ivaDe(String codimpuesto) {
    final impuesto = find('impuestos', codimpuesto);
    if (impuesto == null) {
      throw ArgumentError(
        "Impuesto '$codimpuesto' no sembrado en el doble (tabla impuestos)",
      );
    }
    return impuesto.fsDouble('iva') ?? 0;
  }

  DateTime _fechaDe(Object? value) {
    if (value == null) return DateTime(anioPorDefecto, 6, 15, 12);
    final fecha = fsParseDate(_text(value));
    if (fecha == null) throw _endpointError(400, 'invalid-date');
    return fecha;
  }

  List<Map<String, Object?>> _lineasDe(Object? value) {
    if (value == null) throw _endpointError(400, 'lineas field is required');
    Object? decoded = value;
    if (value is String) {
      try {
        decoded = jsonDecode(value);
      } on FormatException {
        throw _endpointError(400, 'Invalid lines');
      }
    }
    if (decoded is! List<Object?>) throw _endpointError(400, 'Invalid lines');
    return [
      for (final item in decoded)
        if (item is Map<String, Object?>)
          item
        else
          throw _endpointError(400, 'Invalid lines'),
    ];
  }

  static String _text(Object? value, {String orElse = ''}) =>
      value == null ? orElse : fsEncodeValue(value);

  static double _num(Object? value, {required num orElse}) {
    if (value == null) return orElse.toDouble();
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString()) ?? orElse.toDouble();
  }

  /// Copia del registro con los campos [sent] como texto (así devuelve
  /// FacturaScripts un POST) y el resto con sus tipos nativos.
  static FsRecord _textified(
    FsRecord record, {
    required Iterable<String> sent,
  }) {
    final sentKeys = sent.toSet();
    return {
      for (final MapEntry(:key, :value) in record.entries)
        key: sentKeys.contains(key) && value != null
            ? fsEncodeValue(value)
            : value,
    };
  }

  static ErpApiException _notFound(String message, {bool status = false}) =>
      ErpApiException(
        message,
        statusCode: 404,
        responseBody: status
            ? '{"status":"error","message":"$message"}'
            : '{"error":"$message"}',
      );

  static ErpApiException _endpointError(int code, String message) =>
      ErpApiException(
        message,
        statusCode: code,
        responseBody: '{"status":"error","message":"$message"}',
      );

  static ErpApiException _saveError(String message) => ErpApiException(
    'record-save-error - $message',
    statusCode: 400,
    responseBody: '{"error":"record-save-error - $message"}',
  );

  // Filtros ---------------------------------------------------------------

  static const List<String> _suffixes = [
    '_notnull',
    '_null',
    '_gte',
    '_lte',
    '_neq',
    '_like',
    '_gt',
    '_lt',
  ];

  static bool _matches(FsRecord record, String key, Object? value) {
    var column = key;
    var op = '';
    for (final suffix in _suffixes) {
      if (key.endsWith(suffix)) {
        column = key.substring(0, key.length - suffix.length);
        op = suffix;
        break;
      }
    }
    final stored = record[column];
    switch (op) {
      case '_null':
        return stored == null;
      case '_notnull':
        return stored != null;
      case '_like':
        final needle = _text(value).replaceAll('%', '').toLowerCase();
        return _text(stored).toLowerCase().contains(needle);
    }
    if (stored == null) return op == '_neq' && value != null;
    if (value == null) return op == '_neq';
    final cmp = _compare(stored, value);
    return switch (op) {
      '' => cmp == 0,
      '_neq' => cmp != 0,
      '_gt' => cmp > 0,
      '_gte' => cmp >= 0,
      '_lt' => cmp < 0,
      '_lte' => cmp <= 0,
      _ => false,
    };
  }

  static bool _equal(Object? a, Object? b) =>
      a != null && b != null && _compare(a, b) == 0;

  /// Compara como números, fechas o texto, en ese orden, igual que lo haría
  /// MySQL con los valores de texto que envía la API.
  static int _compare(Object? a, Object? b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    final na = _asNum(a);
    final nb = _asNum(b);
    if (na != null && nb != null) return na.compareTo(nb);
    final da = fsParseDate(_text(a));
    final db = fsParseDate(_text(b));
    if (da != null && db != null) return da.compareTo(db);
    return _text(a).compareTo(_text(b));
  }

  static num? _asNum(Object? value) => switch (value) {
    final bool flag => flag ? 1 : 0,
    final num number => number,
    final String text => num.tryParse(text.trim()),
    _ => null,
  };
}

/// Reenvía todo a [inner]; los tests lo extienden para alterar una respuesta
/// concreta (p. ej. devolver un JSON mal formado) sin reimplementar el doble.
base class FakeFsApiDelegate implements FsApi {
  FakeFsApiDelegate(this.inner);

  final FakeFsApi inner;

  @override
  Future<List<String>> resources() => inner.resources();

  @override
  Future<FsPage> list(
    String resource, {
    Map<String, Object?> filters = const {},
    Map<String, FsSortOrder> sort = const {},
    int limit = 50,
    int offset = 0,
  }) => inner.list(
    resource,
    filters: filters,
    sort: sort,
    limit: limit,
    offset: offset,
  );

  @override
  Future<List<FsRecord>> listAll(
    String resource, {
    Map<String, Object?> filters = const {},
    required String sortBy,
    int pageSize = 200,
  }) => inner.listAll(
    resource,
    filters: filters,
    sortBy: sortBy,
    pageSize: pageSize,
  );

  @override
  Future<FsRecord?> get(String resource, Object id) => inner.get(resource, id);

  @override
  Future<FsRecord> create(String resource, Map<String, Object?> fields) =>
      inner.create(resource, fields);

  @override
  Future<FsRecord> update(
    String resource,
    Object id,
    Map<String, Object?> fields,
  ) => inner.update(resource, id, fields);

  @override
  Future<bool> delete(String resource, Object id) => inner.delete(resource, id);

  @override
  Future<FsRecord> call(
    String endpoint, {
    List<Object> path = const [],
    Map<String, Object?> fields = const {},
  }) => inner.call(endpoint, path: path, fields: fields);
}
