import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';
import 'package:test/test.dart';

import 'fakes/fake_ports.dart';
import 'support/host_test_support.dart';

void main() {
  late InMemoryHostStateRepository repo;
  late HostStateStore store;
  late AlertBus alerts;
  late FakeCatalogPort port;
  late CatalogService service;
  late List<CatalogoChangedEvent> eventos;

  setUp(() async {
    repo = InMemoryHostStateRepository();
    alerts = AlertBus();
    store = await HostStateStore.load(
      repo,
      initial: HostSnapshot.new,
      alerts: alerts,
    );
    port = FakeCatalogPort(catalogoPrueba());
    service = CatalogService(store: store, alerts: alerts, port: port);
    eventos = [];
    service.changes.listen(eventos.add);
  });

  tearDown(() async {
    await service.dispose();
    await store.dispose();
    await alerts.dispose();
  });

  test('la versión depende del contenido, no de la fecha ni los avisos', () {
    final a = catalogoPrueba(obtenidoEn: DateTime(2026, 1, 1));
    final b = catalogoPrueba(obtenidoEn: DateTime(2026, 6, 1));
    expect(CatalogService.versionDe(a), CatalogService.versionDe(b));
    expect(CatalogService.versionDe(a), hasLength(16));
    final c = CatalogSnapshot(
      familias: a.familias,
      impuestos: a.impuestos,
      articulos: a.articulos.sublist(1),
      avisos: a.avisos,
      obtenidoEn: a.obtenidoEn,
    );
    expect(CatalogService.versionDe(c), isNot(CatalogService.versionDe(a)));
  });

  test('refrescar guarda el catálogo y emite solo cuando cambia', () async {
    expect(service.disponible, isFalse);
    final snapshot = await service.refrescar();
    await Future<void>.delayed(Duration.zero);
    expect(snapshot, catalogoPrueba());
    expect(service.catalogo, catalogoPrueba());
    expect(service.version, CatalogService.versionDe(catalogoPrueba()));
    expect(eventos.single.version, service.version);
    expect((await repo.load())!.catalogoVersion, service.version);
    expect(service.articulo('CANA')!.descripcion, 'Caña');

    // Misma descarga, otra fecha: sin evento.
    port.snapshot = catalogoPrueba(obtenidoEn: DateTime(2027));
    await service.refrescar();
    await Future<void>.delayed(Duration.zero);
    expect(eventos, hasLength(1));

    // Contenido distinto: evento nuevo.
    port.snapshot = CatalogSnapshot(
      familias: const [],
      impuestos: catalogoPrueba().impuestos,
      articulos: catalogoPrueba().articulos,
      avisos: const ['producto X sin impuesto'],
      obtenidoEn: DateTime(2027),
    );
    await service.refrescar();
    await Future<void>.delayed(Duration.zero);
    expect(eventos, hasLength(2));
    expect(alerts.recientes.single.titulo, contains('sin impuesto'));
  });

  test('llamadas simultáneas comparten la descarga', () async {
    final resultados = await Future.wait([
      service.refrescar(),
      service.refrescar(),
    ]);
    expect(port.calls, 1);
    expect(resultados[0], resultados[1]);
  });

  test('fallo de la API conserva el catálogo anterior', () async {
    await service.refrescar();
    port.failNext(const ErpApiException('caído', statusCode: 503));
    expect(service.refrescar(), throwsA(isA<ErpApiException>()));
    await Future<void>.delayed(Duration.zero);
    expect(service.catalogo, catalogoPrueba());
  });

  test('sin puerto configurado lanza ConfigException', () async {
    final sinErp = CatalogService(store: store, alerts: alerts);
    expect(sinErp.configurado, isFalse);
    expect(sinErp.refrescar, throwsA(isA<ConfigException>()));
    sinErp.configurar(port: port);
    expect(await sinErp.refrescar(), catalogoPrueba());
    await sinErp.dispose();
  });
}
