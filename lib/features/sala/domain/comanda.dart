import 'dart:collection';

import 'package:equatable/equatable.dart';

import '../../../core/utils/json_map.dart';
import '../../../core/utils/json_tolerante.dart';
import 'linea_comanda.dart';
import 'marcha_pase.dart';
import 'precuenta_emitida.dart';

/// Bloque de envío: tramo consecutivo de líneas, en orden de llegada, con el
/// mismo [LineaComanda.envio] (`null` en las líneas de un diario anterior a
/// ese campo).
typedef BloqueEnvio = ({int? envio, List<LineaComanda> lineas});

/// Grupo de líneas de un pase (`null` = directas).
typedef GrupoPase = ({int? pase, List<LineaComanda> lineas});

/// Comanda abierta de una mesa: todo lo pedido desde que se ocupó hasta que
/// se cobra. Una mesa tiene como mucho una comanda abierta.
///
/// [marchas] y [precuentas] son posteriores a la primera versión del diario:
/// se leen de forma tolerante y solo se escriben si no están vacías, de modo
/// que un JSON antiguo se reescribe igual.
final class Comanda extends Equatable {
  Comanda({
    required this.id,
    required this.mesaId,
    required this.abiertaEn,
    List<LineaComanda> lineas = const [],
    this.camarero,
    this.comensales,
    this.cuentaSolicitada = false,
    this.observaciones,
    List<MarchaPase> marchas = const [],
    List<PrecuentaEmitida> precuentas = const [],
  }) : lineas = List.unmodifiable(lineas),
       marchas = List.unmodifiable(marchas),
       precuentas = List.unmodifiable(precuentas);

  factory Comanda.fromJson(Map<String, Object?> json) => Comanda(
    id: json.requireString('id'),
    mesaId: json.requireString('mesaId'),
    abiertaEn: DateTime.parse(json.requireString('abiertaEn')),
    lineas: [
      for (final linea in json.requireMapList('lineas'))
        LineaComanda.fromJson(linea),
    ],
    camarero: json.optionalString('camarero'),
    comensales: json.optionalInt('comensales'),
    cuentaSolicitada: json.optionalBool('cuentaSolicitada') ?? false,
    observaciones: json.optionalString('observaciones'),
    // Una lista ausente o ilegible se lee vacía y un elemento ilegible se
    // descarta: nunca invalidan la comanda entera.
    marchas: listaTolerante(json['marchas'], MarchaPase.fromJson),
    precuentas: listaTolerante(json['precuentas'], PrecuentaEmitida.fromJson),
  );

  final String id;
  final String mesaId;
  final DateTime abiertaEn;

  /// Líneas en orden de llegada, incluidas las anuladas (quedan para la
  /// trazabilidad y para revertir su stock una sola vez).
  final List<LineaComanda> lineas;
  final String? camarero;
  final int? comensales;

  /// El cliente ha pedido la cuenta (la mesa se resalta en el host).
  final bool cuentaSolicitada;
  final String? observaciones;

  /// Marchas de pases en orden cronológico (la primera puede ser automática).
  final List<MarchaPase> marchas;

  /// Precuentas emitidas, en orden de emisión; cada una es un documento
  /// autocontenido que se reimprime tal como salió aunque la comanda cambie.
  final List<PrecuentaEmitida> precuentas;

  Iterable<LineaComanda> get lineasActivas =>
      lineas.where((linea) => !linea.anulada);

  bool get estaVacia => lineasActivas.isEmpty;

  /// Suma de PVP × cantidad de las líneas activas. Es el importe orientativo
  /// de la mesa; el total legal del ticket lo calcula la réplica del
  /// `Calculator` de FacturaScripts al cobrar y puede diferir en un céntimo.
  int get importeCents =>
      lineasActivas.fold(0, (total, linea) => total + linea.importeCents);

  /// Pases ya marchados (una marcha repetida no añade ninguno).
  Set<int> get pasesMarchados => {for (final marcha in marchas) marcha.pase};

  bool get tieneMarchas => marchas.isNotEmpty;

  /// Número que llevará la siguiente precuenta de la comanda (1, 2, 3…).
  int get siguienteNumeroPrecuenta => precuentas.length + 1;

  /// Bloques de envío de la comanda. Un bloque es un envío aunque su número
  /// se repita: el nº se reinicia en el Cierre Z y una mesa abierta lo
  /// atraviesa. «2º envío de la mesa» es el índice del bloque + 1, y
  /// «ENVÍOS Nº 12, 15», los números de los bloques.
  ///
  /// Las líneas se añaden siempre al final ([conLineas]) y la anulación las
  /// sustituye en su sitio ([conLineaActualizada]), así que los bloques no
  /// se mezclan.
  List<BloqueEnvio> get bloquesDeEnvio {
    final bloques = <BloqueEnvio>[];
    var inicio = 0;
    for (var i = 1; i <= lineas.length; i++) {
      if (i < lineas.length && lineas[i].envio == lineas[inicio].envio) {
        continue;
      }
      bloques.add((
        envio: lineas[inicio].envio,
        lineas: List<LineaComanda>.unmodifiable(lineas.sublist(inicio, i)),
      ));
      inicio = i;
    }
    return bloques;
  }

  /// Líneas (incluidas las anuladas) del último bloque de envío.
  List<LineaComanda> get lineasUltimoEnvio =>
      bloquesDeEnvio.lastOrNull?.lineas ?? const [];

  LineaComanda? lineaPorId(String lineaId) {
    for (final linea in lineas) {
      if (linea.id == lineaId) return linea;
    }
    return null;
  }

  /// Marcha con ese [MarchaPase.id] (idempotencia de `comanda.pase.marchar`).
  MarchaPase? marchaPorId(String marchaId) {
    for (final marcha in marchas) {
      if (marcha.id == marchaId) return marcha;
    }
    return null;
  }

  /// Marcha más reciente del [pase], o `null` si no se ha marchado.
  MarchaPase? ultimaMarchaDe(int pase) {
    for (final marcha in marchas.reversed) {
      if (marcha.pase == pase) return marcha;
    }
    return null;
  }

  /// Añade las líneas cuyo [LineaComanda.id] no exista ya (idempotente ante
  /// retransmisiones). Devuelve la comanda resultante y las líneas que
  /// realmente se incorporaron.
  ({Comanda comanda, List<LineaComanda> nuevas}) conLineas(
    Iterable<LineaComanda> candidatas,
  ) {
    final existentes = {for (final linea in lineas) linea.id};
    final nuevas = <LineaComanda>[];
    for (final linea in candidatas) {
      if (existentes.add(linea.id)) nuevas.add(linea);
    }
    if (nuevas.isEmpty) return (comanda: this, nuevas: const []);
    return (comanda: copyWith(lineas: [...lineas, ...nuevas]), nuevas: nuevas);
  }

  /// Sustituye la línea con el mismo id.
  Comanda conLineaActualizada(LineaComanda actualizada) => copyWith(
    lineas: [
      for (final linea in lineas)
        if (linea.id == actualizada.id) actualizada else linea,
    ],
  );

  /// Añade la marcha al final.
  Comanda conMarcha(MarchaPase marcha) =>
      copyWith(marchas: [...marchas, marcha]);

  /// Añade la precuenta al final.
  Comanda conPrecuenta(PrecuentaEmitida precuenta) =>
      copyWith(precuentas: [...precuentas, precuenta]);

  Comanda copyWith({
    List<LineaComanda>? lineas,
    String? camarero,
    int? comensales,
    bool? cuentaSolicitada,
    String? observaciones,
    List<MarchaPase>? marchas,
    List<PrecuentaEmitida>? precuentas,
  }) => Comanda(
    id: id,
    mesaId: mesaId,
    abiertaEn: abiertaEn,
    lineas: lineas ?? this.lineas,
    camarero: camarero ?? this.camarero,
    comensales: comensales ?? this.comensales,
    cuentaSolicitada: cuentaSolicitada ?? this.cuentaSolicitada,
    observaciones: observaciones ?? this.observaciones,
    marchas: marchas ?? this.marchas,
    precuentas: precuentas ?? this.precuentas,
  );

  /// [marchas] y [precuentas] solo si no están vacías.
  Map<String, Object?> toJson() => {
    'id': id,
    'mesaId': mesaId,
    'abiertaEn': abiertaEn.toIso8601String(),
    'lineas': [for (final linea in lineas) linea.toJson()],
    if (camarero != null) 'camarero': camarero,
    if (comensales != null) 'comensales': comensales,
    'cuentaSolicitada': cuentaSolicitada,
    if (observaciones != null) 'observaciones': observaciones,
    if (marchas.isNotEmpty)
      'marchas': [for (final marcha in marchas) marcha.toJson()],
    if (precuentas.isNotEmpty)
      'precuentas': [for (final precuenta in precuentas) precuenta.toJson()],
  };

  @override
  List<Object?> get props => [
    id,
    mesaId,
    abiertaEn,
    lineas,
    camarero,
    comensales,
    cuentaSolicitada,
    observaciones,
    marchas,
    precuentas,
  ];
}

/// Agrupa las líneas por pase conservando el orden de llegada dentro de cada
/// grupo: primero las directas y después los pases de menor a mayor,
/// incluidos los que no están en la configuración. Solo devuelve grupos con
/// líneas. Lo usan la impresión, `MesaPage` y el comandero.
List<GrupoPase> agruparPorPase(Iterable<LineaComanda> lineas) {
  final directas = <LineaComanda>[];
  final porPase = SplayTreeMap<int, List<LineaComanda>>();
  for (final linea in lineas) {
    final pase = linea.pase;
    if (pase == null) {
      directas.add(linea);
    } else {
      porPase.putIfAbsent(pase, () => []).add(linea);
    }
  }
  return [
    if (directas.isNotEmpty)
      (pase: null, lineas: List<LineaComanda>.unmodifiable(directas)),
    for (final grupo in porPase.entries)
      (pase: grupo.key, lineas: List<LineaComanda>.unmodifiable(grupo.value)),
  ];
}
