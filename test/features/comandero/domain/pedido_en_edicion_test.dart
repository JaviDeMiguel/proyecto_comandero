import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/facturascripts/catalog/catalog_models.dart';
import 'package:proyecto_comandero/core/network/tcp/tcp_comandero_client.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/domain/pedido_en_edicion.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:test/test.dart';

import '../fake_sala_host.dart';

void main() {
  final cana = kCatalogoPrueba.porReferencia('CANA')!;
  final paella = kCatalogoPrueba.porReferencia('PAELLA')!;
  final bloqueado = kCatalogoPrueba.porReferencia('BLOQ')!;

  group('PedidoEnEdicion', () {
    test('añadir acumula el mismo artículo con la misma nota', () {
      var pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1', cantidad: 2)
          .conArticulo(cana, nuevoId: () => 'l2')
          .conArticulo(cana, nuevoId: () => 'l3', nota: 'sin espuma')
          .conArticulo(paella, nuevoId: () => 'l4', cantidad: 0.5);
      expect(pedido.lineas.map((l) => l.id), ['l1', 'l3', 'l4']);
      expect(pedido.lineaPorId('l1')!.cantidad, 3);
      expect(pedido.lineaPorId('l3')!.nota, 'sin espuma');
      // 3 × 2,00 + 1 × 2,00 + 0,5 × 12,00
      expect(pedido.importeCents, 600 + 200 + 600);
      expect(pedido.unidades, 4.5);

      pedido = pedido.conCantidad('l1', 1).sinLinea('l3');
      expect(pedido.importeCents, 200 + 600);
      expect(pedido.lineas.length, 2);
    });

    test('rechaza cantidades inválidas y artículos no vendibles', () {
      final vacio = PedidoEnEdicion.vacio('m1');
      expect(
        () => vacio.conArticulo(cana, nuevoId: () => 'x', cantidad: 0),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => vacio.conArticulo(cana, nuevoId: () => 'x', cantidad: double.nan),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => vacio.conArticulo(bloqueado, nuevoId: () => 'x'),
        throwsA(isA<ValidationException>()),
      );
      final uno = vacio.conArticulo(cana, nuevoId: () => 'l1');
      expect(
        () => uno.conCantidad('l1', -1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => uno.conCantidad('no-existe', 1),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => uno.sinLinea('no-existe'),
        throwsA(isA<ValidationException>()),
      );
    });

    test('las líneas en envío no se editan ni agrupan', () {
      final pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .marcandoEnvio({'l1'}, enviando: true);
      expect(pedido.enEnvio.single.id, 'l1');
      expect(pedido.pendientesDeEnviar, isEmpty);
      expect(
        () => pedido.conCantidad('l1', 2),
        throwsA(isA<ValidationException>()),
      );
      expect(() => pedido.sinLinea('l1'), throwsA(isA<ValidationException>()));

      final conOtra = pedido.conArticulo(cana, nuevoId: () => 'l2');
      expect(conOtra.lineas.map((l) => l.id), ['l1', 'l2']);
      expect(conOtra.pendientesDeEnviar.single.id, 'l2');

      final confirmado = conOtra.sinLineas({'l1'});
      expect(confirmado.lineas.map((l) => l.id), ['l2']);
      final devuelto = pedido.marcandoEnvio({'l1'}, enviando: false);
      expect(devuelto.pendientesDeEnviar.single.id, 'l1');
    });

    test('h7: si cambia el precio o el IVA se abre otra línea', () {
      const masCara = ArticuloCatalogo(
        referencia: 'CANA',
        idproducto: 1,
        idvariante: 1,
        descripcion: 'Caña',
        codfamilia: 'BEB',
        codimpuesto: 'IVA10',
        ivaBp: 1000,
        precioNeto: 2.27273,
        pvpCents: 250,
        nostock: true,
      );
      final pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .conArticulo(masCara, nuevoId: () => 'l2');
      expect(pedido.lineas.map((l) => l.id), ['l1', 'l2']);
      expect(pedido.lineaPorId('l1')!.articulo.pvpCents, 200);
      expect(pedido.lineaPorId('l2')!.articulo.pvpCents, 250);
      expect(pedido.importeCents, 450);

      // Otro tipo de IVA con el mismo PVP tampoco se agrupa.
      final otroIva = ArticuloCatalogo(
        referencia: 'CANA',
        idproducto: 1,
        idvariante: 1,
        descripcion: 'Caña',
        codfamilia: 'BEB',
        codimpuesto: 'IVA21',
        ivaBp: 2100,
        precioNeto: 1.65289,
        pvpCents: cana.pvpCents,
        nostock: true,
      );
      expect(
        pedido.conArticulo(otroIva, nuevoId: () => 'l3').lineas,
        hasLength(3),
      );
      // El mismo artículo sin cambios sí se acumula.
      final acumulado = pedido.conArticulo(cana, nuevoId: () => 'l4');
      expect(acumulado.lineaPorId('l1')!.cantidad, 2);
      expect(acumulado.lineas, hasLength(2));
    });

    test('h3: una línea devuelta tras fallo de red se edita con id nuevo', () {
      final pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .marcandoEnvio({'l1'}, enviando: true)
          .devolviendoTrasFalloDeRed({'l1'});
      final devuelta = pedido.lineaPorId('l1')!;
      expect(devuelta.enviando, isFalse);
      expect(devuelta.posiblementeTransmitida, isTrue);
      expect(pedido.pendientesDeEnviar.single.id, 'l1');

      final conCantidad = pedido.conCantidad('l1', 3, nuevoId: () => 'l9');
      expect(conCantidad.lineas.single.id, 'l9');
      expect(conCantidad.lineas.single.reemplazaA, 'l1');
      expect(conCantidad.lineas.single.posiblementeTransmitida, isFalse);
      // Editar la nueva conserva su id (ya no pudo llegar al host).
      expect(
        conCantidad.conCantidad('l9', 4, nuevoId: () => 'zz').lineas.single.id,
        'l9',
      );

      final conNota = pedido.conNota('l1', 'sin espuma');
      expect(conNota.lineas.single.id, isNot('l1'));
      expect(conNota.lineas.single.nota, 'sin espuma');
      expect(conNota.lineas.single.reemplazaA, 'l1');

      // Añadir el mismo artículo no acumula sobre la posiblemente transmitida.
      final otra = pedido.conArticulo(cana, nuevoId: () => 'l2');
      expect(otra.lineas.map((l) => l.id), ['l1', 'l2']);
      expect(otra.lineaPorId('l1')!.cantidad, 1);
    });

    test('u3: conCantidadYNota edita una línea devuelta con un solo id '
        'nuevo', () {
      final pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .marcandoEnvio({'l1'}, enviando: true)
          .devolviendoTrasFalloDeRed({'l1'});
      var ids = 0;
      final editado = pedido.conCantidadYNota(
        'l1',
        cantidad: 2,
        nota: ' Sin gluten ',
        nuevoId: () => 'n${++ids}',
      );
      final linea = editado.lineas.single;
      expect(linea.id, 'n1');
      expect(ids, 1);
      expect(linea.cantidad, 2);
      expect(linea.nota, 'Sin gluten');
      expect(linea.reemplazaA, 'l1');
      expect(linea.posiblementeTransmitida, isFalse);

      // Sin cambios no se toca (ni se genera id).
      expect(
        pedido.conCantidadYNota('l1', cantidad: 1, nota: null),
        same(pedido),
      );
      // Una línea normal conserva su id.
      final normal = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'a');
      expect(
        normal.conCantidadYNota('a', cantidad: 3, nota: 'x').lineas.single.id,
        'a',
      );
      expect(
        () => normal.conCantidadYNota('zz', cantidad: 1, nota: null),
        throwsA(isA<ValidationException>()),
      );
    });

    test('u2: fusionando añade las líneas que faltan; las en envío vuelven '
        'como posiblemente transmitidas', () {
      final destino = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1');
      final origen = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .conArticulo(paella, nuevoId: () => 'l2')
          .conArticulo(cana, nuevoId: () => 'l3', nota: 'fría')
          .marcandoEnvio({'l3'}, enviando: true);
      final fusionado = destino.fusionando(origen);
      expect(fusionado.lineas.map((l) => l.id), ['l1', 'l2', 'l3']);
      expect(fusionado.lineaPorId('l3')!.enviando, isFalse);
      expect(fusionado.lineaPorId('l3')!.posiblementeTransmitida, isTrue);
      expect(fusionado.lineaPorId('l2')!.posiblementeTransmitida, isFalse);
      expect(fusionado.fusionando(origen), same(fusionado));
      expect(
        () => destino.fusionando(PedidoEnEdicion.vacio('m2')),
        throwsArgumentError,
      );
    });

    test('h3: sinLineasYaEnHost quita las editables que el host ya tiene', () {
      final pedido = PedidoEnEdicion.vacio('m1')
          .conArticulo(cana, nuevoId: () => 'l1')
          .conArticulo(paella, nuevoId: () => 'l2')
          .conArticulo(cana, nuevoId: () => 'l3', nota: 'fría')
          .marcandoEnvio({'l3'}, enviando: true);
      final depurado = pedido.sinLineasYaEnHost({'l1', 'l3', 'otra'});
      expect(depurado.lineas.map((l) => l.id), ['l2', 'l3']);
    });

    test('aLineaComanda congela precio, IVA e impuesto del catálogo', () {
      final linea = LineaPedido(
        id: 'l1',
        articulo: paella,
        cantidad: 2,
        nota: 'poco hecha',
      );
      final comanda = linea.aLineaComanda(
        creadaEn: DateTime.utc(2026, 10, 7, 13),
        destino: DestinoPreparacion.cocina,
        camarero: 'Ana',
      );
      expect(comanda.id, 'l1');
      expect(comanda.referencia, 'PAELLA');
      expect(comanda.pvpUnitarioCents, 1200);
      expect(comanda.pvpUnitarioNeto, 10.90909);
      expect(comanda.ivaBp, 1000);
      expect(comanda.codimpuesto, 'IVA10');
      expect(comanda.nota, 'poco hecha');
      expect(comanda.camarero, 'Ana');
      expect(comanda.importeCents, 2400);
      expect(comanda.estado, EstadoLinea.enviada);
    });
  });

  group('ComanderoConfig', () {
    test('destinoDe usa la familia o el valor por defecto', () {
      const config = ComanderoConfig(
        deviceId: 'd1',
        deviceName: 'Móvil',
        destinoPorFamilia: {'BEB': DestinoPreparacion.barra},
      );
      expect(config.destinoDe('BEB'), DestinoPreparacion.barra);
      expect(config.destinoDe('PLA'), DestinoPreparacion.cocina);
      expect(config.destinoDe(null), DestinoPreparacion.cocina);
    });

    test('destinoDe hereda por la jerarquía de familias', () {
      const config = ComanderoConfig(
        deviceId: 'd1',
        deviceName: 'Móvil',
        destinoPorFamilia: {'BEB': DestinoPreparacion.barra},
        destinoPorDefecto: DestinoPreparacion.cocina,
      );
      const madreDe = {'CER': 'BEB', 'ART': 'CER'};
      expect(
        config.destinoDe('ART', madreDe: madreDe),
        DestinoPreparacion.barra,
      );
      expect(config.destinoDe('ART'), DestinoPreparacion.cocina);
      expect(config.enrutamiento.porFamilia, {'BEB': DestinoPreparacion.barra});
    });

    test('parseHostEndpoint admite ip, ip:puerto e IPv6', () {
      expect(
        parseHostEndpoint('192.168.1.10'),
        const HostEndpoint(host: '192.168.1.10', port: 4040),
      );
      expect(
        parseHostEndpoint(' 192.168.1.10:5000 '),
        const HostEndpoint(host: '192.168.1.10', port: 5000),
      );
      expect(
        parseHostEndpoint('[fe80::1]:4041'),
        const HostEndpoint(host: 'fe80::1', port: 4041),
      );
      expect(
        parseHostEndpoint('fe80::1'),
        const HostEndpoint(host: 'fe80::1', port: 4040),
      );
      expect(() => parseHostEndpoint(''), throwsFormatException);
      expect(() => parseHostEndpoint('host:0'), throwsFormatException);
      expect(() => parseHostEndpoint('host:abc'), throwsFormatException);
      expect(() => parseHostEndpoint(':4040'), throwsFormatException);
    });
  });
}
