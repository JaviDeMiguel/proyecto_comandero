/// Mensajes de aplicación entre el comandero y el host, transportados por la
/// capa TCP (`lib/core/network/tcp`) como `type` + `payload`.
///
/// Las peticiones (comandero → host) se responden con `ack` cuyo payload es
/// el resultado indicado; los eventos (host → comandero) no tienen respuesta.
library;

import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';
import '../domain/comanda.dart';
import '../domain/enrutamiento_comandas.dart';
import '../domain/linea_comanda.dart';
import '../domain/mesa.dart';
import '../domain/pases.dart';

abstract final class SalaMessageTypes {
  /// Petición: estado completo de la sala. Respuesta: [SalaSnapshot].
  /// El comandero la envía tras cada (re)conexión.
  static const String salaSnapshotGet = 'sala.snapshot.get';

  /// Petición: catálogo vigente. Respuesta: `CatalogSnapshot.toJson()`.
  static const String catalogoGet = 'catalogo.get';

  /// Petición fiable: líneas nuevas para una mesa ([ComandaSubmitPayload]).
  /// Respuesta: [ComandaSubmitResult]. Idempotente por id de línea.
  static const String comandaSubmit = 'comanda.submit';

  /// Petición fiable: anular una línea ([LineaAnularPayload]).
  /// Respuesta: [ComandaResult].
  static const String lineaAnular = 'comanda.linea.anular';

  /// Petición: marcar/desmarcar "cuenta solicitada" ([MesaCuentaPayload]).
  /// Respuesta: [ComandaResult].
  static const String mesaCuenta = 'mesa.cuenta';

  /// Petición fiable: marchar un pase de la comanda de una mesa
  /// ([MarcharPasePayload]). Respuesta: [ComandaResult] con la comanda y sus
  /// marchas actualizadas. Idempotente por `marchaId`. Un host de una
  /// versión anterior responde `error unknown_type` (no reintentable).
  static const String paseMarchar = 'comanda.pase.marchar';

  /// Evento: la comanda de una mesa cambió ([SalaChangedEvent]).
  static const String salaChanged = 'sala.changed';

  /// Evento: hay un catálogo nuevo ([CatalogoChangedEvent]).
  static const String catalogoChanged = 'catalogo.changed';

  /// Evento sin payload (`{}`): cambió la configuración de sala publicada en
  /// el snapshot (las reglas de enrutamiento familia → cocina/barra o la
  /// configuración de pases). El comandero vuelve a pedir el snapshot de
  /// sala para tener la configuración nueva. Un comandero antiguo lo ignora
  /// (tipo desconocido) y lo recibe al reconectar.
  static const String enrutamientoChanged = 'enrutamiento.changed';
}

/// Códigos de error de aplicación devueltos en `error.code`.
abstract final class SalaErrorCodes {
  static const String mesaDesconocida = 'mesa_desconocida';
  static const String mesaSinComanda = 'mesa_sin_comanda';
  static const String lineaDesconocida = 'linea_desconocida';
  static const String articuloDesconocido = 'articulo_desconocido';
  static const String comandaCerrada = 'comanda_cerrada';

  /// Al marchar: no hay líneas activas de ese pase y, además, los pases
  /// están desactivados o el pase no existe en la configuración.
  static const String paseNoValido = 'pase_no_valido';

  /// Al marchar: no hay líneas activas de ese pase, que sí existe en la
  /// configuración.
  static const String paseSinLineas = 'pase_sin_lineas';
}

/// Estado de la sala: mesas y comandas abiertas.
final class SalaSnapshot extends Equatable {
  SalaSnapshot({
    required List<Mesa> mesas,
    required List<Comanda> comandas,
    this.catalogoVersion,
    required this.generadoEn,
    this.enrutamiento,
    this.pases,
  }) : mesas = List.unmodifiable(mesas),
       comandas = List.unmodifiable(comandas);

  factory SalaSnapshot.fromJson(Map<String, Object?> json) => SalaSnapshot(
    mesas: [
      for (final mesa in json.requireMapList('mesas')) Mesa.fromJson(mesa),
    ],
    comandas: [
      for (final comanda in json.requireMapList('comandas'))
        Comanda.fromJson(comanda),
    ],
    catalogoVersion: json.optionalString('catalogoVersion'),
    generadoEn: DateTime.parse(json.requireString('generadoEn')),
    enrutamiento: _enrutamientoTolerante(json['enrutamiento']),
    pases: PasesConfig.tolerante(json['pases']),
  );

  /// El enrutamiento es informativo para el comandero (el host fija el
  /// destino definitivo de cada línea): un valor ausente o que esta versión
  /// no entiende (p. ej. un destino nuevo de un host más moderno) se ignora
  /// en vez de invalidar todo el snapshot.
  static EnrutamientoComandas? _enrutamientoTolerante(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    try {
      return EnrutamientoComandas.fromJson(raw);
    } on FormatException {
      return null;
    }
  }

  final List<Mesa> mesas;

  /// Una comanda por mesa ocupada.
  final List<Comanda> comandas;

  /// Identificador del catálogo vigente, para que el comandero sepa si debe
  /// volver a pedirlo.
  final String? catalogoVersion;
  final DateTime generadoEn;

  /// Enrutamiento de comandas vigente en el host (familia → cocina/barra).
  /// El comandero lo usa para mostrar el destino de las líneas nuevas;
  /// `null` si el host es de una versión que no lo publica.
  final EnrutamientoComandas? enrutamiento;

  /// Configuración de pases del host. Un host nuevo la publica siempre (con
  /// `activos` verdadero o falso); `null` si el host es de una versión que no
  /// la publica o si no se entiende: entonces el comandero no muestra la
  /// interfaz de pases ni los botones «Marchar».
  final PasesConfig? pases;

  Comanda? comandaDeMesa(String mesaId) {
    for (final comanda in comandas) {
      if (comanda.mesaId == mesaId) return comanda;
    }
    return null;
  }

  /// Copia con la comanda de [mesaId] sustituida (`null` = mesa libre),
  /// conservando el resto de campos.
  SalaSnapshot conComanda(
    String mesaId,
    Comanda? comanda, {
    required DateTime generadoEn,
  }) => SalaSnapshot(
    mesas: mesas,
    comandas: [
      for (final c in comandas)
        if (c.mesaId != mesaId) c,
      ?comanda,
    ],
    catalogoVersion: catalogoVersion,
    generadoEn: generadoEn,
    enrutamiento: enrutamiento,
    pases: pases,
  );

  Map<String, Object?> toJson() => {
    'mesas': [for (final mesa in mesas) mesa.toJson()],
    'comandas': [for (final comanda in comandas) comanda.toJson()],
    if (catalogoVersion != null) 'catalogoVersion': catalogoVersion,
    'generadoEn': generadoEn.toIso8601String(),
    if (enrutamiento != null) 'enrutamiento': enrutamiento!.toJson(),
    if (pases != null) 'pases': pases!.toJson(),
  };

  @override
  List<Object?> get props => [
    mesas,
    comandas,
    catalogoVersion,
    generadoEn,
    enrutamiento,
    pases,
  ];
}

/// Líneas nuevas para una mesa. Si la mesa no tiene comanda abierta, el host
/// la abre.
///
/// Con [lineas] vacías y [comensales] sirve para cambiar solo los comensales
/// de la comanda abierta; entonces [comandaId] identifica esa comanda.
final class ComandaSubmitPayload extends Equatable {
  ComandaSubmitPayload({
    required this.mesaId,
    required List<LineaComanda> lineas,
    this.camarero,
    this.comensales,
    this.comandaId,
  }) : lineas = List.unmodifiable(lineas);

  factory ComandaSubmitPayload.fromJson(Map<String, Object?> json) =>
      ComandaSubmitPayload(
        mesaId: json.requireString('mesaId'),
        lineas: [
          for (final linea in json.requireMapList('lineas'))
            LineaComanda.fromJson(linea),
        ],
        camarero: json.optionalString('camarero'),
        comensales: json.optionalInt('comensales'),
        comandaId: json.optionalString('comandaId'),
      );

  final String mesaId;
  final List<LineaComanda> lineas;
  final String? camarero;
  final int? comensales;

  /// Comanda abierta que ve el comandero (opcional). Un host nuevo no aplica
  /// un envío de solo comensales si no coincide con la comanda abierta de la
  /// mesa; un host antiguo lo ignora.
  final String? comandaId;

  /// Copia con el camarero o los comensales cambiados (el host pone el
  /// nombre del dispositivo como camarero si el comandero no lo manda).
  ComandaSubmitPayload copyWith({String? camarero, int? comensales}) =>
      ComandaSubmitPayload(
        mesaId: mesaId,
        lineas: lineas,
        camarero: camarero ?? this.camarero,
        comensales: comensales ?? this.comensales,
        comandaId: comandaId,
      );

  Map<String, Object?> toJson() => {
    'mesaId': mesaId,
    'lineas': [for (final linea in lineas) linea.toJson()],
    if (camarero != null) 'camarero': camarero,
    if (comensales != null) 'comensales': comensales,
    if (comandaId != null) 'comandaId': comandaId,
  };

  @override
  List<Object?> get props => [mesaId, lineas, camarero, comensales, comandaId];
}

/// Resultado de [SalaMessageTypes.comandaSubmit].
final class ComandaSubmitResult extends Equatable {
  const ComandaSubmitResult({
    required this.comanda,
    required this.lineasNuevas,
    required this.lineasDuplicadas,
  });

  factory ComandaSubmitResult.fromJson(Map<String, Object?> json) =>
      ComandaSubmitResult(
        comanda: Comanda.fromJson(json.requireMap('comanda')),
        lineasNuevas: json.requireInt('lineasNuevas'),
        lineasDuplicadas: json.requireInt('lineasDuplicadas'),
      );

  final Comanda comanda;

  /// Líneas incorporadas en esta petición.
  final int lineasNuevas;

  /// Líneas ya conocidas (retransmisión): no se duplicaron.
  final int lineasDuplicadas;

  Map<String, Object?> toJson() => {
    'comanda': comanda.toJson(),
    'lineasNuevas': lineasNuevas,
    'lineasDuplicadas': lineasDuplicadas,
  };

  @override
  List<Object?> get props => [comanda, lineasNuevas, lineasDuplicadas];
}

final class LineaAnularPayload extends Equatable {
  const LineaAnularPayload({
    required this.mesaId,
    required this.lineaId,
    this.motivo,
  });

  factory LineaAnularPayload.fromJson(Map<String, Object?> json) =>
      LineaAnularPayload(
        mesaId: json.requireString('mesaId'),
        lineaId: json.requireString('lineaId'),
        motivo: json.optionalString('motivo'),
      );

  final String mesaId;
  final String lineaId;
  final String? motivo;

  Map<String, Object?> toJson() => {
    'mesaId': mesaId,
    'lineaId': lineaId,
    if (motivo != null) 'motivo': motivo,
  };

  @override
  List<Object?> get props => [mesaId, lineaId, motivo];
}

final class MesaCuentaPayload extends Equatable {
  const MesaCuentaPayload({required this.mesaId, required this.solicitada});

  factory MesaCuentaPayload.fromJson(Map<String, Object?> json) =>
      MesaCuentaPayload(
        mesaId: json.requireString('mesaId'),
        solicitada: json.requireBool('solicitada'),
      );

  final String mesaId;
  final bool solicitada;

  Map<String, Object?> toJson() => {'mesaId': mesaId, 'solicitada': solicitada};

  @override
  List<Object?> get props => [mesaId, solicitada];
}

/// Marchar un pase de la comanda abierta de una mesa: el host imprime en
/// cocina la orden de preparar sus líneas y registra la marcha en la comanda.
final class MarcharPasePayload extends Equatable {
  const MarcharPasePayload({
    required this.mesaId,
    required this.pase,
    required this.marchaId,
    this.comandaId,
    this.camarero,
  });

  /// Lanza [FormatException] si falta un campo obligatorio, si [pase] es
  /// menor que 1 o si [marchaId] está vacío o pasa de [maxLongitudMarchaId]
  /// caracteres (el host la convierte en `error validation`).
  factory MarcharPasePayload.fromJson(Map<String, Object?> json) {
    final mesaId = json.requireString('mesaId');
    final pase = json.requireInt('pase');
    if (pase < 1) {
      throw FormatException("Campo 'pase': debe ser 1 o mayor y es $pase");
    }
    final marchaId = json.requireString('marchaId');
    if (marchaId.isEmpty || marchaId.length > maxLongitudMarchaId) {
      throw FormatException(
        "Campo 'marchaId': se esperaban entre 1 y $maxLongitudMarchaId "
        'caracteres y tiene ${marchaId.length}',
      );
    }
    return MarcharPasePayload(
      mesaId: mesaId,
      pase: pase,
      marchaId: marchaId,
      comandaId: json.optionalString('comandaId'),
      camarero: json.optionalString('camarero'),
    );
  }

  static const int maxLongitudMarchaId = 64;

  final String mesaId;

  /// Pase a marchar (1 o mayor). El host lo acepta aunque no esté en la
  /// configuración si la comanda tiene líneas activas de ese pase.
  final int pase;

  /// Identificador único de la pulsación, generado por el comandero (uuid):
  /// una marcha retransmitida con el mismo `marchaId` no se vuelve a
  /// imprimir.
  final String marchaId;

  /// Comanda que ve el comandero. Si no es la abierta en la mesa (se cobró y
  /// se volvió a abrir), el host responde `mesa_sin_comanda` sin tocar nada.
  final String? comandaId;

  /// Quién marcha; si falta, el host usa el nombre del dispositivo.
  final String? camarero;

  /// `comandaId` y `camarero` solo si no son nulos.
  Map<String, Object?> toJson() => {
    'mesaId': mesaId,
    'pase': pase,
    'marchaId': marchaId,
    if (comandaId != null) 'comandaId': comandaId,
    if (camarero != null) 'camarero': camarero,
  };

  @override
  List<Object?> get props => [mesaId, pase, marchaId, comandaId, camarero];
}

/// Respuesta genérica con la comanda resultante de una mesa.
final class ComandaResult extends Equatable {
  const ComandaResult({required this.comanda});

  factory ComandaResult.fromJson(Map<String, Object?> json) =>
      ComandaResult(comanda: Comanda.fromJson(json.requireMap('comanda')));

  final Comanda comanda;

  Map<String, Object?> toJson() => {'comanda': comanda.toJson()};

  @override
  List<Object?> get props => [comanda];
}

/// La comanda de [mesaId] cambió; `null` significa que la mesa quedó libre
/// (cobrada o vaciada).
final class SalaChangedEvent extends Equatable {
  const SalaChangedEvent({required this.mesaId, this.comanda});

  factory SalaChangedEvent.fromJson(Map<String, Object?> json) =>
      SalaChangedEvent(
        mesaId: json.requireString('mesaId'),
        comanda: switch (json.optionalMap('comanda')) {
          final Map<String, Object?> map => Comanda.fromJson(map),
          null => null,
        },
      );

  final String mesaId;
  final Comanda? comanda;

  Map<String, Object?> toJson() => {
    'mesaId': mesaId,
    if (comanda != null) 'comanda': comanda!.toJson(),
  };

  @override
  List<Object?> get props => [mesaId, comanda];
}

final class CatalogoChangedEvent extends Equatable {
  const CatalogoChangedEvent({required this.version});

  factory CatalogoChangedEvent.fromJson(Map<String, Object?> json) =>
      CatalogoChangedEvent(version: json.requireString('version'));

  final String version;

  Map<String, Object?> toJson() => {'version': version};

  @override
  List<Object?> get props => [version];
}
