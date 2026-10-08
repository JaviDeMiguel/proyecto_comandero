/// Tests de integración contra el sandbox de FacturaScripts.
///
/// Se saltan si faltan `TPV_FS_BASE_URL` / `TPV_FS_TOKEN`. Solo LEEN datos
/// (ninguna llamada crea, modifica ni borra registros) y siempre envían el
/// token válido: un token inválido cuenta como incidencia y cinco incidencias
/// banean la IP de todos los agentes durante diez minutos.
///
/// Ejecución (Git Bash):
/// ```
/// TPV_FS_BASE_URL=http://127.0.0.1:8765 TPV_FS_TOKEN=... \
///   dart.bat test test/integration/facturascripts_core
/// ```
library;

import 'dart:io';

import 'package:proyecto_comandero/core/facturascripts/catalog/fs_catalog_service.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_api_config.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_resources.dart';
import 'package:proyecto_comandero/core/facturascripts/master_data/fs_master_data_service.dart';
import 'package:test/test.dart';

final String? _baseUrl = Platform.environment['TPV_FS_BASE_URL'];
final String? _token = Platform.environment['TPV_FS_TOKEN'];

// Identificadores sembrados en el sandbox (seed_ids.json); se pueden
// sobrescribir por entorno para otra instalación.
final String _codcliente =
    Platform.environment['TPV_FS_CODCLIENTE'] ?? 'TPVVARIOS';
final String _codpagoEfectivo =
    Platform.environment['TPV_FS_CODPAGO_EFECTIVO'] ?? 'TPVEFE';
final String _codpagoTarjeta =
    Platform.environment['TPV_FS_CODPAGO_TARJETA'] ?? 'TPVTAR';
final String _refPlato = Platform.environment['TPV_FS_REF_PLATO'] ?? 'PAELLA';
final String _refMateria =
    Platform.environment['TPV_FS_REF_MATERIA'] ?? 'ARROZ';

void _log(String message) => stdout.writeln('[fs-integration] $message');

void main() {
  final skip = (_baseUrl == null || _token == null)
      ? 'Define TPV_FS_BASE_URL y TPV_FS_TOKEN para ejecutar contra el sandbox'
      : null;

  late FsHttpApi api;
  late FsMasterDataService master;

  setUpAll(() {
    if (skip != null) return;
    api = FsHttpApi(FsApiConfig(baseUrl: _baseUrl!, token: _token!));
    master = FsMasterDataService(api);
  });

  tearDownAll(() async {
    if (skip != null) return;
    await api.close();
  });

  test(
    'GET /api/3 contiene todos los recursos requeridos por el TPV',
    () async {
      final resources = await api.resources();
      _log('recursos: ${resources.length}');
      final missing = FsResources.requeridosPorElTpv.difference(
        resources.toSet(),
      );
      expect(missing, isEmpty, reason: 'faltan recursos: $missing');
      expect(api.guardState, const FsGuardOk());
    },
    skip: skip,
  );

  test('settings/default: properties es texto JSON con los ajustes', () async {
    final raw = await api.get(FsResources.settings, 'default');
    _log('settings/default crudo: $raw');
    expect(raw!['properties'], isA<String>());

    final settings = await master.settingsDefault();
    _log('settings interpretado: $settings');
    expect(settings.codalmacen, isNotNull);
    expect(settings.idempresa, isNotNull);
    expect(settings.coddivisa, 'EUR');
    expect(settings.decimals, 2);
    expect(settings.taxCalculationMethod, anyOf('classic', 'price-adjusted'));
  }, skip: skip);

  test('empresa: cabecera del ticket', () async {
    final settings = await master.settingsDefault();
    final empresa = await master.empresa(settings.idempresa ?? 1);
    _log('empresa: $empresa');
    expect(empresa.nombre, isNotEmpty);
    expect(empresa.cifnif, isNotNull);
  }, skip: skip);

  test('series, formas de pago, almacenes y estados de factura', () async {
    final series = await master.series();
    _log('series: $series');
    expect(series.any((s) => s.esSimplificada), isTrue);

    final formas = await master.formasPago();
    _log('formas de pago: $formas');
    expect(formas.map((f) => f.codpago), contains(_codpagoEfectivo));
    expect(formas.map((f) => f.codpago), contains(_codpagoTarjeta));

    final almacenes = await master.almacenes();
    _log('almacenes: $almacenes');
    final settings = await master.settingsDefault();
    expect(almacenes.map((a) => a.codalmacen), contains(settings.codalmacen));

    final estados = await master.estadosFactura();
    _log('estados de FacturaCliente: $estados');
    expect(estados, isNotEmpty);
    expect(estados.every((e) => e.tipodoc == 'FacturaCliente'), isTrue);
    expect(estados.where((e) => e.predeterminado), hasLength(1));
    expect(estados.any((e) => !e.editable), isTrue);
    expect(estados.first.actualizastock, -1);
  }, skip: skip);

  test(
    'el cliente genérico sembrado existe y crearlo es idempotente',
    () async {
      final cliente = await master.cliente(_codcliente);
      _log('cliente genérico: $cliente');
      expect(cliente, isNotNull);
      expect(cliente!.riesgomax, isNull);
      expect(cliente.debaja, isFalse);

      // Ya existe: no debe hacer ningún POST.
      final again = await master.crearClienteGenerico(codcliente: _codcliente);
      expect(again, cliente);
      expect(await master.cliente('NO-EXISTE-TPV'), isNull);
    },
    skip: skip,
  );

  test('cargar(): catálogo sembrado con plato y materia prima', () async {
    final settings = await master.settingsDefault();
    final snapshot = await FsCatalogService(api)
        .cargar(codimpuestoPorDefecto: settings.codimpuesto);
    _log(
      'catálogo: ${snapshot.familias.length} familias, '
      '${snapshot.impuestos.length} impuestos, '
      '${snapshot.articulos.length} artículos, avisos: ${snapshot.avisos}',
    );
    expect(snapshot.impuestos.map((i) => i.codimpuesto), contains('IVA10'));
    expect(snapshot.impuesto('IVA10')!.ivaBp, 1000);

    final plato = snapshot.porReferencia(_refPlato);
    _log('plato: $plato');
    expect(plato, isNotNull);
    expect(plato!.vendible, isTrue);
    expect(plato.nostock, isTrue);
    expect(plato.ivaBp, 1000);
    expect(plato.precioNeto, closeTo(10.90909, 1e-9));
    expect(plato.pvpCents, 1200);

    final materia = snapshot.porReferencia(_refMateria);
    _log('materia prima: $materia');
    expect(materia, isNotNull);
    expect(materia!.sevende, isFalse);
    expect(materia.secompra, isTrue);
    expect(materia.nostock, isFalse);
    expect(materia.vendible, isFalse);
    expect(materia.pvpCents, 0);

    // Ida y vuelta por JSON (caché en disco / envío a comanderos).
    expect(CatalogSnapshot.fromJson(snapshot.toJson()), snapshot);
  }, skip: skip);

  test('familias.tpv_destino (plugin de hostelería) llega al catálogo; se '
      'salta si la columna no existe', () async {
    final raw = await api.listAll(FsResources.familias, sortBy: 'codfamilia');
    if (raw.isEmpty || !raw.any((r) => r.containsKey('tpv_destino'))) {
      markTestSkipped(
        'familias no tiene la columna tpv_destino (plugin de hostelería '
        'no activo en este FacturaScripts)',
      );
      return;
    }
    final valores = {for (final r in raw) r['codfamilia']: r['tpv_destino']};
    _log('familias.tpv_destino: $valores');
    // Contrato: 'cocina' | 'barra' | NULL (FS puede servir '' como nulo).
    for (final MapEntry(key: codfamilia, value: valor) in valores.entries) {
      expect(
        valor,
        anyOf(isNull, '', 'cocina', 'barra'),
        reason: 'tpv_destino de $codfamilia',
      );
    }

    final snapshot = await FsCatalogService(api).cargar();
    for (final familia in snapshot.familias) {
      expect(
        familia.destino,
        FamiliaCatalogo.normalizarDestino(valores[familia.codfamilia]),
        reason: familia.codfamilia,
      );
    }
    expect(CatalogSnapshot.fromJson(snapshot.toJson()), snapshot);
  }, skip: skip);

  test('diagnosticar(): la configuración sembrada no tiene errores', () async {
    final settings = await master.settingsDefault();
    final items = await master.diagnosticar(
      DiagnosticoConfig(
        codserie: 'S',
        codpagoEfectivo: _codpagoEfectivo,
        codpagoTarjeta: _codpagoTarjeta,
        codalmacen: settings.codalmacen!,
        codcliente: _codcliente,
      ),
    );
    for (final item in items) {
      _log(
        'diagnóstico ${item.nivel.name} [${item.codigo}] ${item.titulo}: '
        '${item.detalle}',
      );
    }
    expect(
      items.map((i) => i.codigo),
      containsAll([
        'api',
        'serie',
        'almacen',
        'cliente',
        'pago_efectivo',
        'pago_tarjeta',
      ]),
    );
    expect(items.where((i) => i.nivel == DiagnosticoNivel.error), isEmpty);
    expect(api.guardState, const FsGuardOk());
  }, skip: skip);
}
