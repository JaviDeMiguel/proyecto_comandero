part of 'comandero_controller.dart';

/// Pases y comensales de la comanda abierta desde el comandero.
///
/// Es un `part` de `comandero_controller.dart` para compartir su biblioteca:
/// usa la cola fiable (`_requestFiable`), el contador `_marchasEnCurso` y la
/// actualización de la comanda local sin hacer crecer el controlador.
extension ComanderoPases on ComanderoController {
  /// Comensales admitidos por mesa, como en el host.
  static const int minComensales = 1;
  static const int maxComensales = 99;

  /// Configuración de pases que publica el host en el snapshot de sala;
  /// `null` con un host de una versión anterior o que no se entiende. La
  /// interfaz de pases y los botones «Marchar» solo se muestran si
  /// `pases?.activos == true`.
  PasesConfig? get pases => _sala?.pases;

  /// Marcha el [pase] de la comanda abierta de la mesa (petición fiable).
  ///
  /// Cada llamada genera un `marchaId` nuevo que viaja dentro del payload:
  /// sin conexión la petición queda en cola y sale al reconectar con el
  /// mismo id de mensaje y el mismo `marchaId`, así que el host reconoce la
  /// retransmisión y no repite ni la marcha ni la impresión. También lleva
  /// el `comandaId` de la comanda que ve el comandero: si la mesa se cobró y
  /// se volvió a abrir entre medias, el host responde `mesa_sin_comanda` sin
  /// marchar nada a los clientes nuevos. Por eso, si el comandero no ve
  /// ninguna comanda en la mesa, no manda nada. Mientras espera respuesta
  /// cuenta en [ComanderoController.pendientes] y, al cerrar para un
  /// traspaso, en `peticionesPerdidas`.
  ///
  /// Devuelve la comanda con sus marchas al día. Lanza
  /// [ComanderoSalaException] con `mesa_sin_comanda` si la mesa no tiene
  /// comanda en el último snapshot o si el host la rechaza
  /// (`pase_no_valido`, `pase_sin_lineas`, `mesa_sin_comanda`,
  /// `mesa_desconocida`), [RemoteRequestException] con código `unknown_type`
  /// si el host es de una versión anterior, [SinConexionException] si no hay
  /// host objetivo y [ValidationException] si [pase] no es positivo.
  Future<Comanda> marcharPase(String mesaId, int pase) async {
    _checkNotDisposed();
    LineaPedido.validarPase(pase);
    if (_host == null) throw _sinHostObjetivo;
    final comanda = comandaDe(mesaId);
    if (comanda == null) {
      throw _sinComanda(
        mesaId,
        'La mesa no tiene comanda abierta: no hay nada que marchar',
      );
    }
    final payload = MarcharPasePayload(
      mesaId: mesaId,
      pase: pase,
      marchaId: _newId(),
      comandaId: comanda.id,
    );
    final ProtocolMessage ack;
    _marchasEnCurso++;
    try {
      ack = await _requestFiable(
        SalaMessageTypes.paseMarchar,
        payload.toJson(),
        mesaId: mesaId,
      );
    } finally {
      _marchasEnCurso--;
    }
    final result = _parse(
      () => ComandaResult.fromJson(ack.payload),
      SalaMessageTypes.paseMarchar,
    );
    _actualizarComanda(mesaId, result.comanda);
    return result.comanda;
  }

  /// Fija los [comensales] de la comanda abierta de la mesa con un
  /// `comanda.submit` fiable sin líneas que lleva el `comandaId` de esa
  /// comanda: un host nuevo no lo aplica si esa comanda ya se cerró ni abre
  /// una mesa libre con él, y no consume nº de envío.
  ///
  /// Solo con la comanda abierta: en una mesa libre el valor debe esperar al
  /// primer envío de líneas ([ComanderoController.enviar] con `comensales`).
  /// Si el host responde con otra comanda (la que veía el comandero se cerró
  /// entre medias), no la toma por buena: pide el snapshot de sala y avisa.
  ///
  /// Lanza [ComanderoSalaException] con `mesa_sin_comanda` si la mesa no
  /// tiene comanda en el último snapshot o la comanda ya se cerró,
  /// [ValidationException] si [comensales] no está entre [minComensales] y
  /// [maxComensales], [SinConexionException] si no hay host objetivo y los
  /// mismos errores de red y de host que [ComanderoController.enviar].
  Future<Comanda> fijarComensales(String mesaId, int comensales) async {
    _checkNotDisposed();
    if (comensales < minComensales || comensales > maxComensales) {
      throw ValidationException(
        'Los comensales deben estar entre $minComensales y $maxComensales '
        '(recibido $comensales)',
      );
    }
    if (_host == null) throw _sinHostObjetivo;
    final comanda = comandaDe(mesaId);
    if (comanda == null) {
      throw _sinComanda(
        mesaId,
        'La mesa no tiene comanda abierta: los comensales se enviarán con el '
        'primer pedido',
      );
    }
    final payload = ComandaSubmitPayload(
      mesaId: mesaId,
      lineas: const [],
      comensales: comensales,
      comandaId: comanda.id,
    );
    final ack = await _requestFiable(
      SalaMessageTypes.comandaSubmit,
      payload.toJson(),
      mesaId: mesaId,
    );
    final result = _parse(
      () => ComandaSubmitResult.fromJson(ack.payload),
      SalaMessageTypes.comandaSubmit,
    );
    if (result.comanda.id != comanda.id) {
      // La comanda que veía el comandero ya se cerró: un host nuevo no aplicó
      // nada y devolvió la abierta ahora o, con la mesa libre, una vacía que
      // no guardó (mostrarla dejaría una mesa fantasma). Se pide la sala real.
      unawaited(_refrescarSalaEnSesion(_sesion, 'tras fijar comensales'));
      throw _sinComanda(
        mesaId,
        'La comanda que veías ya se cerró: revisa la mesa y, si hace falta, '
        'vuelve a fijar los comensales',
      );
    }
    _actualizarComanda(mesaId, result.comanda);
    return result.comanda;
  }

  /// Rechazo local de una operación sobre la comanda abierta de la mesa
  /// cuando el comandero no la ve (o la que veía ya se cerró).
  ComanderoSalaException _sinComanda(String mesaId, String mensaje) =>
      ComanderoSalaException(
        mensaje,
        code: SalaErrorCodes.mesaSinComanda,
        mesaId: mesaId,
      );
}
