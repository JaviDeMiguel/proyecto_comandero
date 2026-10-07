import 'dart:io';

import 'package:proyecto_comandero/core/facturascripts/accounting/accounting_models.dart';
import 'package:proyecto_comandero/core/facturascripts/accounting/fs_accounting_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_invoice_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/fs_supplier_order_service.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/invoice_models.dart';
import 'package:proyecto_comandero/core/facturascripts/documents/supplier_order_models.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_http_api.dart';
import 'package:proyecto_comandero/core/facturascripts/fs_values.dart';
import 'package:test/test.dart';

import 'sandbox.dart';

/// Identificadores sembrados en el sandbox (`fs_sandbox/seed_ids.json`).
const String codcliente = 'TPVVARIOS';
const String codserie = 'S';
const String codalmacen = 'ALG';
const String codpagoEfectivo = 'TPVEFE';
const String codproveedor = 'PROV1';
const int idempresa = 1;

void main() {
  final env = SandboxEnv.load();
  if (env == null) {
    test('sandbox no configurado', () {}, skip: SandboxEnv.skipReason);
    return;
  }

  late FsHttpApi api;
  final suffix = runSuffix();
  final ahora = DateTime.now();

  setUpAll(() async {
    api = env.connect();
    final resources = await api.resources();
    expect(resources, containsAll(['facturaclientes', 'crearFacturaCliente']));
  });

  tearDownAll(() => api.close());

  void nota(String text) => stdout.writeln('[sandbox] $text');

  group('FsInvoiceService', () {
    int? idfactura;

    tearDownAll(() async {
      if (idfactura == null) return;
      // Una factura emitida no se puede borrar: se devuelve a Boceto antes.
      final estados = await api.list(
        'estadodocumentos',
        filters: {'tipodoc': 'FacturaCliente', 'editable': 1},
        limit: 1,
      );
      if (estados.items.isNotEmpty) {
        await api.update('facturaclientes', idfactura!, {
          'idestado': estados.items.first.fsRequireInt('idestado'),
        });
      }
      final borrada = await api.delete('facturaclientes', idfactura!);
      nota('factura $idfactura borrada: $borrada');
    });

    test('crea una factura simplificada real, la cobra y la emite', () async {
      final estados = await api.list(
        'estadodocumentos',
        filters: {'tipodoc': 'FacturaCliente', 'editable': 0},
        limit: 1,
      );
      expect(estados.items, isNotEmpty, reason: 'estado Emitida');
      final idEmitida = estados.items.first.fsRequireInt('idestado');

      // 7 × 0.86364 @10 → 6.04548; 1 × 1.18182 @10 → 1.18182.
      // Grupo IVA10: neto 7.2273 → 7.23; IVA 0.72273 → 0.72; total 7.95.
      final ticket = TicketFactura(
        claveIdempotente: 'TPV-IT-$suffix',
        codcliente: codcliente,
        codserie: codserie,
        codpago: codpagoEfectivo,
        codalmacen: codalmacen,
        fechaHora: ahora,
        observaciones: 'Test de integración $suffix',
        lineas: [
          LineaFactura(
            referencia: 'CANA',
            descripcion: 'Caña',
            cantidad: 7,
            pvpunitarioNeto: 0.86364,
            codimpuesto: 'IVA10',
          ),
          LineaFactura(
            referencia: 'CAFE',
            descripcion: 'Café',
            cantidad: 1,
            pvpunitarioNeto: 1.18182,
            codimpuesto: 'IVA10',
          ),
        ],
        totalEsperadoCents: 795,
        modoPago: ModoPago.pagarTrasCrear,
        emitir: true,
        idEstadoEmitida: idEmitida,
      );

      final service = FsInvoiceService(api);
      final result = await service.crearOReanudar(ticket);
      idfactura = result.idfactura;
      nota('factura creada: $result');

      expect(result.yaExistia, isFalse);
      expect(result.totalCents, 795);
      expect(result.pagada, isTrue);
      expect(result.idasiento, isNotNull);
      expect(result.emitida, isTrue);
      expect(result.codigo, startsWith('F${ahora.year}$codserie'));
      expect(result.avisos, isEmpty);

      final doc = (await api.get('facturaclientes', result.idfactura))!;
      nota(
        'tipos en GET: total=${doc['total'].runtimeType} '
        'numero=${doc['numero'].runtimeType} pagada=${doc['pagada'].runtimeType} '
        'idasiento=${doc['idasiento'].runtimeType} fecha=${doc['fecha']}',
      );
      expect(doc.fsBool('pagada'), isTrue);
      expect(doc.fsRequireInt('idestado'), idEmitida);
      expect(doc.fsString('numero2'), 'TPV-IT-$suffix');

      final lineas = await api.listAll(
        'lineafacturaclientes',
        filters: {'idfactura': result.idfactura},
        sortBy: 'idlinea',
      );
      expect(lineas, hasLength(2));
      expect(lineas.every((l) => l.fsInt('idproducto') != null), isTrue);

      final recibos = await api.listAll(
        'reciboclientes',
        filters: {'idfactura': result.idfactura},
        sortBy: 'idrecibo',
      );
      expect(recibos.single.fsBool('pagado'), isTrue);
      expect(
        recibos.single.fsDate('fechapago'),
        DateTime(ahora.year, ahora.month, ahora.day),
      );
      expect(recibos.single.fsString('codpago'), codpagoEfectivo);
    });

    test('la misma clave devuelve la misma factura sin crear otra', () async {
      final ticket = TicketFactura(
        claveIdempotente: 'TPV-IT-$suffix',
        codcliente: codcliente,
        codserie: codserie,
        codpago: codpagoEfectivo,
        codalmacen: codalmacen,
        fechaHora: ahora,
        lineas: [
          LineaFactura(
            referencia: 'CANA',
            descripcion: 'Caña',
            cantidad: 7,
            pvpunitarioNeto: 0.86364,
            codimpuesto: 'IVA10',
          ),
        ],
        totalEsperadoCents: 795,
        modoPago: ModoPago.pagarTrasCrear,
      );
      final result = await FsInvoiceService(api).crearOReanudar(ticket);
      expect(result.yaExistia, isTrue);
      expect(result.idfactura, idfactura);
      expect(result.pagada, isTrue);
      expect(result.avisos, isEmpty);

      final page = await api.list(
        'facturaclientes',
        filters: {'numero2': 'TPV-IT-$suffix'},
        limit: 5,
      );
      expect(page.totalCount, 1);
    });

    test('hayFacturasConAsiento: hoy en serie S, con ambos formatos', () async {
      final service = FsAccountingService(api);
      expect(
        await service.hayFacturasConAsiento(fecha: ahora, codserie: codserie),
        isTrue,
      );
      final iso = await api.list(
        'facturaclientes',
        filters: {'fecha': fsFormatIsoDate(ahora), 'codserie': codserie},
        limit: 1,
      );
      final dmy = await api.list(
        'facturaclientes',
        filters: {'fecha': fsFormatDate(ahora), 'codserie': codserie},
        limit: 1,
      );
      nota('filter[fecha]: ISO → ${iso.totalCount}, d-m-Y → ${dmy.totalCount}');
      expect(iso.totalCount, dmy.totalCount);
      expect(iso.totalCount, greaterThan(0));
    });
  });

  group('FsSupplierOrderService', () {
    int? idpedido;
    double? pterecibirAntes;

    Future<double> pterecibir(String referencia) async {
      final page = await api.list(
        'stocks',
        filters: {'referencia': referencia, 'codalmacen': codalmacen},
        limit: 1,
      );
      return page.items.isEmpty
          ? 0
          : (page.items.first.fsDouble('pterecibir') ?? 0);
    }

    tearDownAll(() async {
      if (idpedido == null) return;
      final borrado = await api.delete('pedidoproveedores', idpedido!);
      nota('pedido $idpedido borrado: $borrado');
      if (borrado && pterecibirAntes != null) {
        expect(await pterecibir('ARROZ'), pterecibirAntes);
      }
    });

    test('crea un pedido real y suma pterecibir', () async {
      pterecibirAntes = await pterecibir('ARROZ');
      final draft = PedidoProveedorDraft(
        clave: 'TPV-REPO-IT-$suffix',
        codproveedor: codproveedor,
        codalmacen: codalmacen,
        fechaHora: ahora,
        observaciones: 'Test de integración $suffix',
        lineas: [
          LineaPedido(referencia: 'ARROZ', cantidad: 3),
          LineaPedido(referencia: 'POLLO', cantidad: 2),
          LineaPedido(referencia: 'NOEXISTE-$suffix', cantidad: 1),
        ],
      );
      final result = await FsSupplierOrderService(api).crearOReanudar(draft);
      idpedido = result.idpedido;
      nota('pedido creado: $result');

      expect(result.yaExistia, isFalse);
      expect(result.referenciasSinProducto, ['NOEXISTE-$suffix']);
      expect(await pterecibir('ARROZ'), pterecibirAntes! + 3);

      final again = await FsSupplierOrderService(api).crearOReanudar(draft);
      expect(again.yaExistia, isTrue);
      expect(again.idpedido, result.idpedido);
      expect(again.codigo, result.codigo);
      expect(again.totalCents, result.totalCents);
      expect(again.referenciasSinProducto, ['NOEXISTE-$suffix']);
      expect(await pterecibir('ARROZ'), pterecibirAntes! + 3);
    });
  });

  group('FsAccountingService', () {
    late FsAccountingService service;
    int? idasiento;

    setUpAll(() => service = FsAccountingService(api));

    tearDownAll(() async {
      if (idasiento == null) return;
      final borrado = await api.delete('asientos', idasiento!);
      nota('asiento $idasiento borrado: $borrado');
    });

    test('resuelve las subcuentas del ejercicio actual', () async {
      final s = await service.resolverSubcuentas(ahora, idempresa: idempresa);
      nota('subcuentas: ${s.porCuenta} iva=${s.ivaPorCodimpuesto}');
      expect(s.codejercicio, '${ahora.year}');
      expect(s[CuentaZ.caja570], startsWith('570'));
      expect(s[CuentaZ.banco572], startsWith('572'));
      expect(s[CuentaZ.ventas700], startsWith('700'));
      expect(s[CuentaZ.ivaRepercutido477], startsWith('477'));
      expect(s[CuentaZ.perdidas659], startsWith('659'));
      expect(s[CuentaZ.ingresos759], startsWith('759'));
      expect(s.subcuentaIva('IVA10'), '4770000010');
      expect(s.subcuentaIva('IVA0'), s[CuentaZ.ivaRepercutido477]);
    });

    test('asiento de descuadre: crear, verificar, borrar y recrear', () async {
      final s = await service.resolverSubcuentas(ahora, idempresa: idempresa);
      final z = AsientoZ(
        clave: 'Z-IT-$suffix',
        fecha: ahora,
        concepto: 'Cierre Z test de integración $suffix',
        lineas: [
          PartidaZ(
            codsubcuenta: s[CuentaZ.perdidas659],
            concepto: 'Faltante de caja (test $suffix)',
            debeCents: 320,
          ),
          PartidaZ(
            codsubcuenta: s[CuentaZ.caja570],
            concepto: 'Faltante de caja (test $suffix)',
            haberCents: 320,
          ),
        ],
      );

      final created = await service.contabilizarOReanudar(z);
      idasiento = created.idasiento;
      nota('asiento creado: $created');
      expect(created.yaExistia, isFalse);
      expect(created.partidasCreadas, 2);
      expect(created.verificado, isTrue);
      expect(created.numero, isNotNull);

      final cabecera = (await api.get('asientos', created.idasiento))!;
      nota(
        'tipos en GET asientos: importe=${cabecera['importe']} '
        '(${cabecera['importe'].runtimeType}) numero=${cabecera['numero'].runtimeType} '
        'editable=${cabecera['editable'].runtimeType} fecha=${cabecera['fecha']}',
      );
      expect(cabecera.fsDouble('importe'), 3.2);
      expect(cabecera.fsString('documento'), 'Z-IT-$suffix');

      var partidas = await api.listAll(
        'partidas',
        filters: {'idasiento': created.idasiento},
        sortBy: 'idpartida',
      );
      expect(partidas, hasLength(2));
      expect(partidas.map((p) => p.fsDouble('debe')), containsAll([3.2, 0.0]));

      // Reanudación con el asiento completo: no se toca.
      final same = await service.contabilizarOReanudar(z);
      expect(same.yaExistia, isTrue);
      expect(same.idasiento, created.idasiento);

      // Asiento a medias: se borra una partida a mano y se reanuda.
      expect(
        await api.delete('partidas', partidas.last.fsRequireInt('idpartida')),
        isTrue,
      );
      final recreated = await service.contabilizarOReanudar(z);
      idasiento = recreated.idasiento;
      nota('asiento recreado: $recreated');
      expect(recreated.yaExistia, isFalse);
      expect(recreated.idasiento, isNot(created.idasiento));
      expect(recreated.verificado, isTrue);
      expect(await api.get('asientos', created.idasiento), isNull);

      partidas = await api.listAll(
        'partidas',
        filters: {'idasiento': recreated.idasiento},
        sortBy: 'idpartida',
      );
      expect(partidas, hasLength(2));
      final page = await api.list(
        'asientos',
        filters: {'documento': 'Z-IT-$suffix'},
        limit: 5,
      );
      expect(page.totalCount, 1);
    });
  });
}
