import 'package:equatable/equatable.dart';

import '../../../core/facturascripts/catalog/catalog_models.dart';
import '../../../core/inventory/inventory_models.dart';
import '../../../core/utils/json_map.dart';
import '../../sala/domain/comanda.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/ticket.dart';
import 'sync_job.dart';

/// Turno de caja abierto.
final class CierreAbierto extends Equatable {
  const CierreAbierto({
    required this.id,
    required this.abiertoEn,
    required this.fondoCajaCents,
    this.retiradasCents = 0,
  });

  factory CierreAbierto.fromJson(Map<String, Object?> json) => CierreAbierto(
    id: json.requireString('id'),
    abiertoEn: DateTime.parse(json.requireString('abiertoEn')),
    fondoCajaCents: json.requireInt('fondoCajaCents'),
    retiradasCents: json.optionalInt('retiradasCents') ?? 0,
  );

  final String id;
  final DateTime abiertoEn;
  final int fondoCajaCents;

  /// Efectivo retirado de la caja durante el turno (acumulado).
  final int retiradasCents;

  CierreAbierto conRetirada(int cents) => CierreAbierto(
    id: id,
    abiertoEn: abiertoEn,
    fondoCajaCents: fondoCajaCents,
    retiradasCents: retiradasCents + cents,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'abiertoEn': abiertoEn.toIso8601String(),
    'fondoCajaCents': fondoCajaCents,
    'retiradasCents': retiradasCents,
  };

  @override
  List<Object?> get props => [id, abiertoEn, fondoCajaCents, retiradasCents];
}

/// Resumen archivado de un Cierre Z.
final class ResumenCierre extends Equatable {
  const ResumenCierre({
    required this.id,
    required this.abiertoEn,
    required this.cerradoEn,
    required this.numTickets,
    required this.numAnulados,
    required this.ventasTotalCents,
    required this.ventasEfectivoCents,
    required this.ventasTarjetaCents,
    this.numTicketsMixtos = 0,
    required this.fondoCajaCents,
    required this.retiradasCents,
    required this.efectivoEsperadoCents,
    this.efectivoContadoCents,
    required this.descuadreCents,
    this.documentoAsiento,
    this.asientoEncolado = false,
  });

  factory ResumenCierre.fromJson(Map<String, Object?> json) => ResumenCierre(
    id: json.requireString('id'),
    abiertoEn: DateTime.parse(json.requireString('abiertoEn')),
    cerradoEn: DateTime.parse(json.requireString('cerradoEn')),
    numTickets: json.requireInt('numTickets'),
    numAnulados: json.optionalInt('numAnulados') ?? 0,
    ventasTotalCents: json.requireInt('ventasTotalCents'),
    ventasEfectivoCents: json.requireInt('ventasEfectivoCents'),
    ventasTarjetaCents: json.requireInt('ventasTarjetaCents'),
    numTicketsMixtos: json.optionalInt('numTicketsMixtos') ?? 0,
    fondoCajaCents: json.requireInt('fondoCajaCents'),
    retiradasCents: json.optionalInt('retiradasCents') ?? 0,
    efectivoEsperadoCents: json.requireInt('efectivoEsperadoCents'),
    efectivoContadoCents: json.optionalInt('efectivoContadoCents'),
    descuadreCents: json.requireInt('descuadreCents'),
    documentoAsiento: json.optionalString('documentoAsiento'),
    asientoEncolado: json.optionalBool('asientoEncolado') ?? false,
  );

  final String id;
  final DateTime abiertoEn;
  final DateTime cerradoEn;
  final int numTickets;
  final int numAnulados;
  final int ventasTotalCents;
  final int ventasEfectivoCents;
  final int ventasTarjetaCents;

  /// Tickets cobrados en parte en efectivo y en parte con tarjeta (sus
  /// partes ya están repartidas en las ventas por forma de pago). Los
  /// cierres archivados antes de existir el cobro mixto leen `0`.
  final int numTicketsMixtos;
  final int fondoCajaCents;
  final int retiradasCents;
  final int efectivoEsperadoCents;
  final int? efectivoContadoCents;
  final int descuadreCents;

  /// Clave `documento` del asiento Z en el ERP, si se generó.
  final String? documentoAsiento;
  final bool asientoEncolado;

  Map<String, Object?> toJson() => {
    'id': id,
    'abiertoEn': abiertoEn.toIso8601String(),
    'cerradoEn': cerradoEn.toIso8601String(),
    'numTickets': numTickets,
    'numAnulados': numAnulados,
    'ventasTotalCents': ventasTotalCents,
    'ventasEfectivoCents': ventasEfectivoCents,
    'ventasTarjetaCents': ventasTarjetaCents,
    if (numTicketsMixtos != 0) 'numTicketsMixtos': numTicketsMixtos,
    'fondoCajaCents': fondoCajaCents,
    'retiradasCents': retiradasCents,
    'efectivoEsperadoCents': efectivoEsperadoCents,
    if (efectivoContadoCents != null)
      'efectivoContadoCents': efectivoContadoCents,
    'descuadreCents': descuadreCents,
    if (documentoAsiento != null) 'documentoAsiento': documentoAsiento,
    'asientoEncolado': asientoEncolado,
  };

  @override
  List<Object?> get props => [
    id,
    abiertoEn,
    cerradoEn,
    numTickets,
    numAnulados,
    ventasTotalCents,
    ventasEfectivoCents,
    ventasTarjetaCents,
    numTicketsMixtos,
    fondoCajaCents,
    retiradasCents,
    efectivoEsperadoCents,
    efectivoContadoCents,
    descuadreCents,
    documentoAsiento,
    asientoEncolado,
  ];
}

/// Recetas (`tpv_escandallos`) cacheadas con su fecha de lectura.
final class RecetasCache extends Equatable {
  RecetasCache({required List<RecetaLinea> lineas, required this.obtenidasEn})
    : lineas = List.unmodifiable(lineas);

  factory RecetasCache.fromJson(Map<String, Object?> json) => RecetasCache(
    lineas: [
      for (final item in json.requireMapList('lineas'))
        RecetaLinea(
          refPlato: item.requireString('refPlato'),
          refIngrediente: item.requireString('refIngrediente'),
          cantidadNeta: item.requireDouble('cantidadNeta'),
          mermaPct: item.optionalDouble('mermaPct') ?? 0,
        ),
    ],
    obtenidasEn: DateTime.parse(json.requireString('obtenidasEn')),
  );

  final List<RecetaLinea> lineas;
  final DateTime obtenidasEn;

  bool caducada(DateTime now, Duration ttl) =>
      now.difference(obtenidasEn) >= ttl;

  Map<String, Object?> toJson() => {
    'lineas': [
      for (final l in lineas)
        {
          'refPlato': l.refPlato,
          'refIngrediente': l.refIngrediente,
          'cantidadNeta': l.cantidadNeta,
          'mermaPct': l.mermaPct,
        },
    ],
    'obtenidasEn': obtenidasEn.toIso8601String(),
  };

  @override
  List<Object?> get props => [lineas, obtenidasEn];
}

/// Diario local del host: todo lo que debe sobrevivir a un reinicio.
///
/// Es inmutable; cada mutación produce un snapshot nuevo que
/// `HostStateRepository` persiste completo (fichero JSON atómico).
final class HostSnapshot extends Equatable {
  HostSnapshot({
    List<Mesa> mesas = const [],
    List<Comanda> comandas = const [],
    List<Ticket> ticketsTurno = const [],
    this.numeroLocalSiguiente = 1,
    this.cierreAbierto,
    List<ResumenCierre> historialCierres = const [],
    this.catalogo,
    this.catalogoVersion,
    this.recetas,
    List<SyncJob> cola = const [],
  }) : mesas = List.unmodifiable(mesas),
       comandas = List.unmodifiable(comandas),
       ticketsTurno = List.unmodifiable(ticketsTurno),
       historialCierres = List.unmodifiable(historialCierres),
       cola = List.unmodifiable(cola);

  /// Lanza [FormatException] si el JSON no tiene la forma esperada.
  factory HostSnapshot.fromJson(Map<String, Object?> json) => HostSnapshot(
    mesas: [
      for (final item in json.optionalMapList('mesas')) Mesa.fromJson(item),
    ],
    comandas: [
      for (final item in json.optionalMapList('comandas'))
        Comanda.fromJson(item),
    ],
    ticketsTurno: [
      for (final item in json.optionalMapList('ticketsTurno'))
        Ticket.fromJson(item),
    ],
    numeroLocalSiguiente: json.optionalInt('numeroLocalSiguiente') ?? 1,
    cierreAbierto: switch (json.optionalMap('cierreAbierto')) {
      final Map<String, Object?> map => CierreAbierto.fromJson(map),
      null => null,
    },
    historialCierres: [
      for (final item in json.optionalMapList('historialCierres'))
        ResumenCierre.fromJson(item),
    ],
    catalogo: switch (json.optionalMap('catalogo')) {
      final Map<String, Object?> map => CatalogSnapshot.fromJson(map),
      null => null,
    },
    catalogoVersion: json.optionalString('catalogoVersion'),
    recetas: switch (json.optionalMap('recetas')) {
      final Map<String, Object?> map => RecetasCache.fromJson(map),
      null => null,
    },
    cola: [
      for (final item in json.optionalMapList('cola')) SyncJob.fromJson(item),
    ],
  );

  /// Cierres archivados que se conservan.
  static const int maxHistorialCierres = 30;

  final List<Mesa> mesas;

  /// Comandas abiertas (una por mesa ocupada).
  final List<Comanda> comandas;

  /// Tickets cobrados desde el último Cierre Z.
  final List<Ticket> ticketsTurno;
  final int numeroLocalSiguiente;
  final CierreAbierto? cierreAbierto;

  /// Últimos cierres, del más reciente al más antiguo.
  final List<ResumenCierre> historialCierres;
  final CatalogSnapshot? catalogo;

  /// Hash del contenido del catálogo; cambia solo si cambia el catálogo.
  final String? catalogoVersion;
  final RecetasCache? recetas;

  /// Cola de sincronización en orden de creación.
  final List<SyncJob> cola;

  Comanda? comandaDeMesa(String mesaId) {
    for (final comanda in comandas) {
      if (comanda.mesaId == mesaId) return comanda;
    }
    return null;
  }

  Mesa? mesaPorId(String mesaId) {
    for (final mesa in mesas) {
      if (mesa.id == mesaId) return mesa;
    }
    return null;
  }

  Ticket? ticketPorId(String ticketId) {
    for (final ticket in ticketsTurno) {
      if (ticket.id == ticketId) return ticket;
    }
    return null;
  }

  SyncJob? jobPorId(String jobId) {
    for (final job in cola) {
      if (job.id == jobId) return job;
    }
    return null;
  }

  HostSnapshot copyWith({
    List<Mesa>? mesas,
    List<Comanda>? comandas,
    List<Ticket>? ticketsTurno,
    int? numeroLocalSiguiente,
    CierreAbierto? cierreAbierto,
    bool cerrarTurno = false,
    List<ResumenCierre>? historialCierres,
    CatalogSnapshot? catalogo,
    String? catalogoVersion,
    RecetasCache? recetas,
    List<SyncJob>? cola,
  }) => HostSnapshot(
    mesas: mesas ?? this.mesas,
    comandas: comandas ?? this.comandas,
    ticketsTurno: ticketsTurno ?? this.ticketsTurno,
    numeroLocalSiguiente: numeroLocalSiguiente ?? this.numeroLocalSiguiente,
    cierreAbierto: cerrarTurno ? null : (cierreAbierto ?? this.cierreAbierto),
    historialCierres: historialCierres ?? this.historialCierres,
    catalogo: catalogo ?? this.catalogo,
    catalogoVersion: catalogoVersion ?? this.catalogoVersion,
    recetas: recetas ?? this.recetas,
    cola: cola ?? this.cola,
  );

  /// Sustituye la comanda de su mesa (o la añade); con `null` la retira.
  HostSnapshot conComanda(String mesaId, Comanda? comanda) => copyWith(
    comandas: [
      for (final c in comandas)
        if (c.mesaId != mesaId) c,
      ?comanda,
    ],
  );

  /// Sustituye el trabajo con el mismo id (o lo añade al final).
  HostSnapshot conJob(SyncJob job) =>
      copyWith(cola: _replaceOrAppend(cola, job, (j) => j.id == job.id));

  /// Sustituye el ticket con el mismo id (o lo añade al final).
  HostSnapshot conTicket(Ticket ticket) => copyWith(
    ticketsTurno: _replaceOrAppend(
      ticketsTurno,
      ticket,
      (t) => t.id == ticket.id,
    ),
  );

  static List<T> _replaceOrAppend<T>(
    List<T> items,
    T item,
    bool Function(T) matches,
  ) {
    final index = items.indexWhere(matches);
    if (index < 0) return [...items, item];
    return [
      for (var i = 0; i < items.length; i++) i == index ? item : items[i],
    ];
  }

  Map<String, Object?> toJson() => {
    'mesas': [for (final m in mesas) m.toJson()],
    'comandas': [for (final c in comandas) c.toJson()],
    'ticketsTurno': [for (final t in ticketsTurno) t.toJson()],
    'numeroLocalSiguiente': numeroLocalSiguiente,
    if (cierreAbierto != null) 'cierreAbierto': cierreAbierto!.toJson(),
    'historialCierres': [for (final r in historialCierres) r.toJson()],
    if (catalogo != null) 'catalogo': catalogo!.toJson(),
    if (catalogoVersion != null) 'catalogoVersion': catalogoVersion,
    if (recetas != null) 'recetas': recetas!.toJson(),
    'cola': [for (final j in cola) j.toJson()],
  };

  @override
  List<Object?> get props => [
    mesas,
    comandas,
    ticketsTurno,
    numeroLocalSiguiente,
    cierreAbierto,
    historialCierres,
    catalogo,
    catalogoVersion,
    recetas,
    cola,
  ];
}

extension on Map<String, Object?> {
  /// Lista de objetos opcional: ausente equivale a vacía.
  List<Map<String, Object?>> optionalMapList(String key) =>
      this[key] == null ? const [] : requireMapList(key);
}
