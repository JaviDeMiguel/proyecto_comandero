import 'package:equatable/equatable.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/money/money.dart';
import '../../../core/utils/json_map.dart';
import '../../../core/utils/json_tolerante.dart';
import 'linea_comanda.dart';
import 'precuenta_emitida.dart';

/// Forma de cobro de un ticket. Un ticket se cobra con una forma de pago o
/// con las dos a la vez (cobro mixto: parte en efectivo y parte con tarjeta,
/// un recibo por forma de pago en FacturaScripts).
enum MetodoPago {
  efectivo,
  tarjeta;

  static MetodoPago parse(String value) => MetodoPago.values.firstWhere(
    (metodo) => metodo.name == value,
    orElse: () => throw FormatException("Método de pago desconocido '$value'"),
  );
}

/// Una parte del cobro de un ticket: cuánto se cobró con cada forma de pago.
final class PagoTicket extends Equatable {
  const PagoTicket({required this.metodo, required this.importeCents});

  factory PagoTicket.fromJson(Map<String, Object?> json) => PagoTicket(
    metodo: MetodoPago.parse(json.requireString('metodo')),
    importeCents: json.requireInt('importeCents'),
  );

  final MetodoPago metodo;
  final int importeCents;

  /// Forma de pago principal de un cobro: la de mayor importe y, en empate,
  /// el efectivo. Es la que se guarda en [Ticket.metodoPago].
  static MetodoPago metodoPrincipal(List<PagoTicket> pagos) {
    if (pagos.isEmpty) {
      throw const ValidationException('El cobro no tiene ningún pago');
    }
    var principal = pagos.first;
    for (final pago in pagos.skip(1)) {
      final mayor = pago.importeCents > principal.importeCents;
      final empateEfectivo =
          pago.importeCents == principal.importeCents &&
          pago.metodo == MetodoPago.efectivo;
      if (mayor || empateEfectivo) principal = pago;
    }
    return principal.metodo;
  }

  Map<String, Object?> toJson() => {
    'metodo': metodo.name,
    'importeCents': importeCents,
  };

  @override
  List<Object?> get props => [metodo, importeCents];
}

/// Base y cuota de un tipo de IVA dentro de un ticket.
final class DesgloseIva extends Equatable {
  const DesgloseIva({
    this.codimpuesto,
    required this.ivaBp,
    required this.baseCents,
    required this.cuotaCents,
  });

  factory DesgloseIva.fromJson(Map<String, Object?> json) => DesgloseIva(
    codimpuesto: json.optionalString('codimpuesto'),
    ivaBp: json.requireInt('ivaBp'),
    baseCents: json.requireInt('baseCents'),
    cuotaCents: json.requireInt('cuotaCents'),
  );

  final String? codimpuesto;
  final int ivaBp;
  final int baseCents;
  final int cuotaCents;

  int get totalCents => baseCents + cuotaCents;

  Map<String, Object?> toJson() => {
    if (codimpuesto != null) 'codimpuesto': codimpuesto,
    'ivaBp': ivaBp,
    'baseCents': baseCents,
    'cuotaCents': cuotaCents,
  };

  @override
  List<Object?> get props => [codimpuesto, ivaBp, baseCents, cuotaCents];
}

/// Totales legales del ticket, calculados con la réplica del `Calculator`
/// de FacturaScripts (redondeo por tipo de IVA).
final class TotalesTicket extends Equatable {
  TotalesTicket({
    required this.netoCents,
    required this.ivaCents,
    required this.totalCents,
    List<DesgloseIva> desglose = const [],
  }) : desglose = List.unmodifiable(desglose);

  factory TotalesTicket.fromJson(Map<String, Object?> json) => TotalesTicket(
    netoCents: json.requireInt('netoCents'),
    ivaCents: json.requireInt('ivaCents'),
    totalCents: json.requireInt('totalCents'),
    desglose: [
      for (final item in json.requireMapList('desglose'))
        DesgloseIva.fromJson(item),
    ],
  );

  final int netoCents;
  final int ivaCents;
  final int totalCents;
  final List<DesgloseIva> desglose;

  Map<String, Object?> toJson() => {
    'netoCents': netoCents,
    'ivaCents': ivaCents,
    'totalCents': totalCents,
    'desglose': [for (final item in desglose) item.toJson()],
  };

  @override
  List<Object?> get props => [netoCents, ivaCents, totalCents, desglose];
}

/// Estado de la factura del ticket en el ERP.
enum EstadoSincronizacion {
  /// En la cola de sincronización, todavía no enviado o reintentando.
  pendiente,

  /// Factura creada en FacturaScripts.
  sincronizado,

  /// Rechazado definitivamente por el ERP (422/400): requiere intervención.
  error;

  static EstadoSincronizacion parse(String value) =>
      EstadoSincronizacion.values.firstWhere(
        (estado) => estado.name == value,
        orElse: () =>
            throw FormatException("Estado de sincronización '$value'"),
      );
}

/// Datos de la factura simplificada creada en FacturaScripts.
///
/// [fecha] y [totalFsCents] son posteriores a la primera versión del diario:
/// se leen de forma tolerante y solo se escriben si no son nulos.
final class FacturaSincronizada extends Equatable {
  FacturaSincronizada({
    required this.estado,
    this.idfactura,
    this.codigo,
    this.numero,
    this.idasiento,
    this.pagada = false,
    this.emitida = false,
    List<String> avisos = const [],
    this.error,
    this.actualizadoEn,
    this.fecha,
    this.totalFsCents,
  }) : avisos = List.unmodifiable(avisos);

  factory FacturaSincronizada.fromJson(Map<String, Object?> json) =>
      FacturaSincronizada(
        estado: EstadoSincronizacion.parse(json.requireString('estado')),
        idfactura: json.optionalInt('idfactura'),
        codigo: json.optionalString('codigo'),
        numero: json.optionalInt('numero'),
        idasiento: json.optionalInt('idasiento'),
        pagada: json.optionalBool('pagada') ?? false,
        emitida: json.optionalBool('emitida') ?? false,
        avisos: [
          for (final aviso in json.optionalList('avisos') ?? const [])
            aviso.toString(),
        ],
        error: json.optionalString('error'),
        actualizadoEn: switch (json.optionalString('actualizadoEn')) {
          final String text => DateTime.parse(text),
          null => null,
        },
        // Un valor ausente o ilegible se lee como «FS no lo devolvió»: sin
        // alguno de los dos, la factura no se imprime, pero el ticket vale.
        fecha: fechaTolerante(json['fecha']),
        totalFsCents: enteroTolerante(json['totalFsCents']),
      );

  final EstadoSincronizacion estado;
  final int? idfactura;

  /// Código legal asignado por FacturaScripts (`F2026S12`).
  final String? codigo;
  final int? numero;
  final int? idasiento;
  final bool pagada;
  final bool emitida;
  final List<String> avisos;
  final String? error;
  final DateTime? actualizadoEn;

  /// Fecha **y** hora de expedición en FacturaScripts (`fecha` + `hora` del
  /// documento): la que se imprime y la del QR. `null` si FS no la devolvió
  /// ni al releer (factura sincronizada con una versión anterior).
  final DateTime? fecha;

  /// Total de la factura **en FacturaScripts**: el importe impreso y el del
  /// QR. `null` si FS no lo devolvió ni al releer; nunca se rellena con el
  /// total del TPV (un total de 0 € es válido).
  final int? totalFsCents;

  Map<String, Object?> toJson() => {
    'estado': estado.name,
    if (idfactura != null) 'idfactura': idfactura,
    if (codigo != null) 'codigo': codigo,
    if (numero != null) 'numero': numero,
    if (idasiento != null) 'idasiento': idasiento,
    'pagada': pagada,
    'emitida': emitida,
    'avisos': avisos,
    if (error != null) 'error': error,
    if (actualizadoEn != null)
      'actualizadoEn': actualizadoEn!.toIso8601String(),
    if (fecha != null) 'fecha': fecha!.toIso8601String(),
    if (totalFsCents != null) 'totalFsCents': totalFsCents,
  };

  @override
  List<Object?> get props => [
    estado,
    idfactura,
    codigo,
    numero,
    idasiento,
    pagada,
    emitida,
    avisos,
    error,
    actualizadoEn,
    fecha,
    totalFsCents,
  ];
}

/// Datos del QR tributario con los que salió el ORIGINAL de la factura. Los
/// DUPLICADOS los reutilizan tal cual aunque después cambien los ajustes del
/// QR o el NIF del emisor en caché: toda impresión de una factura lleva el
/// mismo QR que su original. Guarda cadenas, no el `QrTributario` de
/// `lib/core/fiscal`.
final class QrImpreso extends Equatable {
  const QrImpreso({
    required this.url,
    this.leyenda,
    required this.modo,
    required this.entorno,
    required this.nif,
  });

  /// Lectura estricta ([FormatException]); `ImpresionTicket.fromJson` la
  /// envuelve y deja el QR a `null` si es ilegible.
  factory QrImpreso.fromJson(Map<String, Object?> json) => QrImpreso(
    url: json.requireString('url'),
    leyenda: json.optionalString('leyenda'),
    modo: json.requireString('modo'),
    entorno: json.requireString('entorno'),
    nif: json.requireString('nif'),
  );

  /// URL completa codificada en el QR.
  final String url;

  /// Leyenda impresa junto al QR (`VERI*FACTU`), o `null` si no lleva
  /// (modo NO VERI*FACTU).
  final String? leyenda;

  /// `verifactu` | `noVerifactu` (`ModoQrVerifactu.name`).
  final String modo;

  /// `produccion` | `pruebas` (`EntornoVerifactu.name`).
  final String entorno;

  /// NIF del emisor normalizado, tal como va en la URL.
  final String nif;

  /// [leyenda] solo si no es nula.
  Map<String, Object?> toJson() => {
    'url': url,
    if (leyenda != null) 'leyenda': leyenda,
    'modo': modo,
    'entorno': entorno,
    'nif': nif,
  };

  @override
  List<Object?> get props => [url, leyenda, modo, entorno, nif];
}

/// Estado de impresión del ticket (art. 14 del reglamento de facturación: un
/// solo ORIGINAL de la factura y DUPLICADOS marcados como tales).
///
/// Solo se escribe en el JSON del ticket cuando no está [vacia], y cada campo
/// solo cuando no tiene su valor por defecto.
final class ImpresionTicket extends Equatable {
  const ImpresionTicket({
    this.provisionalEn,
    this.copiasProvisional = 0,
    this.facturaOriginalEn,
    this.qr,
    this.duplicados = 0,
  });

  /// Lectura tolerante: un campo ausente o ilegible toma su valor por
  /// defecto y un [qr] ilegible se lee como `null`, sin invalidar el ticket.
  factory ImpresionTicket.fromJson(Map<String, Object?> json) =>
      ImpresionTicket(
        provisionalEn: fechaTolerante(json['provisionalEn']),
        copiasProvisional:
            enteroPositivoTolerante(json['copiasProvisional']) ?? 0,
        facturaOriginalEn: fechaTolerante(json['facturaOriginalEn']),
        qr: _qrTolerante(json['qr']),
        duplicados: enteroPositivoTolerante(json['duplicados']) ?? 0,
      );

  /// Ticket sin ninguna impresión registrada.
  static const ImpresionTicket vacia = ImpresionTicket();

  /// Primera impresión del documento provisional al cobrar.
  final DateTime? provisionalEn;

  /// Reimpresiones «COPIA» del provisional.
  final int copiasProvisional;

  /// Momento en que se encoló el ORIGINAL de la factura simplificada.
  final DateTime? facturaOriginalEn;

  /// QR con el que salió el ORIGINAL; `null` si salió sin QR (modo
  /// desactivado) o si aún no se ha impreso.
  final QrImpreso? qr;

  /// DUPLICADOS encolados.
  final int duplicados;

  /// Todos los campos tienen su valor por defecto.
  bool get estaVacia => this == vacia;

  bool get originalImpreso => facturaOriginalEn != null;

  /// La primera vez fija [provisionalEn]; después cuenta una copia más.
  ImpresionTicket conProvisional(DateTime cuando) => ImpresionTicket(
    provisionalEn: provisionalEn ?? cuando,
    copiasProvisional: provisionalEn == null
        ? copiasProvisional
        : copiasProvisional + 1,
    facturaOriginalEn: facturaOriginalEn,
    qr: qr,
    duplicados: duplicados,
  );

  /// Marca el ORIGINAL y guarda el [qr] con el que sale (`null` si sale sin
  /// QR).
  ImpresionTicket conFacturaOriginal(DateTime cuando, {QrImpreso? qr}) =>
      ImpresionTicket(
        provisionalEn: provisionalEn,
        copiasProvisional: copiasProvisional,
        facturaOriginalEn: cuando,
        qr: qr,
        duplicados: duplicados,
      );

  /// Cuenta un DUPLICADO más.
  ImpresionTicket conDuplicado() => ImpresionTicket(
    provisionalEn: provisionalEn,
    copiasProvisional: copiasProvisional,
    facturaOriginalEn: facturaOriginalEn,
    qr: qr,
    duplicados: duplicados + 1,
  );

  /// Solo los campos que no tienen su valor por defecto.
  Map<String, Object?> toJson() => {
    if (provisionalEn != null)
      'provisionalEn': provisionalEn!.toIso8601String(),
    if (copiasProvisional != 0) 'copiasProvisional': copiasProvisional,
    if (facturaOriginalEn != null)
      'facturaOriginalEn': facturaOriginalEn!.toIso8601String(),
    if (qr != null) 'qr': qr!.toJson(),
    if (duplicados != 0) 'duplicados': duplicados,
  };

  static QrImpreso? _qrTolerante(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    try {
      return QrImpreso.fromJson(raw);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  @override
  List<Object?> get props => [
    provisionalEn,
    copiasProvisional,
    facturaOriginalEn,
    qr,
    duplicados,
  ];
}

/// Ticket cobrado: la foto inmutable de una comanda en el momento del cobro.
///
/// [id] es la clave idempotente del ticket en todo el sistema: diario local,
/// cola de sincronización y `numero2` de la factura en FacturaScripts.
///
/// El cobro puede ser mixto ([pagos] con efectivo y tarjeta). El reparto se
/// guarda en el diario del host antes de facturar porque FacturaScripts no
/// puede reconstruirlo.
///
/// [precuentas] e [impresion] son posteriores a la primera versión del
/// diario: se leen de forma tolerante y solo se escriben si no están vacías.
final class Ticket extends Equatable {
  /// [pagos] es opcional: sin él, el ticket se cobra entero con [metodoPago]
  /// (el comportamiento de siempre). Con él, [metodoPago] debe ser la forma
  /// de pago principal ([PagoTicket.metodoPrincipal]). Lanza
  /// [ValidationException] si el reparto no es coherente.
  Ticket({
    required this.id,
    required this.numeroLocal,
    required this.mesaId,
    required this.nombreMesa,
    required this.comandaId,
    required this.fechaHora,
    required List<LineaComanda> lineas,
    required this.totales,
    required this.metodoPago,
    List<PagoTicket>? pagos,
    this.entregadoCents,
    this.camarero,
    this.comensales,
    this.factura,
    List<PrecuentaEmitida> precuentas = const [],
    this.impresion = ImpresionTicket.vacia,
  }) : lineas = List.unmodifiable(lineas),
       pagos = List<PagoTicket>.unmodifiable(
         pagos ??
             [PagoTicket(metodo: metodoPago, importeCents: totales.totalCents)],
       ),
       precuentas = List.unmodifiable(precuentas) {
    _validarPagos();
  }

  /// Lee también los diarios antiguos (sin `pagos`: un único pago del
  /// total). Un reparto incoherente se informa como [FormatException], igual
  /// que cualquier otro dato corrupto del diario.
  factory Ticket.fromJson(Map<String, Object?> json) {
    final pagos = json.optionalList('pagos');
    try {
      return Ticket(
        id: json.requireString('id'),
        numeroLocal: json.requireInt('numeroLocal'),
        mesaId: json.requireString('mesaId'),
        nombreMesa: json.requireString('nombreMesa'),
        comandaId: json.requireString('comandaId'),
        fechaHora: DateTime.parse(json.requireString('fechaHora')),
        lineas: [
          for (final linea in json.requireMapList('lineas'))
            LineaComanda.fromJson(linea),
        ],
        totales: TotalesTicket.fromJson(json.requireMap('totales')),
        metodoPago: MetodoPago.parse(json.requireString('metodoPago')),
        pagos: pagos == null || pagos.isEmpty
            ? null
            : [
                for (final pago in json.requireMapList('pagos'))
                  PagoTicket.fromJson(pago),
              ],
        entregadoCents: json.optionalInt('entregadoCents'),
        camarero: json.optionalString('camarero'),
        comensales: json.optionalInt('comensales'),
        factura: switch (json.optionalMap('factura')) {
          final Map<String, Object?> map => FacturaSincronizada.fromJson(map),
          null => null,
        },
        // Una precuenta ilegible se descarta y una impresión ilegible se lee
        // vacía: nunca invalidan el ticket.
        precuentas: listaTolerante(
          json['precuentas'],
          PrecuentaEmitida.fromJson,
        ),
        impresion: switch (json['impresion']) {
          final Map<String, Object?> map => ImpresionTicket.fromJson(map),
          _ => ImpresionTicket.vacia,
        },
      );
    } on ValidationException catch (error) {
      throw FormatException('Ticket corrupto: ${error.message}');
    }
  }

  final String id;

  /// Numeración correlativa local del dispositivo (la legal la pone el ERP).
  final int numeroLocal;
  final String mesaId;
  final String nombreMesa;
  final String comandaId;
  final DateTime fechaHora;

  /// Solo las líneas activas en el momento del cobro.
  final List<LineaComanda> lineas;
  final TotalesTicket totales;

  /// Forma de pago principal: la única en un cobro simple; en un cobro mixto,
  /// la de mayor importe (en empate, el efectivo).
  final MetodoPago metodoPago;

  /// Reparto del cobro: uno o dos pagos con formas distintas que suman el
  /// total. En un cobro mixto cada importe es positivo; un pago único lleva
  /// el total, sea cual sea (también cero).
  final List<PagoTicket> pagos;

  /// Efectivo entregado por el cliente para la parte en efectivo.
  final int? entregadoCents;
  final String? camarero;
  final int? comensales;
  final FacturaSincronizada? factura;

  /// Precuentas emitidas a la mesa antes de cobrar (las de la comanda): van
  /// a las observaciones de la factura y al detalle del ticket.
  final List<PrecuentaEmitida> precuentas;

  /// Estado de impresión: provisional, ORIGINAL de la factura y duplicados.
  final ImpresionTicket impresion;

  int get totalCents => totales.totalCents;

  /// El cobro combina efectivo y tarjeta.
  bool get esMixto => pagos.length > 1;

  /// Parte cobrada en efectivo (la que entra en caja).
  int get efectivoCents => _importeDe(MetodoPago.efectivo);

  /// Parte cobrada con tarjeta.
  int get tarjetaCents => _importeDe(MetodoPago.tarjeta);

  /// Cambio a devolver (`0` si no procede). El entregado se refiere solo a
  /// la parte en efectivo.
  int get cambioCents {
    final entregado = entregadoCents;
    if (entregado == null) return 0;
    final cambio = entregado - efectivoCents;
    return cambio > 0 ? cambio : 0;
  }

  int _importeDe(MetodoPago metodo) => pagos
      .where((pago) => pago.metodo == metodo)
      .fold(0, (sum, pago) => sum + pago.importeCents);

  void _validarPagos() {
    if (pagos.isEmpty || pagos.length > MetodoPago.values.length) {
      throw ValidationException(
        'El ticket $id debe cobrarse con uno o dos pagos '
        '(tiene ${pagos.length})',
      );
    }
    if (pagos.map((pago) => pago.metodo).toSet().length != pagos.length) {
      throw ValidationException(
        'El ticket $id repite forma de pago en el cobro',
      );
    }
    final suma = pagos.fold(0, (sum, pago) => sum + pago.importeCents);
    if (suma != totalCents) {
      throw ValidationException(
        'Los pagos del ticket $id suman ${formatCents(suma)} y el total es '
        '${formatCents(totalCents)}',
      );
    }
    if (pagos.length > 1) {
      for (final pago in pagos) {
        if (pago.importeCents <= 0) {
          throw ValidationException(
            'Cobro mixto del ticket $id con un importe no positivo '
            '(${pago.metodo.name}: ${formatCents(pago.importeCents)})',
          );
        }
      }
    }
    final principal = PagoTicket.metodoPrincipal(pagos);
    if (metodoPago != principal) {
      throw ValidationException(
        'La forma de pago principal del ticket $id es ${principal.name}, '
        'no ${metodoPago.name}',
      );
    }
  }

  /// Clave idempotente para `numero2` de la factura (máximo 50 caracteres y
  /// nunca con forma de fecha, que FacturaScripts reescribiría).
  String get claveFactura => 'TPV-$id';

  /// Copia con otra [factura] u otra [impresion]; conserva todo lo demás.
  Ticket copyWith({FacturaSincronizada? factura, ImpresionTicket? impresion}) =>
      Ticket(
        id: id,
        numeroLocal: numeroLocal,
        mesaId: mesaId,
        nombreMesa: nombreMesa,
        comandaId: comandaId,
        fechaHora: fechaHora,
        lineas: lineas,
        totales: totales,
        metodoPago: metodoPago,
        pagos: pagos,
        entregadoCents: entregadoCents,
        camarero: camarero,
        comensales: comensales,
        factura: factura ?? this.factura,
        precuentas: precuentas,
        impresion: impresion ?? this.impresion,
      );

  /// Conserva [impresion] y [precuentas].
  Ticket conFactura(FacturaSincronizada factura) => copyWith(factura: factura);

  Map<String, Object?> toJson() => {
    'id': id,
    'numeroLocal': numeroLocal,
    'mesaId': mesaId,
    'nombreMesa': nombreMesa,
    'comandaId': comandaId,
    'fechaHora': fechaHora.toIso8601String(),
    'lineas': [for (final linea in lineas) linea.toJson()],
    'totales': totales.toJson(),
    'metodoPago': metodoPago.name,
    // Solo el cobro mixto escribe el reparto: el JSON de un pago único queda
    // igual que siempre.
    if (esMixto) 'pagos': [for (final pago in pagos) pago.toJson()],
    if (entregadoCents != null) 'entregadoCents': entregadoCents,
    if (camarero != null) 'camarero': camarero,
    if (comensales != null) 'comensales': comensales,
    if (precuentas.isNotEmpty)
      'precuentas': [for (final precuenta in precuentas) precuenta.toJson()],
    if (!impresion.estaVacia) 'impresion': impresion.toJson(),
    if (factura != null) 'factura': factura!.toJson(),
  };

  @override
  List<Object?> get props => [
    id,
    numeroLocal,
    mesaId,
    nombreMesa,
    comandaId,
    fechaHora,
    lineas,
    totales,
    metodoPago,
    pagos,
    entregadoCents,
    camarero,
    comensales,
    factura,
    precuentas,
    impresion,
  ];
}
