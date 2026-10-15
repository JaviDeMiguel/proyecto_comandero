/// Documentos de cliente del host (§5.3-§5.6 y §5.8 del diseño de
/// impresión): el documento provisional y el cajón al cobrar, la factura
/// simplificada ORIGINAL o DUPLICADO con su QR tributario, la copia del
/// provisional, la vista previa, la precuenta, la espera de la factura en el
/// modo «Emitir factura al cobrar» y las emisiones pendientes.
///
/// Es un colaborador de la fachada `PrintingService`, que le delega su API de
/// tickets y el efecto del cobro. Lee los tickets del diario y escribe en él
/// su estado de impresión (`Ticket.impresion`); para esperar la factura
/// observa el diario y nunca llama a la facturación, así que no hay ciclo con
/// `BillingService` (§5.6).
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/fiscal/verifactu_qr.dart';
import '../../../../core/isolates/escpos/escpos_builder.dart'
    show bytesAbrirCajon;
import '../../../../core/isolates/escpos/ticket_documents.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import '../../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../../impresion/domain/formato_impresion.dart';
import '../../../sala/domain/precuenta_emitida.dart';
import '../../../sala/domain/ticket.dart';
import '../../domain/host_settings.dart';
import '../../domain/host_snapshot.dart';
import '../alert_bus.dart';
import '../host_state_store.dart';
import 'canal_impresion.dart';
import 'mapeo_documentos.dart';

/// Error de las acciones de la interfaz sin impresora de tickets (el texto de
/// siempre).
const String _sinImpresoraTickets = 'No hay impresora de tickets configurada';

/// Marca de las reimpresiones del documento provisional, que no es factura.
const String _avisoCopia = 'COPIA';

/// Impresión de los documentos de cliente: provisional, factura (ORIGINAL o
/// DUPLICADO), precuenta y cajón.
///
/// - **Al cobrar** ([alCobrar], el efecto que despacha la fachada): en el modo
///   por defecto, el provisional con el pulso del cajón al principio si hay
///   efectivo, o el trabajo propio del cajón si el provisional no sale; en el
///   modo «Emitir factura al cobrar», el cajón al instante, la espera de la
///   factura en el diario y el ORIGINAL o, si no llega a tiempo o no se puede
///   imprimir, el provisional sin cajón y un aviso.
/// - **A petición de la interfaz:** [imprimirFactura], [reimprimirProvisional],
///   [imprimirDocumentoTicket], [vistaPreviaTicket], [imprimirPrecuenta] y
///   [abrirCajon] relanzan los errores para que lleguen a quien pulsó.
/// - **Art. 14 del RD 1619/2012:** la marca del ORIGINAL y su QR se escriben
///   en el diario de forma atómica antes de encolar y las facturas de un
///   mismo ticket se imprimen de una en una, así que dos peticiones seguidas
///   nunca dan dos originales. La marca se deshace si no se pudo generar o
///   encolar (la petición siguiente ya la ve deshecha) y se conserva si el
///   trabajo falla después en la impresora (la siguiente impresión es un
///   DUPLICADO).
final class TicketsImpresion {
  /// [settings] y [cabecera] se leen en cada impresión, así que los cambios de
  /// ajustes y de la empresa en caché valen al instante. [cabecera] es la del
  /// emisor ya compuesta (`componerCabecera`). [now] es el reloj del host.
  TicketsImpresion({
    required this._store,
    required this._canal,
    required this._alerts,
    required this._settings,
    required this._cabecera,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final Logger _log = appLogger('host.impresion');

  final HostStateStore _store;
  final CanalImpresion _canal;
  final AlertBus _alerts;
  final ImpresionSettings Function() _settings;
  final EmpresaTicket Function() _cabecera;
  final DateTime Function() _now;

  /// Tickets con una emisión automática de la factura en curso (§5.4). No va
  /// al diario: tras un reinicio no queda ninguna.
  final Set<String> _pendientes = {};
  final StreamController<Set<String>> _cambiosPendientes =
      StreamController<Set<String>>.broadcast();

  /// Cómo terminar cada espera de la factura en curso ([cancelarEsperas]).
  final Set<void Function()> _esperas = {};
  bool _esperasCanceladas = false;

  /// Final de la cadena de impresiones de factura de cada ticket con alguna
  /// en curso: un `Future` que nunca falla ([_imprimirFactura]).
  final Map<String, Future<void>> _facturasEnCurso = {};

  /// Trabajos de factura encolados (`jobId → ticketId`), del más antiguo al
  /// más nuevo, para [reintentarFactura]. Solo en memoria, como la cola.
  final Map<String, String> _trabajosFactura = {};

  /// Trabajos de factura con un [reintentarFactura] en curso.
  final Set<String> _reintentosEnCurso = {};

  /// Trabajos de factura terminados que se recuerdan; los pendientes o
  /// fallidos se recuerdan siempre.
  static const int _maxTrabajosFactura = 100;

  // ---------------------------------------------------------------------------
  // Emisiones pendientes y esperas

  /// El ticket tiene una emisión automática de la factura en curso: desde que
  /// empieza [alCobrar] (antes de su primer `await`) hasta que termina.
  bool emisionPendiente(String ticketId) => _pendientes.contains(ticketId);

  /// Tickets con una emisión automática en curso: cada suscriptor recibe
  /// primero el conjunto actual y después uno nuevo al empezar y al terminar
  /// cada emisión. Admite varios suscriptores.
  Stream<Set<String>> get emisionesPendientes =>
      Stream<Set<String>>.multi((destino) {
        destino.add(Set.unmodifiable(_pendientes));
        final suscripcion = _cambiosPendientes.stream.listen(destino.add);
        destino.onCancel = suscripcion.cancel;
      });

  /// Termina las esperas de la factura en curso, y hace que las que empiecen
  /// después no esperen (cierre del TPV): cada emisión sigue como si hubiera
  /// vencido el plazo.
  void cancelarEsperas() {
    _esperasCanceladas = true;
    for (final terminar in _esperas.toList()) {
      terminar();
    }
  }

  // ---------------------------------------------------------------------------
  // Cobro

  /// Efecto del cobro del [ticket] (§5.3 y §5.4). Sin impresora de tickets no
  /// hace nada. Nunca lanza por un fallo de impresión: los convierte en
  /// avisos, y el cajón se abre aunque el documento no salga.
  Future<void> alCobrar(Ticket ticket) async {
    final ajustes = _settings();
    final endpoint = ajustes.paraTickets;
    if (endpoint == null) return;
    final efectivo =
        ajustes.abrirCajonEfectivo &&
        ticket.pagos.any((pago) => pago.metodo == MetodoPago.efectivo);
    final emision = ajustes.formato.emision;
    if (emision.modo == ModoEmision.facturaAlCobrar) {
      await _emitirFacturaAlCobrar(
        ticket,
        endpoint,
        efectivo: efectivo,
        imprimir: ajustes.imprimirTicketAlCobrar,
        espera: emision.espera,
      );
      return;
    }
    final impreso =
        ajustes.imprimirTicketAlCobrar &&
        await _provisionalAutomatico(ticket, endpoint, abrirCajon: efectivo) !=
            null;
    if (efectivo && !impreso) await _cajonDelCobro(ticket, endpoint);
  }

  /// Modo «Emitir factura al cobrar» (§5.4): el cajón al instante, la espera
  /// de la factura y, en el paso 5, el ORIGINAL o el provisional.
  Future<void> _emitirFacturaAlCobrar(
    Ticket ticket,
    PrinterEndpoint endpoint, {
    required bool efectivo,
    required bool imprimir,
    required Duration espera,
  }) async {
    if (!imprimir) {
      if (efectivo) await _cajonDelCobro(ticket, endpoint);
      return;
    }
    // Antes del primer await: el ticket ya está pendiente cuando el cobro
    // vuelve a la interfaz, que desactiva «Imprimir factura».
    _cambiarPendiente(ticket.id, pendiente: true);
    try {
      if (efectivo) await _cajonDelCobro(ticket, endpoint);
      final listo = await _esperarFactura(ticket.id, espera);
      final actual = listo == null
          ? null
          : _store.snapshot.ticketPorId(ticket.id);
      await _emitir(ticket, actual, endpoint);
    } finally {
      _cambiarPendiente(ticket.id, pendiente: false);
    }
  }

  /// Paso 5 de §5.4: el ORIGINAL si la factura llegó ([actual] no nulo) y se
  /// puede imprimir; si no, el provisional sin cajón y un aviso con la causa.
  /// Si el ORIGINAL falla al generarse o encolarse, también el provisional.
  Future<void> _emitir(
    Ticket cobrado,
    Ticket? actual,
    PrinterEndpoint endpoint,
  ) async {
    final numero = cobrado.numeroLocal;
    final cabecera = _cabecera();
    if (actual == null) {
      final impreso = await _provisionalSinCajon(cobrado, endpoint);
      _alerts.info(
        impreso
            ? 'Factura no disponible a tiempo: se imprimió el documento '
                  'provisional del ticket $numero'
            : 'Factura no disponible a tiempo para el ticket $numero',
        origen: 'impresion',
      );
      return;
    }
    final motivo = _motivoSinFactura(actual, cabecera);
    if (motivo != null) {
      final impreso = await _provisionalSinCajon(actual, endpoint);
      _alerts.info(
        impreso
            ? 'Factura no disponible: se imprimió el documento provisional '
                  'del ticket $numero'
            : 'Factura no disponible para el ticket $numero',
        detalle: motivo,
        origen: 'impresion',
      );
      return;
    }
    try {
      await _imprimirFactura(actual.id, cabecera, endpoint);
    } on AppException catch (error) {
      final impreso = await _provisionalSinCajon(actual, endpoint);
      _alerts.aviso(
        'No se pudo imprimir la factura del ticket $numero: '
        '${error.message}'
        '${impreso ? '. Se imprimió el documento provisional' : ''}',
        origen: 'impresion',
      );
    }
  }

  /// Por qué no se imprime la factura de [ticket] ya fuera de la cola: el
  /// rechazo de FacturaScripts (con su error) o [motivoNoImprimible].
  String? _motivoSinFactura(Ticket ticket, EmpresaTicket cabecera) {
    final factura = ticket.factura;
    if (factura != null && factura.estado == EstadoSincronizacion.error) {
      final error = factura.error;
      return 'FacturaScripts rechazó la factura del ticket nº '
          '${ticket.numeroLocal}${error == null ? '' : ': $error'}';
    }
    return motivoNoImprimible(ticket, cabecera);
  }

  /// Espera a que el ticket deje de estar `pendiente` en el diario o a que
  /// venza [espera] (§5.6). Devuelve el ticket, o `null` si venció el plazo,
  /// si el ticket ya no está en el turno, si se cerró el diario o si se
  /// cancelaron las esperas. La suscripción al diario y el temporizador se
  /// liberan al terminar, sea cual sea la causa.
  Future<Ticket?> _esperarFactura(String ticketId, Duration espera) {
    bool listo(Ticket? t) =>
        t == null || t.factura?.estado != EstadoSincronizacion.pendiente;
    final ahora = _store.snapshot.ticketPorId(ticketId);
    if (listo(ahora)) return Future<Ticket?>.value(ahora);
    if (_esperasCanceladas) return Future<Ticket?>.value();

    final resultado = Completer<Ticket?>();
    late final StreamSubscription<HostSnapshot> suscripcion;
    late final Timer plazo;
    late final void Function() cancelar;
    void terminar(Ticket? ticket) {
      if (resultado.isCompleted) return;
      plazo.cancel();
      unawaited(suscripcion.cancel());
      _esperas.remove(cancelar);
      resultado.complete(ticket);
    }

    cancelar = () => terminar(null);
    suscripcion = _store.changes.listen((snapshot) {
      final ticket = snapshot.ticketPorId(ticketId);
      if (listo(ticket)) terminar(ticket);
    }, onDone: cancelar);
    plazo = Timer(espera, cancelar);
    _esperas.add(cancelar);
    return resultado.future;
  }

  void _cambiarPendiente(String ticketId, {required bool pendiente}) {
    final cambio = pendiente
        ? _pendientes.add(ticketId)
        : _pendientes.remove(ticketId);
    if (cambio) _cambiosPendientes.add(Set.unmodifiable(_pendientes));
  }

  // ---------------------------------------------------------------------------
  // Factura simplificada: ORIGINAL o DUPLICADO

  /// Imprime la factura simplificada del ticket: ORIGINAL la primera vez y
  /// DUPLICADO nº n las siguientes, con el QR guardado con el ORIGINAL.
  ///
  /// Lanza [ValidationException] si el ticket no está en el turno, aún no
  /// tiene código, fecha o total de FS, falta el NIF del emisor, el total de
  /// FS no coincide con el del ticket o los datos del QR no son válidos;
  /// [PrinterException] si no hay impresora de tickets o no se pudo generar o
  /// encolar. En todos esos casos `Ticket.impresion` queda como estaba.
  Future<void> imprimirFactura(String ticketId) async {
    final ticket = _ticketEnTurno(ticketId);
    final cabecera = _cabecera();
    final motivo = motivoNoImprimible(ticket, cabecera);
    if (motivo != null) throw ValidationException(motivo);
    await _imprimirFactura(ticketId, cabecera, _impresoraTickets());
  }

  /// Pasos 4 a 6 de §5.5 para una factura imprimible ([motivoNoImprimible]
  /// nulo), de una en una por ticket: cada petición empieza cuando la
  /// anterior del mismo ticket ya encoló su trabajo o deshizo su marca. Así
  /// dos peticiones seguidas dan el ORIGINAL y después el DUPLICADO nº 1 y,
  /// si la primera falla antes de encolar, la segunda es el ORIGINAL. El
  /// error de cada petición llega solo a quien la hizo.
  Future<void> _imprimirFactura(
    String ticketId,
    EmpresaTicket cabecera,
    PrinterEndpoint endpoint,
  ) {
    final previa = _facturasEnCurso[ticketId] ?? Future<void>.value();
    final esta = previa.then(
      (_) => _marcarYEncolarFactura(ticketId, cabecera, endpoint),
    );
    final cadena = esta.then<void>((_) {}, onError: (Object _) {});
    _facturasEnCurso[ticketId] = cadena;
    unawaited(
      cadena.whenComplete(() {
        if (identical(_facturasEnCurso[ticketId], cadena)) {
          _facturasEnCurso.remove(ticketId);
        }
      }),
    );
    return esta;
  }

  /// Marca en el diario el ORIGINAL (con su QR) o un DUPLICADO más, genera y
  /// encola con [PrintRetryPolicy.connectOnly] y, si algo falla antes de que
  /// el trabajo esté en la cola, deshace la marca y relanza. Lanza
  /// [ValidationException] si, mientras esperaba su turno, el ticket salió
  /// del turno o su factura dejó de ser imprimible.
  Future<void> _marcarYEncolarFactura(
    String ticketId,
    EmpresaTicket cabecera,
    PrinterEndpoint endpoint,
  ) async {
    final ajustes = _settings();
    final cuando = _now();
    late final Ticket ticket;
    late final ImpresionTicket anterior;
    late final ImpresionTicket puesta;
    // La decisión ORIGINAL o DUPLICADO y el QR del ORIGINAL se toman dentro
    // de la clausura, que el diario aplica de forma síncrona. Si la factura
    // ya no es imprimible o el QR no es válido, la clausura lanza antes de
    // devolver el snapshot y no se marca nada.
    await _store.update((s) {
      ticket = s.ticketPorId(ticketId) ?? _fueraDelTurno(ticketId);
      final motivo = motivoNoImprimible(ticket, cabecera);
      if (motivo != null) throw ValidationException(motivo);
      anterior = ticket.impresion;
      puesta = anterior.originalImpreso
          ? anterior.conDuplicado()
          : anterior.conFacturaOriginal(
              cuando,
              qr: _qrDelOriginal(ajustes.formato.verifactu, cabecera, ticket),
            );
      return s.conTicket(ticket.copyWith(impresion: puesta));
    });
    final esOriginal = !anterior.originalImpreso;
    // motivoNoImprimible nulo: la factura tiene código, fecha y total de FS.
    final codigo = ticket.factura!.codigo!;
    final String? jobId;
    try {
      jobId = await _canal.enviar(
        endpoint,
        esOriginal
            ? 'Factura $codigo (original)'
            : 'Factura $codigo (duplicado ${puesta.duplicados})',
        (perfil) => _generarFactura(
          ticket,
          perfil,
          cabecera: cabecera,
          formato: ajustes.formato.ticket,
          qr: puesta.qr,
          duplicado: esOriginal
              ? null
              : DuplicadoPrint(numero: puesta.duplicados, impresoEn: cuando),
        ),
        lanzarErrores: true,
        reintento: PrintRetryPolicy.connectOnly,
      );
    } on Object {
      // Nada llegó a la impresora: se deshace la marca de la factura, salvo
      // que otro escritor del diario la haya cambiado, y se conservan las
      // impresiones del provisional anotadas entre medias. Con el diario
      // cerrado se queda, y la siguiente impresión será un DUPLICADO.
      await _escribirDiario(
        'deshacer la marca de la factura del ticket $ticketId',
        (s) {
          final actual = s.ticketPorId(ticketId);
          if (actual == null) return s;
          final impresion = actual.impresion;
          if (_conMarcaDe(puesta, impresion) != impresion) return s;
          return s.conTicket(
            actual.copyWith(impresion: _conMarcaDe(anterior, impresion)),
          );
        },
      );
      rethrow;
    }
    if (jobId != null) _recordarTrabajoFactura(jobId, ticketId);
  }

  /// Registra el trabajo y, por encima de [_maxTrabajosFactura], olvida los
  /// más antiguos que ya terminaron sin quedar fallidos: uno aún en la cola o
  /// fallido nunca se olvida, porque su reintento debe pasar por aquí.
  void _recordarTrabajoFactura(String jobId, String ticketId) {
    _trabajosFactura[jobId] = ticketId;
    var sobran = _trabajosFactura.length - _maxTrabajosFactura;
    if (sobran <= 0) return;
    final olvidables = [
      for (final id in _trabajosFactura.keys)
        if (!_canal.pendiente(id)) id,
    ];
    for (final id in olvidables) {
      if (sobran-- <= 0) break;
      _trabajosFactura.remove(id);
    }
  }

  /// El trabajo [jobId] imprime una factura (ORIGINAL o DUPLICADO): se
  /// reintenta con [reintentarFactura], nunca con `CanalImpresion.reintentar`.
  bool esTrabajoDeFactura(String jobId) => _trabajosFactura.containsKey(jobId);

  /// [reintentarFactura] haría algo ahora mismo con [jobId]: es de factura,
  /// está fallido y no tiene un reintento en curso.
  bool puedeReintentarFactura(String jobId) =>
      _trabajosFactura.containsKey(jobId) &&
      !_reintentosEnCurso.contains(jobId) &&
      _canal.fallido(jobId);

  /// Reintenta el trabajo de factura fallido [jobId] (§5.17, art. 14): si
  /// ningún intento llegó a enviar nada, reencola sus mismos bytes (ese
  /// ORIGINAL o DUPLICADO no salió); si no, nunca los reenvía, porque algo
  /// pudo salir: imprime el siguiente DUPLICADO con [imprimirFactura] y el
  /// trabajo fallido deja de poder reintentarse.
  ///
  /// Lanza [PrinterException] si el trabajo no es de factura, ya tiene un
  /// reintento en curso, no está fallido o ya se reintentó, y lo mismo que
  /// [imprimirFactura] (entonces el trabajo sigue fallido).
  Future<void> reintentarFactura(String jobId) async {
    final ticketId =
        _trabajosFactura[jobId] ??
        (throw PrinterException('El trabajo $jobId no es de una factura'));
    if (!_reintentosEnCurso.add(jobId)) {
      throw const PrinterException('Ya se está reintentando esa factura');
    }
    try {
      if (_canal.nadaEnviado(jobId)) {
        _canal.reintentar(jobId);
        return;
      }
      await imprimirFactura(ticketId);
      _canal.descartar(jobId);
    } finally {
      _reintentosEnCurso.remove(jobId);
    }
  }

  /// [provisional] con la marca de la factura de [marca]: su ORIGINAL, su QR
  /// y sus DUPLICADOS.
  static ImpresionTicket _conMarcaDe(
    ImpresionTicket marca,
    ImpresionTicket provisional,
  ) => ImpresionTicket(
    provisionalEn: provisional.provisionalEn,
    copiasProvisional: provisional.copiasProvisional,
    facturaOriginalEn: marca.facturaOriginalEn,
    qr: marca.qr,
    duplicados: marca.duplicados,
  );

  /// QR del ORIGINAL de la factura del [ticket] según [config] (§6.3), con
  /// los datos de FS y el NIF normalizado de la [cabecera]; `null` con el
  /// modo desactivado. Lanza [ValidationException] si el NIF no tiene 9
  /// caracteres tras normalizarlo o la serie no vale.
  static QrImpreso? _qrDelOriginal(
    QrVerifactuConfig config,
    EmpresaTicket cabecera,
    Ticket ticket,
  ) {
    // Solo para facturas imprimibles: código, fecha, total de FS y NIF.
    final factura = ticket.factura!;
    final qr = QrTributario.segunAjustes(
      modo: config.modo,
      entorno: config.entorno,
      nif: cabecera.cifnif!,
      numSerie: factura.codigo!,
      fecha: factura.fecha!,
      importeCents: factura.totalFsCents!,
    );
    if (qr == null) return null;
    return QrImpreso(
      url: qr.url,
      leyenda: qr.leyenda,
      modo: config.modo.name,
      entorno: config.entorno.name,
      nif: qr.nif,
    );
  }

  Future<Uint8List> _generarFactura(
    Ticket ticket,
    PerfilImpresora perfil, {
    required EmpresaTicket cabecera,
    required FormatoTicket formato,
    required QrImpreso? qr,
    DuplicadoPrint? duplicado,
  }) => generarTicketEnIsolate(
    datosFactura(
      ticket,
      cabecera: cabecera,
      formato: formato,
      perfil: perfil,
      qrUrl: qr?.url,
      qrLeyenda: qr?.leyenda,
      duplicado: duplicado,
    ),
    runner: _canal.runner,
  );

  // ---------------------------------------------------------------------------
  // Provisional, documento del ticket y vista previa

  /// Reimprime el documento provisional con la marca «COPIA» (nunca abre el
  /// cajón ni lleva QR) y lo anota (`copiasProvisional`). Para tickets sin
  /// factura o cuya factura no se puede imprimir. Lanza [ValidationException]
  /// si el ticket no está en el turno y [PrinterException] si no hay
  /// impresora de tickets o no se pudo generar o encolar.
  Future<void> reimprimirProvisional(String ticketId) async {
    final ticket = _ticketEnTurno(ticketId);
    final endpoint = _impresoraTickets();
    await _canal.enviar(
      endpoint,
      'Ticket ${ticket.numeroLocal} · provisional (copia)',
      (perfil) => _generarProvisional(ticket, perfil, avisos: [_avisoCopia]),
      lanzarErrores: true,
    );
    await _anotarProvisional(ticketId);
  }

  /// La factura si es imprimible ([motivoNoImprimible] nulo) y, si no, una
  /// copia del provisional. Lo usa `BillingService.reimprimir`: lanza lo
  /// mismo que [imprimirFactura] y [reimprimirProvisional].
  Future<void> imprimirDocumentoTicket(String ticketId) async {
    final ticket = _ticketEnTurno(ticketId);
    if (motivoNoImprimible(ticket, _cabecera()) == null) {
      await imprimirFactura(ticketId);
    } else {
      await reimprimirProvisional(ticketId);
    }
  }

  /// Bytes del documento que saldría ahora mismo con «Imprimir factura» o
  /// «Copia provisional», sin efectos: el ORIGINAL con el QR que se
  /// construiría, el DUPLICADO siguiente con el QR guardado o, si la factura
  /// no es imprimible, la copia del provisional. Con el papel del perfil de
  /// la impresora de tickets (sin ella, el papel heredado). Lanza
  /// [ValidationException] si el ticket no está en el turno o el QR del
  /// ORIGINAL no sería válido.
  Future<Uint8List> vistaPreviaTicket(String ticketId) async {
    final ticket = _ticketEnTurno(ticketId);
    final ajustes = _settings();
    final endpoint = ajustes.paraTickets;
    final perfil = endpoint == null
        ? PerfilImpresora(papel: ajustes.paper)
        : ajustes.perfilPara(endpoint);
    final cabecera = _cabecera();
    if (motivoNoImprimible(ticket, cabecera) != null) {
      return _generarProvisional(ticket, perfil, avisos: [_avisoCopia]);
    }
    final impresion = ticket.impresion;
    final original = !impresion.originalImpreso;
    return _generarFactura(
      ticket,
      perfil,
      cabecera: cabecera,
      formato: ajustes.formato.ticket,
      qr: original
          ? _qrDelOriginal(ajustes.formato.verifactu, cabecera, ticket)
          : impresion.qr,
      duplicado: original
          ? null
          : DuplicadoPrint(numero: impresion.duplicados + 1, impresoEn: _now()),
    );
  }

  /// El provisional de una impresión automática del cobro, con el pulso del
  /// cajón al principio si [abrirCajon]; lo anota (`provisionalEn`) si se
  /// encoló. Devuelve el id del trabajo, o `null` si no se pudo generar o
  /// encolar: de una AppException avisa el canal y de un error no tipado
  /// (isolate caído), este método, para que el cobro siga y el cajón se abra
  /// igualmente (D1).
  Future<String?> _provisionalAutomatico(
    Ticket ticket,
    PrinterEndpoint endpoint, {
    required bool abrirCajon,
  }) async {
    final descripcion = 'Ticket ${ticket.numeroLocal} · provisional';
    String? id;
    try {
      id = await _canal.enviar(
        endpoint,
        descripcion,
        (perfil) => _generarProvisional(ticket, perfil, abrirCajon: abrirCajon),
      );
    } on Object catch (error, stackTrace) {
      _log.warning(
        'Fallo inesperado al imprimir "$descripcion"',
        error,
        stackTrace,
      );
      _alerts.error(
        'No se pudo imprimir "$descripcion"',
        detalle: error.toString(),
        origen: 'impresion',
      );
    }
    if (id != null) await _anotarProvisional(ticket.id);
    return id;
  }

  /// El provisional sin cajón de la emisión automática; `true` si se encoló.
  Future<bool> _provisionalSinCajon(
    Ticket ticket,
    PrinterEndpoint endpoint,
  ) async =>
      await _provisionalAutomatico(ticket, endpoint, abrirCajon: false) != null;

  Future<Uint8List> _generarProvisional(
    Ticket ticket,
    PerfilImpresora perfil, {
    bool abrirCajon = false,
    List<String> avisos = const [],
  }) => generarTicketEnIsolate(
    datosProvisional(
      ticket,
      cabecera: _cabecera(),
      formato: _settings().formato.ticket,
      perfil: perfil,
      zona: _store.snapshot.mesaPorId(ticket.mesaId)?.zona,
      abrirCajon: abrirCajon,
      avisos: avisos,
    ),
    runner: _canal.runner,
  );

  /// Anota una impresión más del provisional (la primera fija
  /// `provisionalEn`; las siguientes cuentan copias), si el ticket sigue en
  /// el turno.
  Future<void> _anotarProvisional(String ticketId) {
    final cuando = _now();
    return _escribirDiario('anotar el provisional del ticket $ticketId', (s) {
      final ticket = s.ticketPorId(ticketId);
      if (ticket == null) return s;
      return s.conTicket(
        ticket.copyWith(impresion: ticket.impresion.conProvisional(cuando)),
      );
    });
  }

  /// Aplica [cambio] al diario. Es para las escrituras que siguen a la cola
  /// (anotar el provisional, deshacer una marca): con el diario cerrado
  /// (cierre del TPV) no se puede escribir, así que se registra [que] y se
  /// sigue. La marca del ORIGINAL no pasa por aquí: sin diario no se imprime.
  Future<void> _escribirDiario(
    String que,
    HostSnapshot Function(HostSnapshot) cambio,
  ) async {
    try {
      await _store.update(cambio);
    } on StateError catch (error) {
      _log.warning('Diario cerrado: no se pudo $que', error);
    }
  }

  // ---------------------------------------------------------------------------
  // Precuenta y cajón

  /// Imprime una precuenta registrada (la primera vez o de nuevo: siempre el
  /// mismo papel), desde su registro y sin QR, cajón ni copias (§5.8). Lanza
  /// [PrinterException] si no hay impresora de tickets y la AppException de
  /// generar o encolar.
  Future<void> imprimirPrecuenta(
    PrecuentaEmitida precuenta, {
    String? zona,
  }) async {
    final endpoint = _impresoraTickets();
    await _canal.enviar(
      endpoint,
      'Precuenta nº ${precuenta.numero} · '
      '${etiquetaMesa(precuenta.nombreMesa)}',
      (perfil) => generarPrecuentaEnIsolate(
        datosPrecuenta(
          precuenta,
          cabecera: _cabecera(),
          formato: _settings().formato.ticket,
          perfil: perfil,
          zona: zona,
        ),
        runner: _canal.runner,
      ),
      lanzarErrores: true,
    );
  }

  /// Abre el cajón a mano: un trabajo propio con el pulso en la impresora de
  /// tickets, aunque «Abrir el cajón con efectivo» esté desactivado. Lanza
  /// [PrinterException] si no hay impresora de tickets o no se pudo encolar.
  Future<void> abrirCajon() async {
    await _canal.enviarCrudo(
      _impresoraTickets(),
      'Cajón · apertura manual',
      bytesAbrirCajon(),
      lanzarErrores: true,
    );
  }

  /// El trabajo propio del cajón del cobro (§5.3 y §5.4). Un fallo se avisa
  /// y no detiene el cobro.
  Future<void> _cajonDelCobro(Ticket ticket, PrinterEndpoint endpoint) async {
    try {
      await _canal.enviarCrudo(
        endpoint,
        'Cajón · ticket ${ticket.numeroLocal}',
        bytesAbrirCajon(),
      );
    } on Object catch (error, stackTrace) {
      _log.warning(
        'Fallo inesperado al abrir el cajón del ticket ${ticket.numeroLocal}',
        error,
        stackTrace,
      );
      _alerts.error(
        'No se pudo abrir el cajón del ticket ${ticket.numeroLocal}',
        detalle: error.toString(),
        origen: 'impresion',
      );
    }
  }

  // ---------------------------------------------------------------------------

  Ticket _ticketEnTurno(String ticketId) =>
      _store.snapshot.ticketPorId(ticketId) ?? _fueraDelTurno(ticketId);

  static Never _fueraDelTurno(String ticketId) =>
      throw ValidationException('El ticket $ticketId no está en el turno');

  PrinterEndpoint _impresoraTickets() =>
      _settings().paraTickets ??
      (throw const PrinterException(_sinImpresoraTickets));
}
