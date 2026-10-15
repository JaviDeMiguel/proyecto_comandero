/// Documentos de preparación del host (§5.2, §5.7, §5.9 y §5.10 del diseño
/// de impresión): la comanda de cada envío, el MARCHAR de un pase, la
/// anulación y la reimpresión de una comanda, siempre un ticket por puesto.
library;

import '../../../../core/errors/app_exception.dart';
import '../../../../core/isolates/escpos/ticket_documents.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../../sala/domain/comanda.dart';
import '../../../sala/domain/linea_comanda.dart';
import '../../../sala/domain/marcha_pase.dart';
import '../../../sala/domain/mesa.dart';
import '../../../sala/domain/pases.dart';
import '../../domain/host_settings.dart';
import '../alert_bus.dart';
import 'canal_impresion.dart';
import 'mapeo_documentos.dart';

/// Impresora de un puesto (`ImpresionSettings.impresoraDe`): la propia o,
/// si no tiene, la del otro puesto ([respaldo]).
typedef _Impresora = ({PrinterEndpoint endpoint, bool respaldo});

/// Un puesto de una reimpresión: sus líneas del alcance y su impresora.
typedef _PuestoAReimprimir = ({
  DestinoPreparacion destino,
  List<LineaComanda> lineas,
  _Impresora impresora,
});

/// Imprime el documento de un puesto con sus líneas y devuelve el id del
/// trabajo (o `null` si no se encoló), como `CanalImpresion.enviar`.
typedef _ImprimirPuesto = Future<String?> Function(
  DestinoPreparacion destino,
  List<LineaComanda> lineas,
  _Impresora impresora,
);

/// Colaborador de la fachada `PrintingService` para los documentos de
/// preparación. No implementa `SalaEffects`: la fachada lo llama desde sus
/// efectos (`onLineasAceptadas` → [imprimirEnvio], `onPaseMarchado` →
/// [imprimirMarcha], `onLineasAnuladas` → [imprimirAnulacion]) y desde la
/// acción de la interfaz [reimprimirComanda].
///
/// - **Un ticket por puesto:** las líneas se reparten por `destino` y cada
///   puesto (cocina y después barra) recibe solo las suyas en la impresora
///   de `ImpresionSettings.impresoraDe(destino)`. Si no tiene impresora
///   propia, su ticket sale aparte por la del otro puesto con la nota «Sin
///   impresora de barra: llevar a barra».
/// - **Perfil:** el canal genera cada documento con el perfil de la
///   impresora que lo imprime (la de respaldo incluida): papel, avance
///   inicial, copias y aviso sonoro. Todos son documentos de preparación.
/// - **Errores:** las impresiones automáticas nunca lanzan. El canal
///   convierte en aviso una `AppException`; un fallo no tipado en un puesto
///   se avisa aquí y no impide que impriman los demás. La reimpresión, que
///   pide la interfaz, lanza.
final class ComandasImpresion {
  /// [settings] y [now] se leen en cada llamada: los ajustes pueden cambiar
  /// en caliente (`PrintingService.configurar`).
  ComandasImpresion({
    required this._canal,
    required this._alerts,
    required this._settings,
    required this._now,
  });

  static final Logger _log = appLogger('host.impresion');

  final CanalImpresion _canal;
  final AlertBus _alerts;
  final ImpresionSettings Function() _settings;
  final DateTime Function() _now;

  /// Comanda de un envío (§5.2): por puesto, sus [nuevas] líneas con el nº
  /// de envío, la hora de aceptación (el reloj), el ordinal del bloque de
  /// envío y, con los pases activos, los grupos por pase con ESPERAR en los
  /// no marchados de [comanda], que ya trae las marchas automáticas del
  /// envío (sus pases salen normales). Nada si la impresión de comandas está
  /// desactivada.
  Future<void> imprimirEnvio(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async {
    final ajustes = _settings();
    if (!ajustes.imprimirComandas) return;
    final ahora = _now();
    await _imprimirPorPuesto(
      mesa,
      nuevas,
      ajustes: ajustes,
      documento: 'la comanda',
      imprimir: (destino, lineas, impresora) => _canal.enviar(
        impresora.endpoint,
        _descripcionEnvio(mesa, destino, lineas.first.envio),
        (perfil) => generarComandaCocinaEnIsolate(
          datosComanda(
            mesa,
            comanda,
            lineas,
            destino: destino,
            pases: ajustes.pases,
            perfil: perfil,
            ahora: ahora,
            respaldo: impresora.respaldo,
          ),
          runner: _canal.runner,
        ),
        preparacion: true,
      ),
    );
  }

  /// MARCHAR del pase de [marcha] (§5.7): uno por puesto con líneas activas
  /// de ese pase y solo con las suyas; un puesto sin ellas no imprime nada.
  /// [comanda] ya incluye [marcha] (de ahí salen REPETIDO y la hora de la
  /// marcha anterior); de [lineas], las de la sala, se ignoran las anuladas
  /// y las de otro pase. Nada si la impresión de comandas está desactivada.
  Future<void> imprimirMarcha(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) async {
    final ajustes = _settings();
    if (!ajustes.imprimirComandas) return;
    final pases = ajustes.pases;
    await _imprimirPorPuesto(
      mesa,
      lineas.where((linea) => !linea.anulada && linea.pase == marcha.pase),
      ajustes: ajustes,
      documento: 'el MARCHAR',
      imprimir: (destino, delPase, impresora) => _canal.enviar(
        impresora.endpoint,
        _descripcionMarcha(mesa, destino, marcha, pases),
        (perfil) => generarMarcharEnIsolate(
          datosMarchar(
            mesa,
            comanda,
            marcha,
            delPase,
            destino: destino,
            pases: pases,
            perfil: perfil,
            respaldo: impresora.respaldo,
          ),
          runner: _canal.runner,
        ),
        preparacion: true,
      ),
    );
  }

  /// Anulación de [anuladas] (§5.9): una por puesto con el título en banda,
  /// la hora de la anulación (el reloj) y, por línea, la cantidad en
  /// negativo, su nota original, el motivo («mesa vaciada» al vaciar) y su
  /// envío. Nada si la impresión de comandas está desactivada.
  Future<void> imprimirAnulacion(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) async {
    final ajustes = _settings();
    if (!ajustes.imprimirComandas) return;
    final ahora = _now();
    await _imprimirPorPuesto(
      mesa,
      anuladas,
      ajustes: ajustes,
      documento: 'la anulación',
      imprimir: (destino, lineas, impresora) => _canal.enviar(
        impresora.endpoint,
        'Anulación ${_mesa(mesa)} · ${_puesto(destino)}',
        (perfil) => generarComandaCocinaEnIsolate(
          datosAnulacion(
            mesa,
            comanda,
            lineas,
            destino: destino,
            perfil: perfil,
            ahora: ahora,
            respaldo: impresora.respaldo,
          ),
          runner: _canal.runner,
        ),
        preparacion: true,
      ),
    );
  }

  /// Reimprime la comanda de [mesa] en los [destinos] elegidos (§5.10). Con
  /// [AlcanceReimpresion.todo], sus líneas activas; con
  /// [AlcanceReimpresion.ultimoEnvio], el último bloque de envío sin las
  /// anuladas, aunque su número se repita tras un Cierre Z. Un ticket por
  /// puesto con la banda del [motivo] («REIMPRESIÓN · PREPARAR» o «COPIA ·
  /// NO PREPARAR»), la fecha y hora del reloj con el [dispositivo]
  /// («Reimpresa 09/10/2026 21:40 · Caja 1»), los números de los envíos y
  /// ESPERAR según las marchas actuales; una sola copia, con el aviso sonoro
  /// del perfil. Es una acción explícita: no depende de «imprimir comandas»
  /// y no escribe nada en el diario.
  ///
  /// Lanza [ValidationException] si no hay nada que reimprimir (ningún
  /// puesto elegido o ninguna línea suya en el alcance) y después
  /// [PrinterException] si no hay impresora de comandas. Si falla un puesto,
  /// intenta los demás y relanza el primer error, que el canal ya ha
  /// traducido a [AppException].
  Future<void> reimprimirComanda(
    Mesa mesa,
    Comanda comanda, {
    required Set<DestinoPreparacion> destinos,
    required AlcanceReimpresion alcance,
    required MotivoReimpresion motivo,
    required String dispositivo,
  }) async {
    final ajustes = _settings();
    final puestos = _puestosAReimprimir(
      comanda,
      ajustes,
      destinos: destinos,
      alcance: alcance,
    );
    final ahora = _now();
    (Object, StackTrace)? primerFallo;
    for (final puesto in puestos) {
      try {
        await _enviarReimpresion(
          mesa,
          comanda,
          puesto,
          pases: ajustes.pases,
          motivo: motivo,
          dispositivo: dispositivo,
          ahora: ahora,
        );
      } on Object catch (error, stackTrace) {
        // Se relanza el primer fallo; los demás solo quedan en el registro.
        if (primerFallo != null) {
          _log.warning(
            'Tampoco se pudo reimprimir la comanda de '
            '${_puesto(puesto.destino)} de ${_mesa(mesa)}',
            error,
            stackTrace,
          );
        }
        primerFallo ??= (error, stackTrace);
      }
    }
    if (primerFallo case (final error, final stackTrace)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Encola la reimpresión de [puesto] en su impresora (§5.10): una sola
  /// copia, con el aviso sonoro del perfil, y lanza la [AppException] si no
  /// se puede generar o encolar (el canal traduce los errores no tipados).
  Future<void> _enviarReimpresion(
    Mesa mesa,
    Comanda comanda,
    _PuestoAReimprimir puesto, {
    required PasesConfig pases,
    required MotivoReimpresion motivo,
    required String dispositivo,
    required DateTime ahora,
  }) async {
    final (:destino, :lineas, :impresora) = puesto;
    await _canal.enviar(
      impresora.endpoint,
      _descripcionReimpresion(mesa, destino, motivo),
      (perfil) => generarComandaCocinaEnIsolate(
        datosReimpresion(
          mesa,
          comanda,
          lineas,
          destino: destino,
          pases: pases,
          perfil: perfil,
          motivo: motivo,
          dispositivo: dispositivo,
          ahora: ahora,
          respaldo: impresora.respaldo,
        ),
        runner: _canal.runner,
      ),
      preparacion: true,
      copias: 1,
      lanzarErrores: true,
    );
  }

  /// Imprime [lineas] por puesto con [imprimir], en el orden de los puestos
  /// ([_porPuesto]). Un puesto sin impresora de comandas, propia ni de
  /// respaldo, no imprime. Cada puesto se aísla: un fallo no tipado al
  /// generar o encolar el suyo (un isolate que no arranca, un error de
  /// programación) se avisa como «No se pudo imprimir [documento] de cocina
  /// de Mesa 7» y los demás puestos imprimen igualmente.
  Future<void> _imprimirPorPuesto(
    Mesa mesa,
    Iterable<LineaComanda> lineas, {
    required ImpresionSettings ajustes,
    required String documento,
    required _ImprimirPuesto imprimir,
  }) async {
    for (final (destino, delPuesto) in _porPuesto(lineas)) {
      final impresora = ajustes.impresoraDe(destino);
      if (impresora == null) continue;
      try {
        await imprimir(destino, delPuesto, impresora);
      } on Object catch (error, stackTrace) {
        final titulo =
            'No se pudo imprimir $documento de ${_puesto(destino)} de '
            '${_mesa(mesa)}';
        _log.warning('$titulo: error inesperado', error, stackTrace);
        _alerts.error(titulo, detalle: error.toString(), origen: 'impresion');
      }
    }
  }
}

/// [lineas] repartidas por puesto, en el orden de [DestinoPreparacion]
/// (cocina y después barra) y en su orden de llegada; solo los puestos con
/// alguna línea.
List<(DestinoPreparacion, List<LineaComanda>)> _porPuesto(
  Iterable<LineaComanda> lineas,
) {
  final puestos = <(DestinoPreparacion, List<LineaComanda>)>[];
  for (final destino in DestinoPreparacion.values) {
    final delPuesto = [
      for (final linea in lineas)
        if (linea.destino == destino) linea,
    ];
    if (delPuesto.isNotEmpty) {
      puestos.add((destino, List<LineaComanda>.unmodifiable(delPuesto)));
    }
  }
  return puestos;
}

/// Puestos de una reimpresión con sus líneas y su impresora (§5.10, pasos 1
/// y 2): las líneas del [alcance] de los [destinos] elegidos. Lanza
/// [ValidationException] si no queda ninguna y, después,
/// [PrinterException] si ninguno de esos puestos tiene impresora.
List<_PuestoAReimprimir> _puestosAReimprimir(
  Comanda comanda,
  ImpresionSettings ajustes, {
  required Set<DestinoPreparacion> destinos,
  required AlcanceReimpresion alcance,
}) {
  final puestos = _porPuesto(
    lineasAReimprimir(
      comanda,
      alcance,
    ).where((linea) => destinos.contains(linea.destino)),
  );
  if (puestos.isEmpty) {
    throw ValidationException(_nadaQueReimprimir(alcance, destinos));
  }
  final conImpresora = [
    for (final (destino, lineas) in puestos)
      if (ajustes.impresoraDe(destino) case final impresora?)
        (destino: destino, lineas: lineas, impresora: impresora),
  ];
  if (conImpresora.isEmpty) {
    throw const PrinterException('No hay impresora de comandas configurada');
  }
  return conImpresora;
}

/// Nombre del puesto en los textos: «cocina» o «barra».
String _puesto(DestinoPreparacion destino) =>
    tituloPuesto(destino).toLowerCase();

/// La mesa como se imprime: «Mesa 7» también si se llama «7».
String _mesa(Mesa mesa) => etiquetaMesa(mesa.nombre);

/// «Comanda Nº 12 · Mesa 7 · cocina»; sin nº de envío (líneas de un diario
/// anterior), «Comanda Mesa 7 · cocina».
String _descripcionEnvio(Mesa mesa, DestinoPreparacion destino, int? envio) {
  final numero = envio == null ? '' : ' Nº $envio ·';
  return 'Comanda$numero ${_mesa(mesa)} · ${_puesto(destino)}';
}

/// «Marchar Segundos · Mesa 7 · cocina», con «(repetido)» tras el nombre
/// del pase si ya estaba marchado; un pase fuera de la configuración es
/// «Pase N».
String _descripcionMarcha(
  Mesa mesa,
  DestinoPreparacion destino,
  MarchaPase marcha,
  PasesConfig pases,
) {
  final repetida = marcha.repetida ? ' (repetido)' : '';
  return 'Marchar ${pases.nombreDe(marcha.pase)}$repetida · ${_mesa(mesa)} · '
      '${_puesto(destino)}';
}

/// «Reimpresión de comanda · Mesa 7 · cocina» si no salió o se perdió, y
/// «Copia de comanda · Mesa 7 · cocina» si es una copia para el puesto.
String _descripcionReimpresion(
  Mesa mesa,
  DestinoPreparacion destino,
  MotivoReimpresion motivo,
) {
  final que = switch (motivo) {
    MotivoReimpresion.noSalio => 'Reimpresión',
    MotivoReimpresion.copia => 'Copia',
  };
  return '$que de comanda · ${_mesa(mesa)} · ${_puesto(destino)}';
}

/// Por qué no hay nada que reimprimir: «Elige al menos un puesto para
/// reimprimir», «El último envío no tiene líneas de barra» o «La comanda no
/// tiene líneas de cocina ni de barra».
String _nadaQueReimprimir(
  AlcanceReimpresion alcance,
  Set<DestinoPreparacion> destinos,
) {
  if (destinos.isEmpty) return 'Elige al menos un puesto para reimprimir';
  final origen = switch (alcance) {
    AlcanceReimpresion.todo => 'La comanda',
    AlcanceReimpresion.ultimoEnvio => 'El último envío',
  };
  final puestos = [
    for (final destino in DestinoPreparacion.values)
      if (destinos.contains(destino)) 'de ${_puesto(destino)}',
  ].join(' ni ');
  return '$origen no tiene líneas $puestos';
}
