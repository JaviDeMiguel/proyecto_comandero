/// El cierre de cada servicio del host termina aunque alguien tenga en pausa
/// su suscripción a uno de sus streams.
///
/// Riverpod pausa las suscripciones de las pantallas tapadas (el salón bajo
/// la mesa) y cerrar un `StreamController.broadcast` esperando su `Future`
/// no terminaba hasta que el «done» llegaba a ese oyente: `HostRuntime.dispose`
/// se quedaba colgado (lo destapó la prueba de flujo de Windows).
library;

import 'dart:async';

import 'package:proyecto_comandero/core/isolates/isolate_runner.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/cierre_z_service.dart';
import 'package:proyecto_comandero/features/host/application/host_network_service.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/printing_service.dart';
import 'package:proyecto_comandero/features/host/application/reposicion_service.dart';
import 'package:proyecto_comandero/features/host/application/stock_service.dart';
import 'package:proyecto_comandero/features/host/application/sync_outbox.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:test/test.dart';

import 'support/host_test_support.dart';

/// Plazo de sobra para un cierre sin trabajo pendiente.
const Duration _plazo = Duration(seconds: 2);

/// Se suscribe a [stream] y pone la suscripción en pausa, como Riverpod con
/// una pantalla tapada. La cancela al terminar el test.
void _oyenteEnPausa(Stream<Object?> stream) {
  final suscripcion = stream.listen((_) {})..pause();
  addTearDown(suscripcion.cancel);
}

Future<void> _terminaATiempo(Future<void> cierre) =>
    expectLater(cierre.timeout(_plazo), completes);

void main() {
  late AlertBus alerts;
  late HostStateStore store;

  setUp(() async {
    alerts = AlertBus();
    store = await HostStateStore.load(
      InMemoryHostStateRepository(),
      initial: () => HostSnapshot(mesas: mesasPrueba),
      alerts: alerts,
    );
  });

  SyncOutbox outbox() => SyncOutbox(store: store, alerts: alerts);

  test('AlertBus', () async {
    _oyenteEnPausa(alerts.stream);
    await _terminaATiempo(alerts.dispose());
  });

  test('HostStateStore (changes)', () async {
    _oyenteEnPausa(store.changes);
    await _terminaATiempo(store.dispose());
  });

  test('SyncOutbox (status y terminados)', () async {
    final cola = outbox();
    _oyenteEnPausa(cola.status);
    _oyenteEnPausa(cola.terminados);
    await _terminaATiempo(cola.dispose());
  });

  test('SalaService (changes y enrutamientoChanges)', () async {
    final fixture = await SalaFixture.create();
    _oyenteEnPausa(fixture.sala.changes);
    _oyenteEnPausa(fixture.sala.enrutamientoChanges);
    await _terminaATiempo(fixture.sala.dispose());
  });

  test('CatalogService (changes)', () async {
    final catalogo = CatalogService(store: store, alerts: alerts);
    _oyenteEnPausa(catalogo.changes);
    await _terminaATiempo(catalogo.dispose());
  });

  test('StockService (descuentos)', () async {
    final stock = StockService(
      store: store,
      alerts: alerts,
      outbox: outbox(),
      runner: const InlineIsolateRunner(),
      codalmacen: 'ALG',
    );
    _oyenteEnPausa(stock.descuentos);
    await _terminaATiempo(stock.dispose());
  });

  test('ReposicionService (auditorias)', () async {
    final reposicion = ReposicionService(
      alerts: alerts,
      outbox: outbox(),
      runner: const InlineIsolateRunner(),
      settings: const ReposicionSettings(),
      codalmacen: 'ALG',
    );
    _oyenteEnPausa(reposicion.auditorias);
    await _terminaATiempo(reposicion.dispose());
  });

  test('CierreZService (cierres)', () async {
    const runner = InlineIsolateRunner();
    final cierreZ = CierreZService(
      store: store,
      alerts: alerts,
      outbox: outbox(),
      printing: PrintingService(
        alerts: alerts,
        runner: runner,
        settings: const ImpresionSettings(),
        nombreTpv: 'TPV',
        store: store,
      ),
      runner: runner,
      cierre: const CierreSettings(),
      fiscal: const FiscalSettings(
        codcliente: 'TPV',
        codpagoEfectivo: 'TPVEFE',
        codpagoTarjeta: 'TPVTAR',
        codalmacen: 'ALG',
      ),
      nombreTpv: 'TPV',
    );
    _oyenteEnPausa(cierreZ.cierres);
    await _terminaATiempo(cierreZ.dispose());
  });

  test('HostNetworkService (sessionEvents)', () async {
    final fixture = await SalaFixture.create();
    final red = HostNetworkService(
      sala: fixture.sala,
      catalog: fixture.catalog,
      alerts: fixture.alerts,
      config: const HostNetworkConfig(
        hostId: 'host',
        hostName: 'Host',
        discoveryEnabled: false,
      ),
    );
    _oyenteEnPausa(red.sessionEvents);
    await _terminaATiempo(red.dispose());
  });
}
