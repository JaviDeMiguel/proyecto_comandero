/// Datos de prueba compartidos por los tests del host.
library;

import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/features/host/application/alert_bus.dart';
import 'package:proyecto_comandero/features/host/application/catalog_service.dart';
import 'package:proyecto_comandero/features/host/application/host_state_store.dart';
import 'package:proyecto_comandero/features/host/application/sala_service.dart';
import 'package:proyecto_comandero/features/host/data/in_memory_host_state_repository.dart';
import 'package:proyecto_comandero/features/host/domain/host_snapshot.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/sala/domain/mesa.dart';
import 'package:proyecto_comandero/features/sala/protocol/sala_messages.dart';

import '../fakes/fake_ports.dart';

const List<Mesa> mesasPrueba = [
  Mesa(id: 'm1', nombre: 'Mesa 1', orden: 1),
  Mesa(id: 'm2', nombre: 'Mesa 2', orden: 2),
  Mesa(id: 'barra', nombre: 'Barra', zona: 'Barra'),
];

/// Catálogo con los artículos del sandbox: `CANA` y `CAFE` al 10 %,
/// `PAELLA` (plato con escandallo), `AGUA` al 21 % y `VIEJO` bloqueado.
CatalogSnapshot catalogoPrueba({DateTime? obtenidoEn}) => CatalogSnapshot(
  familias: const [
    FamiliaCatalogo(codfamilia: 'BEB', descripcion: 'Bebidas'),
    FamiliaCatalogo(codfamilia: 'COM', descripcion: 'Comidas'),
  ],
  impuestos: const [
    ImpuestoCatalogo(
      codimpuesto: 'IVA10',
      descripcion: 'IVA 10%',
      ivaBp: 1000,
      codsubcuentarep: '4770000010',
    ),
    ImpuestoCatalogo(
      codimpuesto: 'IVA21',
      descripcion: 'IVA 21%',
      ivaBp: 2100,
      codsubcuentarep: '4770000021',
    ),
  ],
  articulos: [
    articulo('CANA', 'Caña', 0.86364, 'IVA10', 1000, 1, codfamilia: 'BEB'),
    articulo('CAFE', 'Café', 1.18182, 'IVA10', 1000, 2, codfamilia: 'BEB'),
    articulo('PAELLA', 'Paella', 10.90909, 'IVA10', 1000, 3, codfamilia: 'COM'),
    articulo('AGUA', 'Agua', 0.82645, 'IVA21', 2100, 4, codfamilia: 'BEB'),
    articulo('VIEJO', 'Descatalogado', 1, 'IVA21', 2100, 5, bloqueado: true),
  ],
  avisos: const [],
  obtenidoEn: obtenidoEn ?? DateTime(2026, 10, 7, 9),
);

/// Catálogo con jerarquía de familias para el enrutamiento:
/// Bebidas (`BEB`) ⊃ Cervezas (`CER`: `CANA`) y Cafés (`CAF`: `CAFE`);
/// Comidas (`COM`: `PAELLA`) ⊃ Postres (`POS`: `FLAN`); `AGUA` directamente
/// en Bebidas y `PAN` sin familia.
CatalogSnapshot catalogoConSubfamilias() {
  final base = catalogoPrueba();
  return CatalogSnapshot(
    familias: const [
      FamiliaCatalogo(codfamilia: 'BEB', descripcion: 'Bebidas'),
      FamiliaCatalogo(codfamilia: 'CER', descripcion: 'Cervezas', madre: 'BEB'),
      FamiliaCatalogo(codfamilia: 'CAF', descripcion: 'Cafés', madre: 'BEB'),
      FamiliaCatalogo(codfamilia: 'COM', descripcion: 'Comidas'),
      FamiliaCatalogo(codfamilia: 'POS', descripcion: 'Postres', madre: 'COM'),
    ],
    impuestos: base.impuestos,
    articulos: [
      articulo('CANA', 'Caña', 0.86364, 'IVA10', 1000, 1, codfamilia: 'CER'),
      articulo('CAFE', 'Café', 1.18182, 'IVA10', 1000, 2, codfamilia: 'CAF'),
      articulo(
        'PAELLA',
        'Paella',
        10.90909,
        'IVA10',
        1000,
        3,
        codfamilia: 'COM',
      ),
      articulo('AGUA', 'Agua', 0.82645, 'IVA21', 2100, 4, codfamilia: 'BEB'),
      articulo('FLAN', 'Flan', 3.63636, 'IVA10', 1000, 6, codfamilia: 'POS'),
      articulo('PAN', 'Pan', 0.90909, 'IVA10', 1000, 7),
    ],
    avisos: const [],
    obtenidoEn: base.obtenidoEn,
  );
}

ArticuloCatalogo articulo(
  String referencia,
  String descripcion,
  double precioNeto,
  String codimpuesto,
  int ivaBp,
  int id, {
  String? codfamilia,
  bool bloqueado = false,
}) => ArticuloCatalogo(
  referencia: referencia,
  idproducto: id,
  idvariante: id,
  descripcion: descripcion,
  codfamilia: codfamilia,
  codimpuesto: codimpuesto,
  ivaBp: ivaBp,
  precioNeto: precioNeto,
  pvpCents: ArticuloCatalogo.pvpCentsFrom(precioNeto, ivaBp),
  nostock: true,
  bloqueado: bloqueado,
);

/// Línea de comanda a partir de un artículo del catálogo de prueba.
LineaComanda linea(
  String id,
  String referencia,
  double cantidad, {
  String? nota,
  DestinoPreparacion destino = DestinoPreparacion.cocina,
  DateTime? creadaEn,
  CatalogSnapshot? catalogo,
}) {
  final art = (catalogo ?? catalogoPrueba()).porReferencia(referencia)!;
  return LineaComanda(
    id: id,
    referencia: referencia,
    descripcion: art.descripcion,
    cantidad: cantidad,
    pvpUnitarioCents: art.pvpCents,
    pvpUnitarioNeto: art.precioNeto,
    ivaBp: art.ivaBp,
    codimpuesto: art.codimpuesto,
    nota: nota,
    destino: destino,
    creadaEn: creadaEn ?? DateTime(2026, 10, 7, 13, 0),
  );
}

ComandaSubmitPayload submit(
  String mesaId,
  List<LineaComanda> lineas, {
  String? camarero,
}) => ComandaSubmitPayload(mesaId: mesaId, lineas: lineas, camarero: camarero);

/// Sala mínima en memoria con el catálogo de prueba cargado.
final class SalaFixture {
  SalaFixture._(
    this.repo,
    this.store,
    this.alerts,
    this.clock,
    this.catalog,
    this.sala,
  );

  /// [catalogo] sustituye al catálogo de prueba (ignorado si
  /// `conCatalogo` es falso); [enrutamiento] es el de la sala. [newId]
  /// sustituye a los ids correlativos `id-N` (p. ej. ids únicos por
  /// ejecución en los tests contra el sandbox).
  static Future<SalaFixture> create({
    InMemoryHostStateRepository? repo,
    FakeClock? clock,
    bool conCatalogo = true,
    CatalogSnapshot? catalogo,
    EnrutamientoComandas enrutamiento = const EnrutamientoComandas(),
    String Function()? newId,
  }) async {
    final repository = repo ?? InMemoryHostStateRepository();
    final reloj = clock ?? FakeClock();
    final alerts = AlertBus(now: reloj.call);
    final cat = conCatalogo ? (catalogo ?? catalogoPrueba()) : null;
    final store = await HostStateStore.load(
      repository,
      initial: () => HostSnapshot(
        mesas: mesasPrueba,
        catalogo: cat,
        catalogoVersion: cat == null ? null : CatalogService.versionDe(cat),
      ),
      alerts: alerts,
    );
    var ids = 0;
    final catalog = CatalogService(
      store: store,
      alerts: alerts,
      now: reloj.call,
    );
    final sala = SalaService(
      store: store,
      alerts: alerts,
      catalog: catalog,
      now: reloj.call,
      newId: newId ?? () => 'id-${++ids}',
      enrutamiento: enrutamiento,
    );
    return SalaFixture._(repository, store, alerts, reloj, catalog, sala);
  }

  final InMemoryHostStateRepository repo;
  final HostStateStore store;
  final AlertBus alerts;
  final FakeClock clock;
  final CatalogService catalog;
  final SalaService sala;

  Future<void> dispose() async {
    await sala.dispose();
    await catalog.dispose();
    await store.dispose();
    await alerts.dispose();
  }
}
