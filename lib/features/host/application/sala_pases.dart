part of 'sala_service.dart';

/// Pases y marchas de [SalaService]: la orden «Marchar» de la tablet o del
/// comandero y las marchas automáticas al aceptar líneas. La API pública,
/// con su documentación, está en la clase; aquí vive la implementación.
extension _SalaPases on SalaService {
  /// Implementación de [SalaService.marcharPase].
  Future<ComandaResult> _marcharPase(
    String mesaId,
    int pase, {
    required String marchaId,
    String? comandaId,
    String? camarero,
  }) async {
    final mesa = _requireMesa(mesaId);
    final comanda = _requireComanda(mesaId);
    if (comandaId != null && comandaId != comanda.id) {
      throw RemoteRequestException(
        'La comanda de la mesa ${mesa.nombre} ya se cerró',
        code: SalaErrorCodes.mesaSinComanda,
      );
    }
    if (comanda.marchaPorId(marchaId) != null) {
      // Retransmisión de una marcha ya registrada: sin efectos.
      return ComandaResult(comanda: comanda);
    }
    final lineas = comanda.lineasActivas.where((l) => l.pase == pase).toList();
    if (lineas.isEmpty) {
      if (!_pases.activos || !_pases.existe(pase)) {
        throw RemoteRequestException(
          'El pase $pase no existe',
          code: SalaErrorCodes.paseNoValido,
        );
      }
      throw RemoteRequestException(
        'La mesa ${mesa.nombre} no tiene líneas de ${_pases.nombreDe(pase)}',
        code: SalaErrorCodes.paseSinLineas,
      );
    }
    final marcha = MarchaPase(
      id: marchaId,
      pase: pase,
      cuando: _now(),
      camarero: camarero,
      repetida: comanda.pasesMarchados.contains(pase),
    );
    var actualizada = comanda;
    var registrada = false;
    await _store.update((s) {
      // Atómico: la comanda sigue siendo la misma y la marcha aún no existe.
      final abierta = s.comandaDeMesa(mesaId);
      if (abierta == null ||
          abierta.id != comanda.id ||
          abierta.marchaPorId(marchaId) != null) {
        return s;
      }
      registrada = true;
      actualizada = abierta.conMarcha(marcha);
      return s.conComanda(mesaId, actualizada);
    });
    final marchada = actualizada;
    if (!registrada) return ComandaResult(comanda: marchada);
    SalaService._log.info(
      'Mesa ${mesa.nombre}: marchado el pase ${_pases.etiqueta(pase)}'
      '${marcha.repetida ? ' (repetido)' : ''} con ${lineas.length} líneas',
    );
    _emit(SalaChangedEvent(mesaId: mesaId, comanda: marchada));
    _dispatch(
      'pase marchado',
      (e) => e.onPaseMarchado(mesa, marchada, marcha, lineas),
    );
    return ComandaResult(comanda: marchada);
  }

  /// Pase con el que se acepta la línea: con los pases activos se conserva
  /// cualquier pase positivo, esté o no en la configuración (se imprime como
  /// «Pase N» y espera a que lo marchen); con los pases desactivados se
  /// descarta, porque las comandas salen planas.
  int? _paseAceptado(LineaComanda linea) {
    final pase = linea.pase;
    if (pase == null || pase < 1) return null;
    if (_pases.activos) return pase;
    SalaService._log.fine(
      "'${linea.descripcion}': pase $pase descartado (pases desactivados)",
    );
    return null;
  }

  /// Marchas automáticas al aceptar [nuevas] líneas en [comanda] (pura: no
  /// escribe nada; se llama dentro de la escritura que acepta las líneas).
  /// Solo con los pases activos:
  ///
  /// * con `marcharAlEnviar`, si la comanda aún no tiene ninguna marcha, se
  ///   marcha el pase más bajo de las líneas nuevas (el 1º marcha con el
  ///   primer envío, y la mesa que solo pide segundos también);
  /// * siempre, cualquier pase de las líneas nuevas menor que el mayor ya
  ///   marchado queda marchado: unos entrantes pedidos con los segundos en
  ///   marcha se preparan en el acto en vez de esperar.
  Comanda _conMarchasAutomaticas(
    Comanda comanda,
    List<LineaComanda> nuevas, {
    String? camarero,
  }) {
    if (!_pases.activos) return comanda;
    final pasesNuevos = {for (final l in nuevas) ?l.pase};
    if (pasesNuevos.isEmpty) return comanda;
    final marchados = comanda.pasesMarchados;
    final aMarchar = <int>{
      if (_pases.marcharAlEnviar && !comanda.tieneMarchas)
        pasesNuevos.reduce(min),
    };
    final mayor = [...marchados, ...aMarchar].fold(0, max);
    aMarchar.addAll(
      pasesNuevos.where((p) => p < mayor && !marchados.contains(p)),
    );
    var resultado = comanda;
    for (final pase in aMarchar.toList()..sort()) {
      resultado = resultado.conMarcha(
        MarchaPase(
          id: _newId(),
          pase: pase,
          cuando: _now(),
          camarero: camarero,
          automatica: true,
        ),
      );
    }
    return resultado;
  }
}
