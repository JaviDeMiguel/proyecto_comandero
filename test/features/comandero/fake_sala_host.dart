/// Host simulado para los tests del comandero: un [TcpHostServer] REAL en
/// loopback cuyo manejador implementa los mensajes de sala en memoria, más un
/// [UdpDiscoveryResponder] real para el descubrimiento.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_responder.dart';
import 'package:proyecto_comandero/core/network/discovery/udp_discovery_scanner.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_host_server.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/marcha_pase.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

/// Plazo genérico de espera de un evento en los tests.
const Duration kWait = Duration(seconds: 8);

final InternetAddress kLoopback = InternetAddress.loopbackIPv4;

/// Opciones cortas del cliente TCP para que las reconexiones sean rápidas.
const ClientOptions kClientOptions = ClientOptions(
  connectTimeout: Duration(seconds: 1),
  handshakeTimeout: Duration(seconds: 1),
  requestTimeout: Duration(seconds: 2),
  reconnectBaseDelay: Duration(milliseconds: 20),
  reconnectMaxDelay: Duration(milliseconds: 80),
  reconnectJitter: 0.2,
  closeTimeout: Duration(milliseconds: 100),
);

/// Catálogo de pruebas: dos familias, dos tipos de IVA, un artículo bloqueado.
final CatalogSnapshot kCatalogoPrueba = CatalogSnapshot(
  familias: const [
    FamiliaCatalogo(codfamilia: 'BEB', descripcion: 'Bebidas'),
    FamiliaCatalogo(codfamilia: 'PLA', descripcion: 'Platos'),
  ],
  impuestos: const [
    ImpuestoCatalogo(codimpuesto: 'IVA10', descripcion: 'IVA 10%', ivaBp: 1000),
    ImpuestoCatalogo(codimpuesto: 'IVA21', descripcion: 'IVA 21%', ivaBp: 2100),
  ],
  articulos: [
    ArticuloCatalogo(
      referencia: 'CANA',
      idproducto: 1,
      idvariante: 1,
      descripcion: 'Caña',
      codfamilia: 'BEB',
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      precioNeto: 1.81818,
      pvpCents: ArticuloCatalogo.pvpCentsFrom(1.81818, 1000),
      nostock: true,
    ),
    ArticuloCatalogo(
      referencia: 'PAELLA',
      idproducto: 2,
      idvariante: 2,
      descripcion: 'Paella',
      codfamilia: 'PLA',
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      precioNeto: 10.90909,
      pvpCents: ArticuloCatalogo.pvpCentsFrom(10.90909, 1000),
      nostock: true,
    ),
    ArticuloCatalogo(
      referencia: 'CAFE',
      idproducto: 3,
      idvariante: 3,
      descripcion: 'Café',
      codfamilia: 'BEB',
      codimpuesto: 'IVA21',
      ivaBp: 2100,
      precioNeto: 1.0,
      pvpCents: ArticuloCatalogo.pvpCentsFrom(1.0, 2100),
      nostock: true,
    ),
    const ArticuloCatalogo(
      referencia: 'BLOQ',
      idproducto: 4,
      idvariante: 4,
      descripcion: 'Bloqueado',
      codfamilia: 'PLA',
      codimpuesto: 'IVA10',
      ivaBp: 1000,
      precioNeto: 5.0,
      pvpCents: 550,
      bloqueado: true,
    ),
  ],
  avisos: const [],
  obtenidoEn: DateTime.utc(2026, 10, 7, 9),
);

const List<Mesa> kMesasPrueba = [
  Mesa(id: 'm1', nombre: 'Mesa 1', zona: 'Salón', orden: 1),
  Mesa(id: 'm2', nombre: 'Mesa 2', zona: 'Salón', orden: 2),
  Mesa(id: 'b1', nombre: 'Barra', zona: 'Barra', orden: 1),
];

/// Reserva un puerto TCP libre en loopback y lo libera: el host de pruebas
/// debe poder pararse y volver a arrancar en el MISMO puerto.
Future<int> freeTcpPort() async {
  final socket = await ServerSocket.bind(kLoopback, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

final class FakeSalaHost {
  FakeSalaHost({
    required this.tcpPort,
    this.hostId = 'host-1',
    this.hostName = 'Barra',
    String? pairingCode,
    CatalogSnapshot? catalogo,
    this.catalogoVersion = 'v1',
    List<Mesa> mesas = kMesasPrueba,
    this.pases,
  }) : catalogo = catalogo ?? kCatalogoPrueba,
       mesas = List.of(mesas) {
    server = TcpHostServer(
      identity: HostIdentity(hostId: hostId, hostName: hostName),
      onRequest: _onRequest,
      options: HostServerOptions(
        port: tcpPort,
        bindAddress: kLoopback,
        handshakeTimeout: const Duration(seconds: 1),
        heartbeatInterval: const Duration(milliseconds: 100),
        idleTimeout: const Duration(seconds: 2),
        pairingCode: pairingCode,
        closeTimeout: const Duration(milliseconds: 100),
      ),
    );
    responder = UdpDiscoveryResponder(
      announcement: () => HostAnnouncement(
        hostId: hostId,
        hostName: hostName,
        tcpPort: tcpPort,
        requiresPairing: server.options.requiresPairing,
      ),
      port: 0,
      bindAddress: kLoopback,
      maxResponsesPerSource: 1000,
    );
  }

  final int tcpPort;
  final String hostId;
  final String hostName;
  final List<Mesa> mesas;
  CatalogSnapshot catalogo;
  String catalogoVersion;

  /// Enrutamiento que publica en el snapshot (`null` = host antiguo).
  EnrutamientoComandas? enrutamiento;

  /// Configuración de pases que publica en el snapshot. `null` = host
  /// antiguo: no la publica y, como un host con los pases desactivados,
  /// descarta el pase de las líneas que recibe.
  PasesConfig? pases;

  /// Tipos de petición que este host "no conoce": responde `error
  /// unknown_type` no reintentable, como un host de una versión anterior.
  final Set<String> tiposNoAdmitidos = {};

  late final TcpHostServer server;
  late final UdpDiscoveryResponder responder;

  /// Comandas abiertas por mesa.
  final Map<String, Comanda> comandas = {};

  /// Tipos de las peticiones recibidas, en orden (incluye retransmisiones
  /// solo si el servidor no las dedujo: el servidor deduplica antes).
  final List<String> requests = [];

  /// Payloads de `comanda.submit` que llegaron al manejador, en orden.
  final List<ComandaSubmitPayload> submits = [];

  /// Payloads de `comanda.pase.marchar` que llegaron al manejador, en orden
  /// (con las retransmisiones que el servidor no dedujo, p. ej. tras
  /// reiniciar el host).
  final List<MarcharPasePayload> marchasRecibidas = [];

  /// Marchas registradas por `comanda.pase.marchar`, en orden: una
  /// retransmisión con un `marchaId` ya conocido no añade ninguna. Las
  /// marchas automáticas del envío no se registran aquí.
  final List<MarchaPase> marchas = [];

  int _comandaSeq = 0;
  int _envioSeq = 0;
  int _marchaSeq = 0;

  /// Número de `catalogo.get` que fallarán (error interno) antes de servirlo.
  int fallosCatalogo = 0;

  /// Si no es `null`, `comanda.submit` registra las líneas y espera a que se
  /// complete antes de responder (simula un `ack` que no llega a tiempo).
  Completer<void>? retenerSubmit;

  /// Si no es `null`, `comanda.submit` registra las líneas y responde este
  /// payload en lugar del resultado (simula un host de otra versión).
  Map<String, Object?>? respuestaSubmit;

  /// Si no es `null`, `comanda.pase.marchar` registra la marcha y espera a
  /// que se complete antes de responder (simula un `ack` que no llega).
  Completer<void>? retenerMarchar;

  HostEndpoint get endpoint => HostEndpoint(host: '127.0.0.1', port: tcpPort);

  /// Opciones de escaneo dirigidas al respondedor de este host.
  DiscoveryScanOptions get scanOptions => DiscoveryScanOptions(
    timeout: const Duration(milliseconds: 400),
    probes: 2,
    probeInterval: const Duration(milliseconds: 50),
    targets: [DiscoveryTarget(address: kLoopback, port: responder.port)],
  );

  Future<void> start() async {
    await server.start();
    await responder.start();
  }

  Future<void> stop() async {
    await server.stop();
    await responder.stop();
  }

  Future<void> dispose() async {
    await responder.stop();
    await server.dispose();
  }

  /// Emite `sala.changed` a todos los comanderos.
  int emitirSalaChanged(String mesaId, Comanda? comanda) {
    if (comanda == null) {
      comandas.remove(mesaId);
    } else {
      comandas[mesaId] = comanda;
    }
    return server.broadcast(
      SalaMessageTypes.salaChanged,
      SalaChangedEvent(mesaId: mesaId, comanda: comanda).toJson(),
    );
  }

  /// Sustituye el catálogo y avisa a los comanderos.
  int cambiarCatalogo(CatalogSnapshot nuevo, String version) {
    catalogo = nuevo;
    catalogoVersion = version;
    return server.broadcast(
      SalaMessageTypes.catalogoChanged,
      CatalogoChangedEvent(version: version).toJson(),
    );
  }

  /// Sustituye el enrutamiento que publica y avisa con `enrutamiento.changed`.
  int cambiarEnrutamiento(EnrutamientoComandas? nuevo) {
    enrutamiento = nuevo;
    return server.broadcast(SalaMessageTypes.enrutamientoChanged, const {});
  }

  /// Sustituye la configuración de pases que publica y avisa con
  /// `enrutamiento.changed` (el mismo evento que el host real).
  int cambiarPases(PasesConfig? nuevo) {
    pases = nuevo;
    return server.broadcast(SalaMessageTypes.enrutamientoChanged, const {});
  }

  SalaSnapshot snapshot() => SalaSnapshot(
    mesas: mesas,
    comandas: comandas.values.toList(),
    catalogoVersion: catalogoVersion,
    generadoEn: DateTime.now(),
    enrutamiento: enrutamiento,
    pases: pases,
  );

  Future<Map<String, Object?>> _onRequest(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) async {
    requests.add(request.type);
    if (tiposNoAdmitidos.contains(request.type)) {
      throw _tipoDesconocido(request.type);
    }
    switch (request.type) {
      case SalaMessageTypes.salaSnapshotGet:
        return snapshot().toJson();
      case SalaMessageTypes.catalogoGet:
        if (fallosCatalogo > 0) {
          fallosCatalogo--;
          throw const RemoteRequestException(
            'Fallo transitorio del catálogo',
            code: ErrorCodes.internal,
          );
        }
        return catalogo.toJson();
      case SalaMessageTypes.comandaSubmit:
        return _aceptarLineas(ComandaSubmitPayload.fromJson(request.payload));
      case SalaMessageTypes.paseMarchar:
        return _marcharPase(
          session,
          MarcharPasePayload.fromJson(request.payload),
        );
      case SalaMessageTypes.lineaAnular:
        final payload = LineaAnularPayload.fromJson(request.payload);
        final comanda = _requireComanda(payload.mesaId);
        final linea = comanda.lineaPorId(payload.lineaId);
        if (linea == null) {
          throw RemoteRequestException(
            "Línea '${payload.lineaId}' desconocida",
            code: SalaErrorCodes.lineaDesconocida,
          );
        }
        final actualizada = comanda.conLineaActualizada(
          linea.anular(cuando: DateTime.now(), motivo: payload.motivo),
        );
        comandas[payload.mesaId] = actualizada;
        return ComandaResult(comanda: actualizada).toJson();
      case SalaMessageTypes.mesaCuenta:
        final payload = MesaCuentaPayload.fromJson(request.payload);
        final comanda = _requireComanda(payload.mesaId);
        final actualizada = comanda.copyWith(
          cuentaSolicitada: payload.solicitada,
        );
        comandas[payload.mesaId] = actualizada;
        return ComandaResult(comanda: actualizada).toJson();
      default:
        throw _tipoDesconocido(request.type);
    }
  }

  /// `comanda.submit` como el host nuevo (§4.4 y §5.1 del diseño): conserva
  /// el pase de las líneas solo con los pases activos, estampa el nº de
  /// envío, marcha solo el primer pase si procede, aplica los comensales y
  /// conserva al primer camarero. Un envío vacío no abre una mesa libre ni
  /// toca una comanda distinta de la del `comandaId`.
  Future<Map<String, Object?>> _aceptarLineas(
    ComandaSubmitPayload payload,
  ) async {
    submits.add(payload);
    _requireMesa(payload.mesaId);
    for (final linea in payload.lineas) {
      if (catalogo.porReferencia(linea.referencia) == null) {
        throw RemoteRequestException(
          "Artículo '${linea.referencia}' desconocido",
          code: SalaErrorCodes.articuloDesconocido,
        );
      }
    }
    final actual = comandas[payload.mesaId];
    final vacio = payload.lineas.isEmpty;
    if (actual != null &&
        vacio &&
        payload.comandaId != null &&
        payload.comandaId != actual.id) {
      return ComandaSubmitResult(
        comanda: actual,
        lineasNuevas: 0,
        lineasDuplicadas: 0,
      ).toJson();
    }
    final base =
        actual ??
        Comanda(
          id: vacio ? 'c-vacia' : 'c${++_comandaSeq}',
          mesaId: payload.mesaId,
          abiertaEn: DateTime.now(),
          camarero: payload.camarero,
          comensales: payload.comensales,
        );
    final envio = _envioSeq + 1;
    final conservaPase = pases?.activos ?? false;
    final (:comanda, :nuevas) = base.conLineas([
      for (final linea in payload.lineas)
        linea.copyWith(
          camarero: linea.camarero ?? payload.camarero,
          pase: conservaPase ? null : () => null,
          envio: envio,
        ),
    ]);
    if (nuevas.isNotEmpty) _envioSeq = envio;
    final resultado = _conMarchasAutomaticas(comanda, nuevas, payload.camarero)
        .copyWith(
          camarero: comanda.camarero ?? payload.camarero,
          comensales: payload.comensales ?? comanda.comensales,
        );
    // Un envío vacío en una mesa libre devuelve la comanda sin guardarla.
    if (actual != null || !vacio) comandas[payload.mesaId] = resultado;
    final retener = retenerSubmit;
    if (retener != null) await retener.future;
    final respuesta = respuestaSubmit;
    if (respuesta != null) return respuesta;
    return ComandaSubmitResult(
      comanda: resultado,
      lineasNuevas: nuevas.length,
      lineasDuplicadas: payload.lineas.length - nuevas.length,
    ).toJson();
  }

  /// D2.3 del diseño: con los pases activos, (a) si `marcharAlEnviar` y la
  /// comanda no tiene marchas, marcha el pase más bajo de las líneas nuevas;
  /// (b) marcha cualquier pase de las líneas nuevas menor que el mayor ya
  /// marchado.
  Comanda _conMarchasAutomaticas(
    Comanda comanda,
    List<LineaComanda> nuevas,
    String? camarero,
  ) {
    final config = pases;
    if (config == null || !config.activos) return comanda;
    final pasesNuevos = {for (final linea in nuevas) ?linea.pase};
    if (pasesNuevos.isEmpty) return comanda;
    final aMarchar = <int>{
      if (config.marcharAlEnviar && !comanda.tieneMarchas)
        pasesNuevos.reduce(min),
    };
    final mayor = [...comanda.pasesMarchados, ...aMarchar].fold(0, max);
    aMarchar.addAll(
      pasesNuevos.where(
        (pase) => pase < mayor && !comanda.pasesMarchados.contains(pase),
      ),
    );
    var resultado = comanda;
    for (final pase in aMarchar.toList()..sort()) {
      resultado = resultado.conMarcha(
        MarchaPase(
          id: 'auto-${++_marchaSeq}',
          pase: pase,
          cuando: DateTime.now(),
          camarero: camarero,
          automatica: true,
        ),
      );
    }
    return resultado;
  }

  /// `comanda.pase.marchar` como el host nuevo (§5.7 del diseño): rechaza un
  /// `comandaId` que no sea el de la comanda abierta, es idempotente por
  /// `marchaId` y exige líneas activas del pase (con ellas marcha aunque el
  /// pase no esté en la configuración o los pases estén desactivados).
  Future<Map<String, Object?>> _marcharPase(
    ClientSessionInfo session,
    MarcharPasePayload payload,
  ) async {
    marchasRecibidas.add(payload);
    final comanda = _requireComanda(payload.mesaId);
    if (payload.comandaId != null && payload.comandaId != comanda.id) {
      throw RemoteRequestException(
        "La comanda de la mesa '${payload.mesaId}' ya se cerró",
        code: SalaErrorCodes.mesaSinComanda,
      );
    }
    if (comanda.marchaPorId(payload.marchaId) != null) {
      return ComandaResult(comanda: comanda).toJson();
    }
    if (!comanda.lineasActivas.any((linea) => linea.pase == payload.pase)) {
      final config = pases;
      if (config == null || !config.activos || !config.existe(payload.pase)) {
        throw RemoteRequestException(
          'El pase ${payload.pase} no existe',
          code: SalaErrorCodes.paseNoValido,
        );
      }
      throw RemoteRequestException(
        "La mesa '${payload.mesaId}' no tiene líneas de "
        '${config.nombreDe(payload.pase)}',
        code: SalaErrorCodes.paseSinLineas,
      );
    }
    final marcha = MarchaPase(
      id: payload.marchaId,
      pase: payload.pase,
      cuando: DateTime.now(),
      camarero: payload.camarero ?? session.deviceName,
      repetida: comanda.pasesMarchados.contains(payload.pase),
    );
    final actualizada = comanda.conMarcha(marcha);
    comandas[payload.mesaId] = actualizada;
    marchas.add(marcha);
    final retener = retenerMarchar;
    if (retener != null) await retener.future;
    return ComandaResult(comanda: actualizada).toJson();
  }

  static RemoteRequestException _tipoDesconocido(String type) =>
      RemoteRequestException(
        "Tipo '$type' desconocido",
        code: ErrorCodes.unknownType,
      );

  void _requireMesa(String mesaId) {
    if (!mesas.any((mesa) => mesa.id == mesaId)) {
      throw RemoteRequestException(
        "Mesa '$mesaId' desconocida",
        code: SalaErrorCodes.mesaDesconocida,
      );
    }
  }

  Comanda _requireComanda(String mesaId) {
    _requireMesa(mesaId);
    final comanda = comandas[mesaId];
    if (comanda == null) {
      throw RemoteRequestException(
        "La mesa '$mesaId' no tiene comanda abierta",
        code: SalaErrorCodes.mesaSinComanda,
      );
    }
    return comanda;
  }
}

/// Espera el primer estado que cumpla [test] (o el actual, si ya lo cumple).
Future<T> waitState<T extends Object>(
  Stream<Object> states,
  Object current,
  bool Function(T state) test, {
  Duration timeout = kWait,
  String? what,
}) async {
  final actual = current;
  if (actual is T && test(actual)) return actual;
  final state = await states
      .firstWhere((s) => s is T && test(s))
      .timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'No llegó ${what ?? 'el estado ${T.toString()}'} en $timeout',
        ),
      );
  return state as T;
}
