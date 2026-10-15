part of 'sala_service.dart';

/// Cobro y vaciado de mesas de [SalaService]. La API pública, con su
/// documentación, está en la clase (así la ven también los ficheros que no
/// importan esta biblioteca); aquí vive la implementación.
///
/// El cobro archiva el ticket (con las precuentas emitidas a la mesa) y el
/// vaciado anula las líneas activas y archiva esas precuentas como «sin
/// cobro» para el Cierre Z, todo en una única escritura del diario.
extension _SalaCobro on SalaService {
  /// Implementación de [SalaService.cobrar].
  Future<Ticket> _cobrar(
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

  /// Implementación de [SalaService.cobrarMixto].
  Future<Ticket> _cobrarMixto(
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

  /// Archiva el ticket (con las precuentas emitidas a la mesa), libera la
  /// mesa y aplica los efectos durables (el trabajo de factura, entre otros)
  /// en UNA escritura del diario.
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
        precuentas: comanda.precuentas,
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
    SalaService._log.info(
      'Mesa ${mesa.nombre} cobrada: ticket ${ticket.numeroLocal} '
      '${formatCents(ticket.totalCents)} (${_formaDeCobro(ticket)})',
    );
    _emit(SalaChangedEvent(mesaId: mesaId));
    _dispatch('mesa cobrada', (e) => e.onMesaCobrada(ticket));
    return ticket;
  }

  /// Implementación de [SalaService.vaciarMesa].
  Future<void> _vaciarMesa(String mesaId, {String? motivo}) async {
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
    final sinCobro = [
      for (final precuenta in comanda.precuentas)
        PrecuentaSinCobro(
          precuenta: precuenta,
          vaciadaEn: cuando,
          motivo: motivo,
        ),
    ];
    final fallos = <Object>[];
    await _store.update((s) {
      var next = s.conComanda(mesaId, null).conPrecuentasSinCobro(sinCobro);
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
    if (sinCobro.isNotEmpty) {
      SalaService._log.info(
        'Mesa ${mesa.nombre} vaciada con ${sinCobro.length} precuentas sin '
        'cobro (${motivo ?? 'sin motivo'})',
      );
    }
    _emit(SalaChangedEvent(mesaId: mesaId));
    if (anuladas.isNotEmpty) {
      _dispatch(
        'mesa vaciada',
        (e) => e.onLineasAnuladas(mesa, actualizada, anuladas),
      );
    }
  }
}

String _formaDeCobro(Ticket ticket) => ticket.esMixto
    ? 'mixto: efectivo ${formatCents(ticket.efectivoCents)} + tarjeta '
          '${formatCents(ticket.tarjetaCents)}'
    : ticket.metodoPago.name;
