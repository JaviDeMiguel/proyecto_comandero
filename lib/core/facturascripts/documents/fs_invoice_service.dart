/// Factura simplificada idempotente de cada ticket sobre `crearFacturaCliente`.
library;

import '../../errors/app_exception.dart';
import '../../logging/app_logger.dart';
import '../../money/money.dart';
import '../fs_api.dart';
import '../fs_values.dart';
import 'fs_cobro_mixto.dart';
import 'invoice_models.dart';

/// Crea la factura de un ticket en una sola transacción del ERP y la deja
/// cobrada y, si se pide, emitida. Reanudable: la misma clave nunca produce
/// dos facturas.
///
/// Estrategia (DESIGN_BRIEF §3): `POST crearFacturaCliente` calcula totales,
/// numera, genera asiento y recibos y mueve stock en una transacción. Antes
/// de crear se consulta `filter[numero2]`: la API no ofrece idempotencia y la
/// respuesta de un POST puede perderse después de que el ERP haya confirmado.
///
/// Cobro mixto ([TicketFactura.esCobroMixto]): tras crear (sin `pagada`) se
/// reconcilian los recibos con el plan de cobro ([FsCobroMixto]) y después
/// se emite. El cobro simple sigue el flujo de siempre.
///
/// El resultado lleva la fecha y hora y el total de la factura **en FS**
/// ([ResultadoFactura.fecha], [ResultadoFactura.totalFsCents]): si el
/// documento devuelto no los trae se relee la factura una vez y, si siguen
/// faltando, quedan nulos (nunca se sustituyen por los del ticket).
final class FsInvoiceService {
  FsInvoiceService(this._api) : _cobroMixto = FsCobroMixto(_api);

  static const String _resource = 'facturaclientes';
  static const String _crear = 'crearFacturaCliente';
  static const String _pagar = 'pagarFacturaCliente';

  final FsApi _api;
  final FsCobroMixto _cobroMixto;
  final Logger _log = appLogger('facturascripts.invoice');

  /// Crea la factura o, si ya existe una con la misma clave, la reanuda
  /// (cobro y emisión pendientes) sin crear otra.
  ///
  /// Lanza [ValidationException] si hay más de una factura con esa clave en
  /// el ERP (nunca debería ocurrir: el TPV envía en serie), [ErpApiException]
  /// ante cualquier fallo de la API (el llamador decide por `kind`: 422/400
  /// es fallo definitivo, red/5xx se reintenta y volverá a entrar por aquí).
  Future<ResultadoFactura> crearOReanudar(TicketFactura ticket) async {
    try {
      return await _crearOReanudar(ticket);
    } on FormatException catch (error) {
      // La respuesta llegó (2xx) pero no tiene la forma esperada: no es
      // transitorio ni reintentable sin revisar.
      throw ErpApiException(
        'Respuesta de FacturaScripts no interpretable al facturar '
        "'${ticket.claveIdempotente}': ${error.message}",
        statusCode: 200,
        cause: error,
      );
    }
  }

  Future<ResultadoFactura> _crearOReanudar(TicketFactura ticket) async {
    final clave = ticket.claveIdempotente;
    final avisos = <String>[];

    var doc = await _buscarPorClave(clave);
    final yaExistia = doc != null;
    if (doc == null) {
      _log.fine('Creando factura $clave');
      final response = await _api.call(_crear, fields: _camposCreacion(ticket));
      doc = _docDeRespuesta(response, 'doc');
    } else {
      _log.info('Factura $clave ya existía en FS: reanudando');
    }

    final idfactura = doc.fsRequireInt('idfactura');

    var pagada = doc.fsBool('pagada');
    var recibos = const <ReciboFactura>[];
    if (ticket.esCobroMixto) {
      // Cobro mixto: un recibo por forma de pago, reconciliado con el plan
      // en cada pasada (idempotente y reanudable en cualquier paso).
      final cobro = await _cobroMixto.registrar(
        idfactura: idfactura,
        plan: ticket.planCobro,
        fechaPago: ticket.fechaHora,
        avisos: avisos,
      );
      doc = {...doc, ...cobro.factura};
      pagada = cobro.pagada;
      recibos = cobro.recibos;
    } else {
      // Cobro simple. nacePagada: la forma de pago lo hace todo; solo se
      // comprueba.
      final codpago = ticket.codpagoCabecera;
      final modoPago = ticket.modoPagoCabecera;
      if (!pagada && modoPago == ModoPago.pagarTrasCrear) {
        _log.fine('Cobrando factura $idfactura ($clave)');
        final response = await _api.call(
          _pagar,
          path: [idfactura],
          fields: {
            'pagada': 1,
            'fechapago': fsFormatDate(ticket.fechaHora),
            'codpago': codpago,
          },
        );
        final pagadaDoc = response['data'];
        if (pagadaDoc is FsRecord) {
          doc = {...doc, ...pagadaDoc};
        } else {
          doc = await _releer(idfactura) ?? doc;
        }
        pagada = doc.fsBool('pagada');
      }
      if (!pagada) {
        avisos.add(
          modoPago == ModoPago.nacePagada
              ? "La factura no nace pagada: la forma de pago '$codpago' "
                    'no tiene pagado=1 en FacturaScripts'
              : 'La factura sigue sin pagar tras pagarFacturaCliente',
        );
      }
    }

    // Fecha y total de FS: son los de la factura impresa y su QR, nunca los
    // del ticket (el ERP puede cambiar fecha y hora al rellenar un hueco de
    // numeración). Lo que siga faltando tras releer queda nulo.
    doc = await _completarFechaYTotal(doc, idfactura);
    final fecha = _fechaDe(doc);
    if (fecha == null) {
      avisos.add('FacturaScripts no devolvió la fecha de la factura');
    }

    // Verificación de totales: la verdad es la de FS, pero una discrepancia
    // con el TPV se avisa (nunca se repite la factura).
    final totalFs = doc.fsDouble('total');
    final totalFsCents = totalFs == null ? null : centsFromDecimal(totalFs);
    if (totalFsCents == null) {
      avisos.add('FacturaScripts no devolvió el total de la factura');
    } else if (totalFsCents != ticket.totalEsperadoCents) {
      avisos.add(
        'Total FacturaScripts ${formatCents(totalFsCents)} ≠ TPV '
        '${formatCents(ticket.totalEsperadoCents)}',
      );
    }

    final idasiento = doc.fsInt('idasiento');
    if (idasiento == null) {
      avisos.add('Factura sin asiento: ¿ejercicio sin plan contable?');
    }

    // Emisión: PUT con SOLO idestado y solo si difiere (el PUT no es
    // idempotente: cada campo recibido cuenta como modificado).
    var emitida = false;
    if (ticket.emitir) {
      final objetivo = ticket.idEstadoEmitida!;
      var idestado = doc.fsInt('idestado');
      if (idestado == null) {
        doc = await _releer(idfactura) ?? doc;
        idestado = doc.fsInt('idestado');
      }
      if (idestado != objetivo) {
        _log.fine(
          'Emitiendo factura $idfactura: idestado $idestado → $objetivo',
        );
        final updated = await _api.update(_resource, idfactura, {
          'idestado': objetivo,
        });
        doc = {...doc, ...updated};
        idestado = doc.fsInt('idestado');
      }
      emitida = idestado == objetivo;
      if (!emitida) {
        avisos.add('La factura no quedó emitida (idestado=$idestado)');
      }
    }

    if (avisos.isNotEmpty) {
      _log.warning('Factura $clave (id $idfactura) con avisos: $avisos');
    }
    return ResultadoFactura(
      idfactura: idfactura,
      codigo: doc.fsRequireString('codigo'),
      numero: doc.fsString('numero') ?? '',
      fecha: fecha,
      totalCents: totalFsCents ?? ticket.totalEsperadoCents,
      totalFsCents: totalFsCents,
      pagada: pagada,
      idasiento: idasiento,
      emitida: emitida,
      yaExistia: yaExistia,
      avisos: List.unmodifiable(avisos),
      recibos: recibos,
    );
  }

  /// Devuelve [doc] completado con una única relectura de la factura si no
  /// trae la fecha o el total. Si tampoco los trae el GET, siguen faltando.
  Future<FsRecord> _completarFechaYTotal(FsRecord doc, int idfactura) async {
    if (_fechaDe(doc) != null && doc.fsDouble('total') != null) return doc;
    _log.fine(
      'Factura $idfactura sin fecha o total en la respuesta: releyendo',
    );
    return {...doc, ...?await _releer(idfactura)};
  }

  /// Fecha y hora de la factura en FS (`fecha` `dd-MM-yyyy` más `hora`
  /// `HH:mm:ss`; sin `hora`, las 00:00:00). `null` si falta la fecha o no se
  /// puede interpretar.
  static DateTime? _fechaDe(FsRecord doc) {
    final fecha = doc.fsNonEmptyString('fecha');
    if (fecha == null) return null;
    final hora = doc.fsNonEmptyString('hora') ?? '00:00:00';
    return fsParseDate('$fecha $hora');
  }

  /// Campos del formulario de `crearFacturaCliente`. Nunca se envían
  /// `pagada`, totales, numeración, `idestado`, `codejercicio` ni `idempresa`:
  /// el bucle genérico del controlador los aceptaría y rompen el guardado.
  ///
  /// En el cobro mixto `codpago` es el de la parte número 1 y tampoco se
  /// envía `pagada`: marcaría pagado el único recibo con esa forma de pago.
  Map<String, Object?> _camposCreacion(TicketFactura ticket) => {
    'codcliente': ticket.codcliente,
    'codserie': ticket.codserie,
    'codpago': ticket.codpagoCabecera,
    'codalmacen': ticket.codalmacen,
    'fecha': fsFormatDate(ticket.fechaHora),
    'hora': fsFormatTime(ticket.fechaHora),
    'numero2': ticket.claveIdempotente,
    if (ticket.observaciones case final texto? when texto.trim().isNotEmpty)
      'observaciones': texto,
    'lineas': [for (final linea in ticket.lineas) linea.toFsJson()],
  };

  Future<FsRecord?> _buscarPorClave(String clave) async {
    final page = await _api.list(
      _resource,
      filters: {'numero2': clave},
      limit: 2,
    );
    if (page.items.length > 1) {
      final ids = [for (final item in page.items) item.fsString('idfactura')];
      throw ValidationException(
        "Clave '$clave' duplicada en FacturaScripts: facturas $ids. "
        'Hay que resolverlo a mano antes de continuar',
      );
    }
    return page.items.isEmpty ? null : page.items.first;
  }

  Future<FsRecord?> _releer(int idfactura) => _api.get(_resource, idfactura);

  static FsRecord _docDeRespuesta(FsRecord response, String key) {
    final doc = response[key];
    if (doc is FsRecord) return doc;
    throw FormatException("Campo '$key' ausente en la respuesta de $_crear");
  }
}
