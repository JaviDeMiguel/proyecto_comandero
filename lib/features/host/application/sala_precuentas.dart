part of 'sala_service.dart';

/// Precuentas y comensales de [SalaService]. La API pública, con su
/// documentación, está en la clase; aquí vive la implementación.
extension _SalaPrecuentas on SalaService {
  /// Implementación de [SalaService.emitirPrecuenta].
  Future<PrecuentaEmitida> _emitirPrecuenta(
    String mesaId, {
    String? emitidaPor,
  }) async {
    final mesa = _requireMesa(mesaId);
    final comanda = _requireComanda(mesaId);
    final activas = comanda.lineasActivas.toList();
    if (activas.isEmpty) {
      throw const ValidationException(
        'La mesa no tiene líneas: no hay precuenta que imprimir',
      );
    }
    final precuenta = PrecuentaEmitida(
      numero: comanda.siguienteNumeroPrecuenta,
      emitidaEn: _now(),
      comandaId: comanda.id,
      nombreMesa: mesa.nombre,
      lineas: [for (final linea in activas) LineaPrecuenta.desde(linea)],
      totales: calcularTotales(activas),
      comensales: comanda.comensales,
      emitidaPor: emitidaPor,
    );
    final actualizada = comanda.conPrecuenta(precuenta);
    await _store.update((s) => s.conComanda(mesaId, actualizada));
    SalaService._log.info(
      'Mesa ${mesa.nombre}: precuenta nº ${precuenta.numero} de '
      '${formatCents(precuenta.totalCents)} (${emitidaPor ?? '-'})',
    );
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: actualizada));
    return precuenta;
  }

  /// Implementación de [SalaService.fijarComensales].
  Future<ComandaResult> _fijarComensales(
    String mesaId,
    int comensales, {
    String? camarero,
  }) async {
    if (!_comensalesEnRango(comensales)) {
      throw ValidationException(
        'Los comensales deben estar entre ${SalaService.minComensales} y '
        '${SalaService.maxComensales} (recibidos: $comensales)',
      );
    }
    _requireMesa(mesaId);
    final comanda = comandaDeMesa(mesaId);
    if (comanda == null) {
      return ComandaResult(
        comanda: await abrirMesa(
          mesaId,
          camarero: camarero,
          comensales: comensales,
        ),
      );
    }
    if (comanda.comensales == comensales) {
      return ComandaResult(comanda: comanda);
    }
    final actualizada = comanda.copyWith(comensales: comensales);
    await _store.update((s) => s.conComanda(mesaId, actualizada));
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: actualizada));
    return ComandaResult(comanda: actualizada);
  }

  /// Comensales con los que se acepta un envío del comandero
  /// ([SalaService.aceptarLineas]): los del [payload] si están entre
  /// [SalaService.minComensales] y [SalaService.maxComensales]. El TCP es un
  /// borde del sistema: un valor fuera de rango (un comandero antiguo o con
  /// fallos) se ignora sin lanzar, para no perder las líneas del envío, y la
  /// mesa conserva los comensales que tenía.
  int? _comensalesAceptados(ComandaSubmitPayload payload) {
    final comensales = payload.comensales;
    if (comensales == null || _comensalesEnRango(comensales)) {
      return comensales;
    }
    SalaService._log.fine(
      'Mesa ${payload.mesaId}: comensales $comensales fuera de '
      '${SalaService.minComensales}-${SalaService.maxComensales}; se ignoran',
    );
    return null;
  }

  bool _comensalesEnRango(int comensales) =>
      comensales >= SalaService.minComensales &&
      comensales <= SalaService.maxComensales;
}
