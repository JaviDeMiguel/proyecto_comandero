import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/facturascripts/catalog/catalog_models.dart'
    show ArticuloCatalogo;
import '../../../core/fiscal/fs_totales_calculator.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/money/money.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/enrutamiento_comandas.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/ticket.dart';
import '../../sala/protocol/sala_messages.dart';
import '../domain/host_snapshot.dart';
import 'alert_bus.dart';
import 'catalog_service.dart';
import 'host_state_store.dart';
import 'sala_effects.dart';

const Uuid _uuid = Uuid();

/// Estado de mesas y comandas del host.
///
/// Toda mutación (1) valida, (2) actualiza el diario local de forma atómica,
/// (3) emite [SalaChangedEvent] para la red y la UI y (4) dispara los
/// [SalaEffects] registrados. Los errores de negocio se lanzan como
/// [RemoteRequestException] con un código de [SalaErrorCodes], listos para
/// viajar al comandero como `error` no reintentable.
final class SalaService {
  SalaService({
    required this._store,
    required this._alerts,
    required this._catalog,
    DateTime Function()? now,
    String Function()? newId,
    MetodoIva metodoIva = MetodoIva.classic,
    int decimales = 2,
    this._enrutamiento = const EnrutamientoComandas(),
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? _uuid.v4 {
    configurarCalculo(metodo: metodoIva, decimales: decimales);
  }

  static final Logger _log = appLogger('host.sala');

  final HostStateStore _store;
  final AlertBus _alerts;
  final CatalogService _catalog;
  final DateTime Function() _now;
  final String Function() _newId;
  MetodoIva _metodoIva = MetodoIva.classic;
  int _decimales = 2;
  EnrutamientoComandas _enrutamiento;

  final List<SalaEffects> _effects = [];
  final Set<Future<void>> _inFlight = {};
  final StreamController<SalaChangedEvent> _changes =
      StreamController<SalaChangedEvent>.broadcast();
  final StreamController<void> _enrutamientoChanges =
      StreamController<void>.broadcast();

  List<Mesa> get mesas => _store.snapshot.mesas;
  List<Comanda> get comandas => _store.snapshot.comandas;
  Comanda? comandaDeMesa(String mesaId) =>
      _store.snapshot.comandaDeMesa(mesaId);
  Mesa? mesa(String mesaId) => _store.snapshot.mesaPorId(mesaId);

  /// Cambios de comanda por mesa (broadcast).
  Stream<SalaChangedEvent> get changes => _changes.stream;

  /// Avisa (broadcast) cada vez que [configurarEnrutamiento] cambia las
  /// reglas del TPV, para que los comanderos pidan el snapshot de nuevo.
  Stream<void> get enrutamientoChanges => _enrutamientoChanges.stream;

  /// Registra un receptor de efectos.
  void addEffects(SalaEffects effects) => _effects.add(effects);

  /// Completa cuando no queda ningún efecto en vuelo (para tests y para el
  /// cierre ordenado).
  Future<void> idle() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait(_inFlight.toList());
    }
  }

  /// Método y decimales del `Calculator` de FacturaScripts (ajustes del ERP).
  void configurarCalculo({MetodoIva? metodo, int? decimales}) {
    if (metodo != null) _metodoIva = metodo;
    if (decimales != null) _decimales = decimales;
  }

  /// Enrutamiento de comandas configurado en el TPV (familia → cocina/barra),
  /// sin los destinos del ERP.
  EnrutamientoComandas get enrutamiento => _enrutamiento;

  /// Enrutamiento que aplica el host: el del TPV con los destinos de las
  /// familias del ERP (`familias.tpv_destino`) incorporados por nivel. Es el
  /// que se publica a los comanderos en el snapshot de sala.
  EnrutamientoComandas get enrutamientoEfectivo =>
      _enrutamiento.conDestinosErp(_catalog.catalogo?.familias ?? const []);

  /// Sustituye el enrutamiento en caliente. Se aplica a las líneas que se
  /// acepten a partir de ahora (las ya aceptadas conservan su destino: ya
  /// se imprimieron) y viaja en los snapshots siguientes; se avisa por
  /// [enrutamientoChanges] para que los comanderos conectados lo pidan.
  void configurarEnrutamiento(EnrutamientoComandas enrutamiento) {
    if (enrutamiento == _enrutamiento) return;
    _enrutamiento = enrutamiento;
    _log.info(
      'Enrutamiento de comandas: ${enrutamiento.porFamilia.length} reglas, '
      'por defecto ${enrutamiento.porDefecto.name}',
    );
    if (!_enrutamientoChanges.isClosed) _enrutamientoChanges.add(null);
  }

  /// Destino de preparación que el host asigna a un artículo de
  /// [codfamilia], heredando por la jerarquía de familias del catálogo con
  /// las reglas del TPV y los destinos del ERP.
  DestinoPreparacion destinoDe(String? codfamilia) {
    final familias = _catalog.catalogo?.familias ?? const [];
    return _enrutamiento.destinoDe(
      codfamilia,
      madreDe: EnrutamientoComandas.jerarquia(familias),
      erp: EnrutamientoComandas.destinosErp(familias),
    );
  }

  /// Sustituye la configuración de mesas. Las comandas abiertas se conservan
  /// aunque su mesa desaparezca de la lista (se cobran o vacían después).
  /// Sustituye la lista de mesas. Las mesas con comanda abierta que no estén
  /// en [mesas] se conservan al final (si no, su comanda quedaría huérfana y
  /// no se podría cobrar). Devuelve los nombres de las conservadas para que
  /// el llamador avise.
  Future<List<String>> configurarMesas(List<Mesa> mesas) async {
    final conservadas = <Mesa>[];
    await _store.update((s) {
      final ids = {for (final m in mesas) m.id};
      for (final comanda in s.comandas) {
        if (ids.contains(comanda.mesaId)) continue;
        final mesa = s.mesaPorId(comanda.mesaId);
        if (mesa != null && !conservadas.contains(mesa)) conservadas.add(mesa);
      }
      return s.copyWith(mesas: [...mesas, ...conservadas]);
    });
    return [for (final m in conservadas) m.nombre];
  }

  SalaSnapshot snapshot() => SalaSnapshot(
    mesas: mesas,
    comandas: comandas,
    catalogoVersion: _catalog.version,
    generadoEn: _now(),
    enrutamiento: enrutamientoEfectivo,
  );

  // ---------------------------------------------------------------------------
  // Mutaciones

  /// Abre una comanda vacía en la mesa (o devuelve la ya abierta).
  Future<Comanda> abrirMesa(
    String mesaId, {
    String? camarero,
    int? comensales,
  }) async {
    _requireMesa(mesaId);
    final existente = comandaDeMesa(mesaId);
    if (existente != null) return existente;
    final comanda = Comanda(
      id: _newId(),
      mesaId: mesaId,
      abiertaEn: _now(),
      camarero: camarero,
      comensales: comensales,
    );
    await _store.update((s) => s.conComanda(mesaId, comanda));
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: comanda));
    return comanda;
  }

  /// Incorpora líneas nuevas a la mesa (abriéndola si hace falta).
  ///
  /// Idempotente por id de línea contra todo el turno: las líneas de las
  /// comandas abiertas de cualquier mesa y las de los tickets ya cobrados
  /// cuentan como duplicadas. Así una retransmisión que llega tras cobrar
  /// (con el host reiniciado, sin su caché de mensajes) no reabre la mesa.
  /// Si todas son duplicadas y la mesa no tiene comanda abierta, se devuelve
  /// una comanda vacía sin guardarla.
  ///
  /// El host es la autoridad de precios y de destinos: con catálogo, el
  /// precio, el IVA y el `codimpuesto` de cada línea se toman del artículo
  /// (y se avisa si el comandero mandó otros), y el destino de preparación
  /// (cocina/barra) lo fija el [enrutamiento] según la familia del artículo,
  /// sea cual sea el que mandó el comandero o la tablet. Sin catálogo se
  /// conserva el destino recibido.
  Future<ComandaSubmitResult> aceptarLineas(
    ComandaSubmitPayload payload,
  ) async {
    final mesa = _requireMesa(payload.mesaId);
    final actual = comandaDeMesa(payload.mesaId);
    final existentes = _idsLineasDelTurno();
    final candidatas = <LineaComanda>[];
    final corregidas = <String>[];
    final familias = _catalog.catalogo?.familias ?? const [];
    final madreDe = EnrutamientoComandas.jerarquia(familias);
    final erp = EnrutamientoComandas.destinosErp(familias);
    for (final linea in payload.lineas) {
      if (existentes.contains(linea.id)) continue;
      final normalizada = _normalizarLinea(linea, corregidas, madreDe, erp);
      candidatas.add(
        normalizada.estado == EstadoLinea.anulada
            ? normalizada.copyWith(estado: EstadoLinea.enviada)
            : normalizada,
      );
    }
    if (corregidas.isNotEmpty) {
      _log.warning(
        'Mesa ${mesa.nombre}: precio o IVA del comandero distinto del '
        'catálogo en ${corregidas.join(', ')}; se usa el del host',
      );
      _alerts.aviso(
        'Precios corregidos con el catálogo del host',
        detalle:
            'Mesa ${mesa.nombre}: ${corregidas.join(', ')}. El comandero '
            'puede tener el catálogo desactualizado.',
        origen: 'sala',
      );
    }
    if (actual == null && candidatas.isEmpty && payload.lineas.isNotEmpty) {
      // Todo es retransmisión de líneas ya cobradas o de otra mesa: no se
      // reabre la mesa.
      _log.info(
        'Mesa ${mesa.nombre}: ${payload.lineas.length} líneas ya conocidas; '
        'no se reabre la mesa',
      );
      return ComandaSubmitResult(
        comanda: Comanda(
          id: _newId(),
          mesaId: payload.mesaId,
          abiertaEn: _now(),
          camarero: payload.camarero,
          comensales: payload.comensales,
        ),
        lineasNuevas: 0,
        lineasDuplicadas: payload.lineas.length,
      );
    }

    final base =
        actual ??
        Comanda(
          id: _newId(),
          mesaId: payload.mesaId,
          abiertaEn: _now(),
          camarero: payload.camarero,
          comensales: payload.comensales,
        );
    final (:comanda, :nuevas) = base.conLineas(candidatas);
    final resultado = comanda.copyWith(
      camarero: payload.camarero ?? comanda.camarero,
      comensales: payload.comensales ?? comanda.comensales,
    );
    final duplicadas = payload.lineas.length - nuevas.length;

    if (actual == null || nuevas.isNotEmpty || resultado != actual) {
      final fallos = <Object>[];
      await _store.update(
        (s) => _durables(
          s.conComanda(payload.mesaId, resultado),
          fallos,
          (e, snap) =>
              nuevas.isEmpty ? snap : e.alAceptarLineas(snap, mesa, nuevas),
        ),
      );
      _avisarFallosDurables('líneas aceptadas', fallos);
      _emit(SalaChangedEvent(mesaId: payload.mesaId, comanda: resultado));
    }
    if (nuevas.isNotEmpty) {
      _log.info(
        'Mesa ${mesa.nombre}: ${nuevas.length} líneas nuevas '
        '($duplicadas duplicadas)',
      );
      _dispatch(
        'líneas aceptadas',
        (e) => e.onLineasAceptadas(mesa, resultado, nuevas),
      );
    }
    return ComandaSubmitResult(
      comanda: resultado,
      lineasNuevas: nuevas.length,
      lineasDuplicadas: duplicadas,
    );
  }

  /// Anula una línea. Idempotente: anular una ya anulada no hace nada.
  Future<ComandaResult> anularLinea(
    String mesaId,
    String lineaId, {
    String? motivo,
  }) async {
    final mesa = _requireMesa(mesaId);
    final comanda = _requireComanda(mesaId);
    final linea = comanda.lineaPorId(lineaId);
    if (linea == null) {
      throw RemoteRequestException(
        'La línea $lineaId no existe en la mesa ${mesa.nombre}',
        code: SalaErrorCodes.lineaDesconocida,
      );
    }
    if (linea.anulada) return ComandaResult(comanda: comanda);

    final anulada = linea.anular(cuando: _now(), motivo: motivo);
    final actualizada = comanda.conLineaActualizada(anulada);
    final fallos = <Object>[];
    await _store.update(
      (s) => _durables(
        s.conComanda(mesaId, actualizada),
        fallos,
        (e, snap) => e.alAnularLinea(snap, mesa, anulada),
      ),
    );
    _avisarFallosDurables('línea anulada', fallos);
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: actualizada));
    _dispatch(
      'línea anulada',
      (e) => e.onLineasAnuladas(mesa, actualizada, [anulada]),
    );
    return ComandaResult(comanda: actualizada);
  }

  /// Marca o desmarca "cuenta solicitada".
  Future<ComandaResult> marcarCuenta(String mesaId, bool solicitada) async {
    _requireMesa(mesaId);
    final comanda = _requireComanda(mesaId);
    if (comanda.cuentaSolicitada == solicitada) {
      return ComandaResult(comanda: comanda);
    }
    final actualizada = comanda.copyWith(cuentaSolicitada: solicitada);
    await _store.update((s) => s.conComanda(mesaId, actualizada));
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: actualizada));
    return ComandaResult(comanda: actualizada);
  }

  /// Cobra la mesa: calcula los totales legales, archiva el ticket en el
  /// turno con numeración local correlativa y libera la mesa.
  ///
  /// [totalEsperadoCents] es el total que el cajero tenía en pantalla (y,
  /// con tarjeta, el que cobró en el datáfono): si la cuenta de la mesa
  /// cambió entre medias (p. ej. un comandero añadió una línea) no se cobra
  /// nada y se lanza [ValidationException] para que revise el importe.
  ///
  /// Lanza [RemoteRequestException] (`mesa_sin_comanda`, `comanda_cerrada` si
  /// no tiene líneas activas) y [ValidationException] si el efectivo
  /// entregado no cubre el total o el total no es el esperado.
  Future<Ticket> cobrar(
    String mesaId,
    MetodoPago metodoPago, {
    int? entregadoCents,
    int? totalEsperadoCents,
  }) async {
    final (:mesa, :comanda, :activas, :totales) = _prepararCobro(
      mesaId,
      totalEsperadoCents: totalEsperadoCents,
    );
    if (entregadoCents != null && entregadoCents < totales.totalCents) {
      throw ValidationException(
        'El efectivo entregado (${formatCents(entregadoCents)}) no cubre el '
        'total (${formatCents(totales.totalCents)})',
      );
    }
    return _registrarCobro(
      mesa: mesa,
      comanda: comanda,
      activas: activas,
      totales: totales,
      metodoPago: metodoPago,
      entregadoCents: metodoPago == MetodoPago.efectivo ? entregadoCents : null,
    );
  }

  /// Cobro mixto: [efectivoCents] en efectivo y el resto del total con
  /// tarjeta, en un único ticket (y una única factura con un recibo por
  /// forma de pago). [entregadoCents] es lo que entrega el cliente para la
  /// parte en efectivo; el cambio se calcula sobre esa parte.
  ///
  /// Mismo camino durable que [cobrar]: el ticket con su reparto y el
  /// trabajo de factura se guardan en la misma escritura del diario.
  ///
  /// [totalEsperadoCents] es el total sobre el que el cajero hizo el reparto:
  /// la tarjeta se calcula como el resto, así que si la cuenta cambió entre
  /// medias no se cobra nada (ver [cobrar]).
  ///
  /// Lanza [RemoteRequestException] como [cobrar] y [ValidationException] si
  /// alguna parte quedaría a cero o negativa (`0 < efectivo < total`), si el
  /// entregado no cubre la parte en efectivo o si el total no es el esperado.
  Future<Ticket> cobrarMixto(
    String mesaId, {
    required int efectivoCents,
    int? entregadoCents,
    int? totalEsperadoCents,
  }) async {
    final (:mesa, :comanda, :activas, :totales) = _prepararCobro(
      mesaId,
      totalEsperadoCents: totalEsperadoCents,
    );
    final total = totales.totalCents;
    if (efectivoCents <= 0) {
      throw const ValidationException(
        'En un cobro mixto la parte en efectivo debe ser mayor que cero',
      );
    }
    if (efectivoCents >= total) {
      throw ValidationException(
        'La parte en efectivo (${formatCents(efectivoCents)}) debe ser menor '
        'que el total (${formatCents(total)}): la tarjeta no puede quedar a '
        'cero',
      );
    }
    if (entregadoCents != null && entregadoCents < efectivoCents) {
      throw ValidationException(
        'El efectivo entregado (${formatCents(entregadoCents)}) no cubre la '
        'parte en efectivo (${formatCents(efectivoCents)})',
      );
    }
    final pagos = [
      PagoTicket(metodo: MetodoPago.efectivo, importeCents: efectivoCents),
      PagoTicket(
        metodo: MetodoPago.tarjeta,
        importeCents: total - efectivoCents,
      ),
    ];
    return _registrarCobro(
      mesa: mesa,
      comanda: comanda,
      activas: activas,
      totales: totales,
      metodoPago: PagoTicket.metodoPrincipal(pagos),
      pagos: pagos,
      entregadoCents: entregadoCents,
    );
  }

  /// Valida la mesa y su comanda y calcula los totales legales del cobro.
  ///
  /// Si se da [totalEsperadoCents] y no coincide con el total recalculado,
  /// lanza [ValidationException] antes de escribir nada en el diario.
  ({
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> activas,
    TotalesTicket totales,
  })
  _prepararCobro(String mesaId, {int? totalEsperadoCents}) {
    final mesa = _requireMesa(mesaId);
    final comanda = _requireComanda(mesaId);
    final activas = comanda.lineasActivas.toList();
    if (activas.isEmpty) {
      throw RemoteRequestException(
        'La mesa ${mesa.nombre} no tiene líneas que cobrar',
        code: SalaErrorCodes.comandaCerrada,
      );
    }
    final totales = calcularTotales(activas);
    if (totalEsperadoCents != null &&
        totalEsperadoCents != totales.totalCents) {
      throw ValidationException(
        'La cuenta de la mesa ${mesa.nombre} ha cambiado '
        '(${formatCents(totalEsperadoCents)} → '
        '${formatCents(totales.totalCents)}): revisa el cobro',
      );
    }
    return (mesa: mesa, comanda: comanda, activas: activas, totales: totales);
  }

  /// Archiva el ticket, libera la mesa y aplica los efectos durables (el
  /// trabajo de factura, entre otros) en UNA escritura del diario.
  Future<Ticket> _registrarCobro({
    required Mesa mesa,
    required Comanda comanda,
    required List<LineaComanda> activas,
    required TotalesTicket totales,
    required MetodoPago metodoPago,
    List<PagoTicket>? pagos,
    int? entregadoCents,
  }) async {
    final mesaId = mesa.id;
    late final Ticket ticket;
    final fallos = <Object>[];
    // `update` aplica la mutación de forma síncrona: si el ticket no es
    // válido lanza antes de escribir nada en el diario.
    await _store.update((s) {
      ticket = Ticket(
        id: _newId(),
        numeroLocal: s.numeroLocalSiguiente,
        mesaId: mesaId,
        nombreMesa: mesa.nombre,
        comandaId: comanda.id,
        fechaHora: _now(),
        lineas: activas,
        totales: totales,
        metodoPago: metodoPago,
        pagos: pagos,
        entregadoCents: entregadoCents,
        camarero: comanda.camarero,
        comensales: comanda.comensales,
        factura: FacturaSincronizada(estado: EstadoSincronizacion.pendiente),
      );
      return _durables(
        s
            .conComanda(mesaId, null)
            .conTicket(ticket)
            .copyWith(numeroLocalSiguiente: s.numeroLocalSiguiente + 1),
        fallos,
        (e, snap) => e.alCobrar(snap, ticket),
      );
    });
    _avisarFallosDurables('mesa cobrada', fallos);
    _log.info(
      'Mesa ${mesa.nombre} cobrada: ticket ${ticket.numeroLocal} '
      '${formatCents(ticket.totalCents)} (${_formaDeCobro(ticket)})',
    );
    _emit(SalaChangedEvent(mesaId: mesaId));
    _dispatch('mesa cobrada', (e) => e.onMesaCobrada(ticket));
    return ticket;
  }

  static String _formaDeCobro(Ticket ticket) => ticket.esMixto
      ? 'mixto: efectivo ${formatCents(ticket.efectivoCents)} + tarjeta '
            '${formatCents(ticket.tarjetaCents)}'
      : ticket.metodoPago.name;

  /// Libera la mesa sin cobrar: anula todas las líneas activas (revirtiendo
  /// su stock) y retira la comanda.
  Future<void> vaciarMesa(String mesaId, {String? motivo}) async {
    final mesa = _requireMesa(mesaId);
    final comanda = comandaDeMesa(mesaId);
    if (comanda == null) return;
    final cuando = _now();
    final anuladas = <LineaComanda>[];
    var actualizada = comanda;
    for (final linea in comanda.lineasActivas) {
      final anulada = linea.anular(cuando: cuando, motivo: motivo ?? 'vaciar');
      anuladas.add(anulada);
      actualizada = actualizada.conLineaActualizada(anulada);
    }
    final fallos = <Object>[];
    await _store.update((s) {
      var next = s.conComanda(mesaId, null);
      for (final linea in anuladas) {
        next = _durables(
          next,
          fallos,
          (e, snap) => e.alAnularLinea(snap, mesa, linea),
        );
      }
      return next;
    });
    _avisarFallosDurables('mesa vaciada', fallos);
    _emit(SalaChangedEvent(mesaId: mesaId));
    if (anuladas.isNotEmpty) {
      _dispatch(
        'mesa vaciada',
        (e) => e.onLineasAnuladas(mesa, actualizada, anuladas),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Totales

  /// Totales legales de las líneas con la réplica del `Calculator` de FS.
  TotalesTicket calcularTotales(List<LineaComanda> lineas) {
    final totales = calcularTotalesFs(
      [
        for (final linea in lineas)
          LineaCalculo(
            cantidad: linea.cantidad,
            pvpunitario: linea.pvpUnitarioNeto,
            ivaPct: basisPointsToPercent(linea.ivaBp),
            codimpuesto: linea.codimpuesto,
          ),
      ],
      metodo: _metodoIva,
      decimales: _decimales,
    );
    return TotalesTicket(
      netoCents: totales.netoCents,
      ivaCents: totales.totalIvaCents,
      totalCents: totales.totalCents,
      desglose: [
        for (final grupo in totales.grupos)
          DesgloseIva(
            codimpuesto: grupo.codimpuesto,
            ivaBp: basisPointsFromPercent(grupo.ivaPct),
            baseCents: grupo.netoCents,
            cuotaCents: grupo.cuotaIvaCents,
          ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Internos

  Mesa _requireMesa(String mesaId) {
    final mesa = _store.snapshot.mesaPorId(mesaId);
    if (mesa == null) {
      throw RemoteRequestException(
        'La mesa $mesaId no existe',
        code: SalaErrorCodes.mesaDesconocida,
      );
    }
    return mesa;
  }

  Comanda _requireComanda(String mesaId) {
    final comanda = comandaDeMesa(mesaId);
    if (comanda == null) {
      throw RemoteRequestException(
        'La mesa $mesaId no tiene comanda abierta',
        code: SalaErrorCodes.mesaSinComanda,
      );
    }
    return comanda;
  }

  /// Ids de todas las líneas conocidas del turno: comandas abiertas de todas
  /// las mesas y tickets cobrados (persistidos en el diario).
  Set<String> _idsLineasDelTurno() {
    final s = _store.snapshot;
    return {
      for (final comanda in s.comandas)
        for (final linea in comanda.lineas) linea.id,
      for (final ticket in s.ticketsTurno)
        for (final linea in ticket.lineas) linea.id,
    };
  }

  /// Valida la línea y, con catálogo, fija precio, IVA y `codimpuesto` del
  /// artículo (el host es la autoridad de precios) y el destino de
  /// preparación según el enrutamiento por familias ([madreDe] es la
  /// jerarquía de familias del catálogo y [erp] sus destinos en el ERP).
  /// Añade a [corregidas] la descripción de las líneas cuyo precio o
  /// impuesto difería; un destino distinto no se avisa (el comandero puede
  /// no conocer el enrutamiento).
  LineaComanda _normalizarLinea(
    LineaComanda linea,
    List<String> corregidas,
    Map<String, String?> madreDe,
    Map<String, DestinoPreparacion> erp,
  ) {
    final articulo = _validarLinea(linea);
    if (articulo == null) return linea;
    final destino = _enrutamiento.destinoDe(
      articulo.codfamilia,
      madreDe: madreDe,
      erp: erp,
    );
    if (destino != linea.destino) {
      _log.fine(
        "'${linea.descripcion}': destino ${linea.destino.name} → "
        '${destino.name} (familia ${articulo.codfamilia ?? '-'})',
      );
    }
    final iguales =
        linea.pvpUnitarioCents == articulo.pvpCents &&
        linea.pvpUnitarioNeto == articulo.precioNeto &&
        linea.ivaBp == articulo.ivaBp &&
        linea.codimpuesto == articulo.codimpuesto;
    if (iguales) return linea.copyWith(destino: destino);
    corregidas.add(
      "'${linea.descripcion}' (${formatCents(linea.pvpUnitarioCents)} → "
      '${formatCents(articulo.pvpCents)})',
    );
    return LineaComanda(
      id: linea.id,
      referencia: linea.referencia,
      descripcion: linea.descripcion,
      cantidad: linea.cantidad,
      pvpUnitarioCents: articulo.pvpCents,
      pvpUnitarioNeto: articulo.precioNeto,
      ivaBp: articulo.ivaBp,
      codimpuesto: articulo.codimpuesto,
      nota: linea.nota,
      estado: linea.estado,
      destino: destino,
      camarero: linea.camarero,
      creadaEn: linea.creadaEn,
      anuladaEn: linea.anuladaEn,
      motivoAnulacion: linea.motivoAnulacion,
    );
  }

  /// Aplica a [snapshot] los efectos durables de todos los receptores. Un
  /// receptor que lanza no impide la mutación: su error se anota en
  /// [fallos] y se avisa después.
  HostSnapshot _durables(
    HostSnapshot snapshot,
    List<Object> fallos,
    HostSnapshot Function(SalaEffects effects, HostSnapshot snapshot) hook,
  ) {
    var actual = snapshot;
    for (final effects in _effects) {
      try {
        actual = hook(effects, actual);
      } on Object catch (error, stackTrace) {
        _log.severe('Efecto durable falló en $effects', error, stackTrace);
        fallos.add(error);
      }
    }
    return actual;
  }

  void _avisarFallosDurables(String que, List<Object> fallos) {
    for (final error in fallos) {
      _alerts.error(
        'No se pudo registrar el trabajo de "$que"',
        detalle: error.toString(),
        origen: 'sala',
      );
    }
  }

  /// Devuelve el artículo del catálogo (o `null` si no hay catálogo).
  ArticuloCatalogo? _validarLinea(LineaComanda linea) {
    if (!linea.cantidad.isFinite || linea.cantidad <= 0) {
      throw ValidationException(
        "Cantidad no válida en '${linea.descripcion}': ${linea.cantidad}",
      );
    }
    if (linea.descripcion.trim().isEmpty || linea.referencia.trim().isEmpty) {
      throw const ValidationException(
        'Una línea de comanda necesita referencia y descripción',
      );
    }
    final catalogo = _catalog.catalogo;
    if (catalogo == null) return null; // Sin ERP: se confía en el comandero.
    final articulo = catalogo.porReferencia(linea.referencia);
    if (articulo == null || !articulo.vendible) {
      throw RemoteRequestException(
        "El artículo '${linea.referencia}' no está en la carta",
        code: SalaErrorCodes.articuloDesconocido,
      );
    }
    return articulo;
  }

  void _emit(SalaChangedEvent event) {
    if (!_changes.isClosed) _changes.add(event);
  }

  void _dispatch(
    String que,
    Future<void> Function(SalaEffects effects) action,
  ) {
    for (final effects in _effects) {
      late final Future<void> future;
      future = Future<void>.sync(() => action(effects))
          .catchError((Object error, StackTrace stackTrace) {
            _log.warning('Efecto "$que" falló en $effects', error, stackTrace);
            _alerts.aviso(
              'Un efecto de la sala falló ($que)',
              detalle: error.toString(),
              origen: 'sala',
            );
          })
          .whenComplete(() => _inFlight.remove(future));
      _inFlight.add(future);
    }
  }

  Future<void> dispose() async {
    await idle();
    await _changes.close();
    await _enrutamientoChanges.close();
  }
}
