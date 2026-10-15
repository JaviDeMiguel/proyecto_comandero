import 'dart:async';
import 'dart:typed_data';

import '../../../core/errors/app_exception.dart';
import '../../../core/isolates/cierre_z/cierre_z_models.dart'
    show CierreZResult;
import '../../../core/isolates/escpos/ticket_documents.dart';
import '../../../core/isolates/isolate_runner.dart';
import '../../../core/money/money.dart';
import '../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../impresion/domain/formato_impresion.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/marcha_pase.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/precuenta_emitida.dart';
import '../../sala/domain/ticket.dart';
import '../domain/empresa_emisora.dart';
import '../domain/host_settings.dart';
import 'alert_bus.dart';
import 'host_state_store.dart';
import 'impresion/canal_impresion.dart';
import 'impresion/comandas_impresion.dart';
import 'impresion/mapeo_documentos.dart';
import 'impresion/mapeo_documentos.dart'
    as mapeo
    show formaDePago, tituloPuesto;
import 'impresion/muestras.dart';
import 'impresion/tickets_impresion.dart';
import 'ports.dart';
import 'sala_effects.dart';

export 'impresion/mapeo_documentos.dart'
    show AlcanceReimpresion, MotivoReimpresion;
export 'impresion/muestras.dart' show DocumentoMuestra;

/// Fachada de la impresión ESC/POS del host (§5.0 del diseño de impresión):
/// el único [SalaEffects] de impresión y la API que usa la interfaz.
///
/// No genera documentos: delega en sus colaboradores de `impresion/`, que
/// crea en el constructor y no expone:
///
/// - [CanalImpresion]: genera en un isolate con el perfil de cada impresora,
///   añade copias y aviso, encola en [PrinterPort] y sigue el trabajo;
/// - [ComandasImpresion]: comanda de cada envío, MARCHAR, anulación y
///   reimpresión de comanda (un ticket por puesto);
/// - [TicketsImpresion]: provisional y cajón al cobrar, factura ORIGINAL o
///   DUPLICADO, copia del provisional, vista previa, precuenta, espera de la
///   factura y emisiones pendientes.
///
/// Las impresiones automáticas (efectos) nunca propagan un fallo: lo
/// convierten en aviso operativo. Las que pide la interfaz lo relanzan, para
/// que quien pulsó sepa que no ha salido.
///
/// Los ajustes, la empresa y el nombre del TPV se leen en cada impresión, así
/// que [configurar] en caliente vale para lo siguiente que se imprima.
final class PrintingService extends SalaEffects {
  /// [store] es el diario del host: de él se leen los tickets y en él se
  /// escribe su estado de impresión.
  ///
  /// [empresa] es la cabecera fija de los ajustes (solo tests) y
  /// [empresaErp], la identidad del emisor guardada en el diario (§5.13).
  PrintingService({
    required this._alerts,
    required IsolateRunner runner,
    required ImpresionSettings settings,
    required String nombreTpv,
    required HostStateStore store,
    PrinterPort? printer,
    EmpresaTicket? empresa,
    EmpresaEmisora? empresaErp,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    configurar(
      printer: printer,
      settings: settings,
      empresa: empresa,
      empresaErp: empresaErp,
      nombreTpv: nombreTpv,
    );
    _canal = CanalImpresion(
      alerts: _alerts,
      runner: runner,
      settings: () => _settings,
      printer: () => _printer,
    );
    _comandas = ComandasImpresion(
      canal: _canal,
      alerts: _alerts,
      settings: () => _settings,
      now: _now,
    );
    _tickets = TicketsImpresion(
      store: store,
      canal: _canal,
      alerts: _alerts,
      settings: () => _settings,
      cabecera: () => _cabecera,
      now: _now,
    );
  }

  final AlertBus _alerts;
  final DateTime Function() _now;
  late final CanalImpresion _canal;
  late final ComandasImpresion _comandas;
  late final TicketsImpresion _tickets;
  ImpresionSettings _settings = const ImpresionSettings();
  String _nombreTpv = '';
  PrinterPort? _printer;
  EmpresaTicket? _empresa;
  EmpresaEmisora? _empresaErp;

  ImpresionSettings get settings => _settings;

  /// Hay cola de impresión y al menos una impresora configurada.
  bool get disponible => _printer != null && _settings.hayImpresora;

  /// Hay cola de impresión y una impresora por la que salen los documentos de
  /// cliente (la de tickets o, si no, la de cocina o la de barra).
  bool get hayImpresoraTickets =>
      _printer != null && _settings.paraTickets != null;

  /// La cabecera del emisor tiene NIF: sin él no se imprimen facturas
  /// simplificadas. No avisa de cambios; la interfaz usa
  /// `cabeceraFiscalCompletaProvider`, que compone la misma cabecera.
  bool get cabeceraFiscalCompleta =>
      _cabecera.cifnif?.trim().isNotEmpty ?? false;

  /// Cambia en caliente lo que se indique; lo nulo se conserva.
  void configurar({
    PrinterPort? printer,
    ImpresionSettings? settings,
    EmpresaTicket? empresa,
    EmpresaEmisora? empresaErp,
    String? nombreTpv,
  }) {
    _printer = printer ?? _printer;
    if (settings != null) _settings = settings;
    if (empresa != null) _empresa = empresa;
    if (empresaErp != null) _empresaErp = empresaErp;
    if (nombreTpv != null) _nombreTpv = nombreTpv;
  }

  /// Completa cuando no queda ningún trabajo en seguimiento (tests y cierre).
  Future<void> idle() => _canal.idle();

  /// Reintenta el trabajo de impresión fallido [jobId], el de
  /// `OperationalAlert.trabajoImpresion` (§5.17). Una factura que pudo
  /// enviar bytes no se repite: sale el siguiente DUPLICADO; si no llegó a
  /// conectar, o si no es una factura, se reencolan sus mismos bytes y un
  /// nuevo fallo da otro aviso. Lanza [PrinterException] si no está fallido
  /// o ya se reintentó, si la cola lo rechaza y, con el DUPLICADO, lo mismo
  /// que [imprimirFactura]. El canal nunca reenvía los bytes de una factura
  /// que pudo salir, aunque este servicio ya no la recuerde.
  Future<void> reintentar(String jobId) async {
    if (_tickets.esTrabajoDeFactura(jobId)) {
      await _tickets.reintentarFactura(jobId);
    } else {
      _canal.reintentar(jobId);
    }
  }

  /// [reintentar] haría algo ahora mismo con [jobId] (la interfaz solo
  /// ofrece «Reintentar» entonces): no ha salido ya, no se reintentó ni lo
  /// sustituyó un DUPLICADO, no se canceló y no tiene un reintento en curso.
  bool puedeReintentar(String jobId) => _tickets.esTrabajoDeFactura(jobId)
      ? _tickets.puedeReintentarFactura(jobId)
      : _canal.puedeReintentar(jobId);

  /// Cabecera del emisor con los ajustes y la empresa vigentes (§5.13).
  EmpresaTicket get _cabecera => componerCabecera(
    empresaAjustes: _empresa,
    empresaErp: _empresaErp,
    formato: _settings.formato.ticket,
    nombreTpv: _nombreTpv,
  );

  /// Texto impreso de cada forma de cobro.
  static String formaDePago(MetodoPago metodo) => mapeo.formaDePago(metodo);

  /// Título del puesto en los tickets de comanda.
  static String tituloPuesto(DestinoPreparacion destino) =>
      mapeo.tituloPuesto(destino);

  // ---------------------------------------------------------------------------
  // Efectos de la sala

  @override
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) => _comandas.imprimirEnvio(mesa, comanda, nuevas);

  @override
  Future<void> onLineasAnuladas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) => _comandas.imprimirAnulacion(mesa, comanda, anuladas);

  @override
  Future<void> onPaseMarchado(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) => _comandas.imprimirMarcha(mesa, comanda, marcha, lineas);

  /// Sin cola de impresión no hace nada, como siempre: en el modo «Emitir
  /// factura al cobrar» esperaría la factura para nada.
  @override
  Future<void> onMesaCobrada(Ticket ticket) async {
    if (_printer == null) return;
    await _tickets.alCobrar(ticket);
  }

  // ---------------------------------------------------------------------------
  // Documentos de cliente (acciones de la interfaz)

  /// Imprime la factura simplificada del ticket: ORIGINAL la primera vez y
  /// DUPLICADO nº n las siguientes (§5.5). Lanza [ValidationException] si el
  /// ticket no está en el turno o su factura no se puede imprimir
  /// (`motivoNoImprimible`, QR no válido) y [PrinterException] si no hay
  /// impresora de tickets o no se pudo generar o encolar.
  Future<void> imprimirFactura(String ticketId) =>
      _tickets.imprimirFactura(ticketId);

  /// Reimprime el documento provisional con la marca «COPIA», sin cajón.
  Future<void> reimprimirProvisional(String ticketId) =>
      _tickets.reimprimirProvisional(ticketId);

  /// La factura si se puede imprimir y, si no, una copia del provisional.
  Future<void> imprimirDocumentoTicket(String ticketId) =>
      _tickets.imprimirDocumentoTicket(ticketId);

  /// Bytes del documento que saldría ahora mismo, sin efectos.
  Future<Uint8List> vistaPreviaTicket(String ticketId) =>
      _tickets.vistaPreviaTicket(ticketId);

  /// Imprime una precuenta ya registrada (`SalaService.emitirPrecuenta`).
  /// Lanza [PrinterException] si no hay impresora de tickets o no se pudo
  /// generar o encolar.
  Future<void> imprimirPrecuenta(PrecuentaEmitida precuenta, {String? zona}) =>
      _tickets.imprimirPrecuenta(precuenta, zona: zona);

  /// Abre el cajón a mano. Lanza [PrinterException] si no hay impresora de
  /// tickets o no se pudo encolar.
  Future<void> abrirCajon() => _tickets.abrirCajon();

  /// El ticket tiene una emisión automática de factura en curso (§5.4).
  bool emisionPendiente(String ticketId) => _tickets.emisionPendiente(ticketId);

  /// Tickets con una emisión automática en curso: primero el conjunto actual
  /// y después uno nuevo al empezar y al terminar cada emisión.
  Stream<Set<String>> get emisionesPendientes => _tickets.emisionesPendientes;

  /// Libera las esperas de factura en curso y las futuras (al cerrar el TPV).
  void cancelarEsperas() => _tickets.cancelarEsperas();

  // ---------------------------------------------------------------------------
  // Comandas y muestras (acciones de la interfaz)

  /// Reimprime la comanda de la mesa con la banda del [motivo] en los
  /// [destinos] elegidos (§5.10). Lanza [ValidationException] si no hay nada
  /// que reimprimir y [PrinterException] si ninguno de esos puestos tiene
  /// impresora o no se pudo generar o encolar.
  Future<void> reimprimirComanda(
    Mesa mesa,
    Comanda comanda, {
    required Set<DestinoPreparacion> destinos,
    required AlcanceReimpresion alcance,
    required MotivoReimpresion motivo,
    required String dispositivo,
  }) => _comandas.reimprimirComanda(
    mesa,
    comanda,
    destinos: destinos,
    alcance: alcance,
    motivo: motivo,
    dispositivo: dispositivo,
  );

  /// Imprime la muestra [tipo] en la impresora que sirve a [rol] según
  /// [ajustes] (el borrador de la página «Tickets y comandas»), con el perfil
  /// y la cabecera de ese borrador (§5.18). Lanza [PrinterException] si ese
  /// rol no tiene impresora o no se pudo generar o encolar.
  Future<void> imprimirMuestra(
    DocumentoMuestra tipo, {
    required ImpresionSettings ajustes,
    required RolImpresora rol,
  }) async {
    final endpoint = _impresoraDeRol(ajustes, rol);
    if (endpoint == null) {
      throw PrinterException(
        'No hay impresora de ${rol.name} configurada: no se puede imprimir '
        'la muestra',
      );
    }
    final cabecera = componerCabecera(
      empresaAjustes: _empresa,
      empresaErp: _empresaErp,
      formato: ajustes.formato.ticket,
      nombreTpv: _nombreTpv,
    );
    final perfil = ajustes.perfilPara(endpoint);
    await _canal.enviar(
      endpoint,
      'Muestra · ${tipo.etiqueta}',
      (p) => generarMuestra(
        tipo,
        ajustes: ajustes,
        cabecera: cabecera,
        papel: p.papel,
        ahora: _now(),
        runner: _canal.runner,
        avanceInicial: p.lineasIniciales,
      ),
      preparacion: tipo.preparacion,
      lanzarErrores: true,
      perfil: perfil,
    );
  }

  static PrinterEndpoint? _impresoraDeRol(
    ImpresionSettings ajustes,
    RolImpresora rol,
  ) => switch (rol) {
    RolImpresora.tickets => ajustes.paraTickets,
    RolImpresora.cocina =>
      ajustes.impresoraDe(DestinoPreparacion.cocina)?.endpoint,
    RolImpresora.barra =>
      ajustes.impresoraDe(DestinoPreparacion.barra)?.endpoint,
  };

  // ---------------------------------------------------------------------------
  // Informe Z

  /// Imprime el informe del Cierre Z con la sección «PRECUENTAS SIN COBRO»
  /// si hay alguna (§5.15). Sin impresora de tickets no hace nada; un fallo
  /// se convierte en aviso.
  Future<void> imprimirInformeZ(
    CierreZResult result, {
    List<PrecuentaSinCobro> precuentasSinCobro = const [],
  }) async {
    final endpoint = _settings.paraTickets;
    if (_printer == null || endpoint == null) return;
    final informe = result.informe;
    final cabecera = _cabecera;
    await _canal.enviar(
      endpoint,
      'Informe Z ${informe.idCierre}',
      (perfil) => generarInformeZEnIsolate(
        ZReportPrintData(
          empresa: cabecera,
          nombreTpv: _nombreTpv,
          fecha: informe.fecha,
          numTickets: informe.numTickets,
          numAnulados: informe.numAnulados,
          ventasTotalCents: informe.ventasTotalCents,
          ventasEfectivoCents: informe.ventasEfectivoCents,
          ventasTarjetaCents: informe.ventasTarjetaCents,
          ticketMedioCents: informe.ticketMedioCents,
          porIva: [
            for (final v in informe.porIva)
              DesgloseIvaTicketPrint(
                ivaPct: basisPointsToPercent(v.ivaBp),
                baseCents: v.baseCents,
                cuotaCents: v.cuotaCents,
              ),
          ],
          fondoCajaCents: informe.fondoCajaCents,
          retiradasCents: informe.retiradasCents,
          efectivoEsperadoCents: informe.efectivoEsperadoCents,
          efectivoContadoCents: informe.efectivoContadoCents,
          descuadreCents: informe.descuadreCents,
          partidas: [
            for (final p in result.asiento.partidas)
              (
                codsubcuenta: p.codsubcuenta,
                concepto: p.concepto,
                debeCents: p.debeCents,
                haberCents: p.haberCents,
              ),
          ],
          precuentasSinCobro: [
            for (final p in precuentasSinCobro)
              (
                numero: p.precuenta.numero,
                mesa: p.precuenta.nombreMesa,
                emitidaEn: p.precuenta.emitidaEn,
                totalCents: p.precuenta.totalCents,
                motivo: p.motivo,
              ),
          ],
          paper: perfil.papel,
        ),
        runner: _canal.runner,
      ),
    );
  }
}
