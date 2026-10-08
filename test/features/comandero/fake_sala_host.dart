/// Host simulado para los tests del comandero: un [TcpHostServer] REAL en
/// loopback cuyo manejador implementa los mensajes de sala en memoria, más un
/// [UdpDiscoveryResponder] real para el descubrimiento.
library;

import 'dart:async';
import 'dart:io';

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
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
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

  late final TcpHostServer server;
  late final UdpDiscoveryResponder responder;

  /// Comandas abiertas por mesa.
  final Map<String, Comanda> comandas = {};

  /// Tipos de las peticiones recibidas, en orden (incluye retransmisiones
  /// solo si el servidor no las dedujo: el servidor deduplica antes).
  final List<String> requests = [];

  int _comandaSeq = 0;

  /// Número de `catalogo.get` que fallarán (error interno) antes de servirlo.
  int fallosCatalogo = 0;

  /// Si no es `null`, `comanda.submit` registra las líneas y espera a que se
  /// complete antes de responder (simula un `ack` que no llega a tiempo).
  Completer<void>? retenerSubmit;

  /// Si no es `null`, `comanda.submit` registra las líneas y responde este
  /// payload en lugar del resultado (simula un host de otra versión).
  Map<String, Object?>? respuestaSubmit;

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

  SalaSnapshot snapshot() => SalaSnapshot(
    mesas: mesas,
    comandas: comandas.values.toList(),
    catalogoVersion: catalogoVersion,
    generadoEn: DateTime.now(),
    enrutamiento: enrutamiento,
  );

  Future<Map<String, Object?>> _onRequest(
    ClientSessionInfo session,
    ProtocolMessage request,
  ) async {
    requests.add(request.type);
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
        final payload = ComandaSubmitPayload.fromJson(request.payload);
        _requireMesa(payload.mesaId);
        for (final linea in payload.lineas) {
          if (catalogo.porReferencia(linea.referencia) == null) {
            throw RemoteRequestException(
              "Artículo '${linea.referencia}' desconocido",
              code: SalaErrorCodes.articuloDesconocido,
            );
          }
        }
        final actual =
            comandas[payload.mesaId] ??
            Comanda(
              id: 'c${++_comandaSeq}',
              mesaId: payload.mesaId,
              abiertaEn: DateTime.now(),
              camarero: payload.camarero,
              comensales: payload.comensales,
            );
        final resultado = actual.conLineas(payload.lineas);
        comandas[payload.mesaId] = resultado.comanda;
        final retener = retenerSubmit;
        if (retener != null) await retener.future;
        final respuesta = respuestaSubmit;
        if (respuesta != null) return respuesta;
        return ComandaSubmitResult(
          comanda: resultado.comanda,
          lineasNuevas: resultado.nuevas.length,
          lineasDuplicadas: payload.lineas.length - resultado.nuevas.length,
        ).toJson();
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
        throw RemoteRequestException(
          "Tipo '${request.type}' desconocido",
          code: ErrorCodes.unknownType,
        );
    }
  }

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
