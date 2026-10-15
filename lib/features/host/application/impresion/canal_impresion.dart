/// Canal de impresión del host (§5.12 del diseño de impresión): genera cada
/// documento con el perfil de la impresora que lo imprime, añade las copias
/// y el aviso sonoro de los documentos de preparación, lo encola con su
/// política de reintento y sigue el trabajo hasta que termina.
library;

import 'dart:async';
import 'dart:typed_data';

import '../../../../core/errors/app_exception.dart';
import '../../../../core/isolates/escpos/escpos_builder.dart'
    show ZumbadorModo, bytesAviso;
import '../../../../core/isolates/isolate_runner.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/printing/print_queue.dart'
    show PrintRetryPolicy;
import '../../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../../impresion/domain/formato_impresion.dart';
import '../../domain/host_settings.dart';
import '../alert_bus.dart';
import '../ports.dart';

/// Canal común de todos los documentos que imprime el host.
///
/// - **Perfil:** cada trabajo se genera con
///   `ImpresionSettings.perfilPara(endpoint)` de la impresora que realmente
///   lo imprime (la propia del puesto o la de respaldo). Ese perfil ya viene
///   resuelto: el zumbador del conector del cajón no suena en la impresora
///   que sirve a los tickets (decisión C).
/// - **Copias y aviso:** solo en los documentos de preparación (comanda,
///   MARCHAR, anulación, reimpresión): las copias se concatenan en **un**
///   trabajo (cada una con su `init` y su corte) y el aviso sonoro va una vez,
///   tras la última. Un documento de cliente sale siempre una vez y sin
///   aviso: una segunda impresión de una factura es un DUPLICADO, no una
///   copia.
/// - **Errores:** sin `lanzarErrores` (impresiones automáticas) una
///   [AppException] al generar o al encolar se convierte en aviso operativo,
///   y un error no tipado (isolate caído) se relanza tal cual, como hoy: lo
///   recoge el aislamiento de quien llama (el de cada puesto en las
///   comandas, §5.2, paso 3). Con él (acciones de la interfaz) se relanza la
///   [AppException], y un error no tipado se traduce a [PrinterException].
///   Un trabajo que falla después, en la impresora, se avisa como «Fallo de
///   impresión», con su id en `trabajoImpresion` si la cola admite
///   reintentos ([RetryablePrinterPort]).
/// - **Reintentos (P2, §5.17):** [reintentar] reencola un trabajo fallido
///   con sus mismos bytes y lo vuelve a seguir; un nuevo fallo da otro aviso.
///   El canal no sabe qué es una factura: el reintento de las facturas lo
///   decide `TicketsImpresion`.
final class CanalImpresion {
  CanalImpresion({
    required this._alerts,
    required this.runner,
    required this._settings,
    required this._printer,
  });

  static final Logger _log = appLogger('host.impresion');

  /// Trabajos fallidos que se recuerdan para [reintentar]; los más antiguos
  /// se olvidan (la cola tampoco guarda más de 100 terminados).
  static const int maxFallidos = 100;

  final AlertBus _alerts;

  /// Ejecutor de los generadores: quien llama a [enviar] lo usa en
  /// `generar` (`generarXxxEnIsolate(datos, runner: canal.runner)`).
  final IsolateRunner runner;

  final ImpresionSettings Function() _settings;
  final PrinterPort? Function() _printer;
  final Set<Future<void>> _seguimientos = {};

  /// Trabajos fallidos que se pueden reintentar, del más antiguo al más
  /// nuevo, con la cola que los tiene (puede haber cambiado en caliente).
  final Map<String, _TrabajoFallido> _fallidos = {};

  /// Seguimientos en curso de cada trabajo (normalmente uno).
  final Map<String, int> _siguiendo = {};

  /// Impresoras (`claveImpresora`) cuyo zumbador del conector del cajón ya
  /// se registró como anulado en esta sesión.
  final Set<String> _cajonAnulado = {};

  /// Genera el documento con el perfil de [endpoint] y lo encola.
  ///
  /// Con [preparacion], concatena `perfil.copias` copias (o [copias], que
  /// manda: la reimpresión fuerza 1) en un solo trabajo y añade el aviso
  /// sonoro del perfil una vez al final; sin él, [copias] no cuenta. Devuelve
  /// el id del trabajo, o `null` si no se encoló (sin cola de impresión, o
  /// una [AppException] convertida en aviso); sin [lanzarErrores], un error
  /// no tipado se relanza tal cual. Con [lanzarErrores] relanza la
  /// [AppException] de generar o encolar (o una [PrinterException] si no hay
  /// cola o el error no era tipado). [reintento] llega al puerto: las
  /// facturas usan [PrintRetryPolicy.connectOnly].
  ///
  /// [perfil] sustituye al de los ajustes para [endpoint] en todo (lo que
  /// recibe `generar`, las copias y el aviso): las muestras se imprimen con el
  /// del borrador de la página «Tickets y comandas», ya resuelto
  /// (`borrador.perfilPara(endpoint)`).
  ///
  /// Lanza [ArgumentError] si [copias] es menor que 1.
  Future<String?> enviar(
    PrinterEndpoint endpoint,
    String descripcion,
    Future<Uint8List> Function(PerfilImpresora perfil) generar, {
    bool preparacion = false,
    int? copias,
    bool lanzarErrores = false,
    PrintRetryPolicy reintento = PrintRetryPolicy.always,
    PerfilImpresora? perfil,
  }) async {
    if (copias != null && copias < 1) {
      throw ArgumentError.value(copias, 'copias', 'debe ser al menos 1');
    }
    final printer = _printer();
    if (printer == null) {
      return _sinCola(descripcion, lanzarErrores: lanzarErrores);
    }
    final ajustes = _settings();
    final efectivo = perfil ?? ajustes.perfilPara(endpoint);
    final Uint8List bytes;
    try {
      final documento = await generar(efectivo);
      bytes = preparacion
          ? _conCopiasYAviso(documento, efectivo, copias ?? efectivo.copias)
          : documento;
    } on Object catch (error, stackTrace) {
      return _fallo(
        'generar',
        descripcion,
        error,
        stackTrace,
        lanzarErrores: lanzarErrores,
      );
    }
    if (preparacion && perfil == null) {
      _registrarCajonAnulado(endpoint, efectivo, ajustes);
    }
    return _encolar(
      printer,
      endpoint,
      descripcion,
      bytes,
      reintento: reintento,
      lanzarErrores: lanzarErrores,
    );
  }

  /// Encola [bytes] tal cual (el trabajo propio del cajón,
  /// `bytesAbrirCajon()`), sin perfil, copias ni aviso, con
  /// [PrintRetryPolicy.always]. Devuelve el id del trabajo o `null`; los
  /// errores, como en [enviar].
  Future<String?> enviarCrudo(
    PrinterEndpoint endpoint,
    String descripcion,
    Uint8List bytes, {
    bool lanzarErrores = false,
  }) async {
    final printer = _printer();
    if (printer == null) {
      return _sinCola(descripcion, lanzarErrores: lanzarErrores);
    }
    return _encolar(
      printer,
      endpoint,
      descripcion,
      bytes,
      reintento: PrintRetryPolicy.always,
      lanzarErrores: lanzarErrores,
    );
  }

  /// Completa cuando no queda ningún trabajo en seguimiento (tests y
  /// cierre).
  Future<void> idle() async {
    while (_seguimientos.isNotEmpty) {
      await Future.wait(_seguimientos.toList());
    }
  }

  /// El trabajo falló en la impresora (no se canceló) y el canal lo recuerda.
  bool fallido(String jobId) => _fallidos.containsKey(jobId);

  /// El trabajo sigue en la cola o falló y el canal lo recuerda: aún puede
  /// imprimirse o reintentarse.
  bool pendiente(String jobId) =>
      _siguiendo.containsKey(jobId) || _fallidos.containsKey(jobId);

  /// [reintentar] reencolaría ahora mismo el trabajo [jobId]: está
  /// [fallido] y, si es [PrintRetryPolicy.connectOnly] (una factura), ningún
  /// intento llegó a enviar nada.
  bool puedeReintentar(String jobId) {
    final trabajo = _fallidos[jobId];
    if (trabajo == null) return false;
    if (trabajo.reintento != PrintRetryPolicy.connectOnly) return true;
    try {
      return trabajo.printer.nadaEnviado(jobId);
    } on PrinterException {
      return false;
    }
  }

  /// Reencola el trabajo fallido [jobId] con sus mismos bytes en la cola que
  /// lo tiene y lo vuelve a seguir: si falla otra vez, nuevo aviso. Devuelve
  /// su id (el mismo).
  ///
  /// Falla cerrado con las facturas: un trabajo [PrintRetryPolicy.connectOnly]
  /// solo se reencola si ningún intento envió nada, la misma regla que
  /// aplica la cola dentro de cada ciclo; si no, su siguiente impresión es un
  /// DUPLICADO, que decide `TicketsImpresion`.
  ///
  /// Lanza [PrinterException] si el canal no lo tiene por fallido (no falló,
  /// se canceló, ya se reintentó o se descartó), si es una factura que pudo
  /// enviar bytes o si la cola lo rechaza (ya salió del historial, cola
  /// cerrada o llena); en esos dos últimos casos sigue fallido.
  String reintentar(String jobId) {
    final trabajo = _fallidoOLanza(jobId);
    if (trabajo.reintento == PrintRetryPolicy.connectOnly &&
        !trabajo.printer.nadaEnviado(jobId)) {
      throw PrinterException(
        'No se reenvía "${trabajo.descripcion}": pudo salir parte del '
        'documento, así que se imprime de nuevo como DUPLICADO',
      );
    }
    final id = trabajo.printer.reintentar(jobId);
    _fallidos.remove(jobId);
    _log.fine('Reintento de "${trabajo.descripcion}" → ${trabajo.endpoint}');
    _seguir(
      trabajo.printer,
      trabajo.endpoint,
      trabajo.descripcion,
      id,
      reintento: trabajo.reintento,
    );
    return id;
  }

  /// `true` si ningún intento del trabajo fallido [jobId] llegó a enviar
  /// nada. Lanza [PrinterException] como [reintentar].
  bool nadaEnviado(String jobId) =>
      _fallidoOLanza(jobId).printer.nadaEnviado(jobId);

  /// Deja de ofrecer el reintento de [jobId] (lo sustituyó otro trabajo,
  /// como el DUPLICADO de una factura). No hace nada si no estaba fallido.
  void descartar(String jobId) => _fallidos.remove(jobId);

  _TrabajoFallido _fallidoOLanza(String jobId) =>
      _fallidos[jobId] ??
      (throw PrinterException(
        'No se puede reintentar el trabajo de impresión $jobId: no está '
        'fallido o ya se reintentó',
      ));

  /// [copias] veces el documento y, una sola vez al final, el aviso sonoro
  /// del perfil (vacío con `ninguno`).
  Uint8List _conCopiasYAviso(
    Uint8List documento,
    PerfilImpresora perfil,
    int copias,
  ) {
    final aviso = bytesAviso(
      perfil.zumbador,
      pitidos: perfil.pitidos,
      pin: perfil.pinZumbador,
    );
    final trabajo = BytesBuilder(copy: false);
    for (var i = 0; i < copias; i++) {
      trabajo.add(documento);
    }
    trabajo.add(aviso);
    return trabajo.toBytes();
  }

  /// Registra (`fine`, una vez por impresora y sesión) que el perfil guardado
  /// tenía el zumbador en el conector del cajón y el resolutor lo anuló
  /// porque [endpoint] sirve a los tickets.
  void _registrarCajonAnulado(
    PrinterEndpoint endpoint,
    PerfilImpresora resuelto,
    ImpresionSettings ajustes,
  ) {
    if (resuelto.zumbador != ZumbadorModo.ninguno) return;
    final direcciones = {
      RolImpresora.tickets: ajustes.tickets,
      RolImpresora.cocina: ajustes.cocina,
      RolImpresora.barra: ajustes.barra,
    };
    final anulado = rolesDe(endpoint, direcciones).any((rol) {
      final guardado = ajustes.formato.perfiles[rol];
      return guardado != null &&
          guardado.zumbador == ZumbadorModo.puertoCajon &&
          guardado.copyWith(zumbador: ZumbadorModo.ninguno) == resuelto;
    });
    if (!anulado || !_cajonAnulado.add(claveImpresora(endpoint))) return;
    _log.fine(
      'Impresora $endpoint: el aviso por el conector del cajón no suena en '
      'la impresora que sirve a los tickets (abriría el cajón)',
    );
  }

  String? _encolar(
    PrinterPort printer,
    PrinterEndpoint endpoint,
    String descripcion,
    Uint8List bytes, {
    required PrintRetryPolicy reintento,
    required bool lanzarErrores,
  }) {
    final String jobId;
    try {
      jobId = printer.imprimir(
        endpoint,
        bytes,
        description: descripcion,
        reintento: reintento,
      );
    } on Object catch (error, stackTrace) {
      return _fallo(
        'encolar',
        descripcion,
        error,
        stackTrace,
        lanzarErrores: lanzarErrores,
      );
    }
    _log.fine('Encolado "$descripcion" → $endpoint ($jobId)');
    _seguir(printer, endpoint, descripcion, jobId, reintento: reintento);
    return jobId;
  }

  /// Sigue el trabajo hasta que termina: si falla en la impresora, aviso
  /// «Fallo de impresión» con la dirección y el motivo y, si la cola admite
  /// reintentos y no se canceló, lo recuerda para [reintentar] y pone su id
  /// en el aviso.
  void _seguir(
    PrinterPort printer,
    PrinterEndpoint endpoint,
    String descripcion,
    String jobId, {
    required PrintRetryPolicy reintento,
  }) {
    _siguiendo.update(jobId, (n) => n + 1, ifAbsent: () => 1);
    late final Future<void> seguimiento;
    seguimiento = printer
        .terminado(jobId)
        .then((error) {
          if (error == null) return;
          final reintentable =
              printer is RetryablePrinterPort && error != trabajoCancelado
              ? printer
              : null;
          if (reintentable != null) {
            _recordarFallido(jobId, (
              printer: reintentable,
              endpoint: endpoint,
              descripcion: descripcion,
              reintento: reintento,
            ));
          }
          _alerts.error(
            'Fallo de impresión: $descripcion',
            detalle: '$endpoint: $error',
            origen: 'impresion',
            trabajoImpresion: reintentable == null ? null : jobId,
          );
        })
        .catchError((Object error) {
          _log.warning('Seguimiento de "$descripcion" falló', error);
        })
        .whenComplete(() {
          _seguimientos.remove(seguimiento);
          final n = _siguiendo[jobId] ?? 1;
          if (n <= 1) {
            _siguiendo.remove(jobId);
          } else {
            _siguiendo[jobId] = n - 1;
          }
        });
    _seguimientos.add(seguimiento);
  }

  void _recordarFallido(String jobId, _TrabajoFallido trabajo) {
    _fallidos.remove(jobId);
    _fallidos[jobId] = trabajo;
    if (_fallidos.length > maxFallidos) {
      _fallidos.remove(_fallidos.keys.first);
    }
  }

  /// Un fallo al [accion] (`generar` o `encolar`). Una [AppException] se
  /// relanza con [lanzarErrores] y, sin él, se convierte en aviso operativo
  /// y `null` (como hoy). Un error no tipado se relanza tal cual sin
  /// [lanzarErrores] (también como hoy: lo registra y avisa el aislamiento de
  /// quien llama) y, con él, se traduce a [PrinterException] con la causa.
  String? _fallo(
    String accion,
    String descripcion,
    Object error,
    StackTrace stackTrace, {
    required bool lanzarErrores,
  }) {
    final titulo = 'No se pudo $accion "$descripcion"';
    if (error is AppException) {
      if (lanzarErrores) Error.throwWithStackTrace(error, stackTrace);
      _alerts.error(titulo, detalle: error.message, origen: 'impresion');
      return null;
    }
    if (!lanzarErrores) Error.throwWithStackTrace(error, stackTrace);
    _log.warning('$titulo: error inesperado', error, stackTrace);
    throw PrinterException(titulo, cause: error);
  }

  /// Sin cola de impresión: no hay por dónde imprimir.
  String? _sinCola(String descripcion, {required bool lanzarErrores}) {
    if (lanzarErrores) {
      throw PrinterException(
        'La impresión no está disponible: no se puede imprimir '
        '"$descripcion"',
      );
    }
    _log.fine('Sin cola de impresión: no se imprime "$descripcion"');
    return null;
  }
}

/// Un trabajo fallido que se puede reintentar: la cola que lo tiene, lo
/// necesario para volver a avisar si falla otra vez y su política (con
/// [PrintRetryPolicy.connectOnly], una factura).
typedef _TrabajoFallido = ({
  RetryablePrinterPort printer,
  PrinterEndpoint endpoint,
  String descripcion,
  PrintRetryPolicy reintento,
});
