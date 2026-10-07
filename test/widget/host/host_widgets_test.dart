import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/escandallos/presentation/escandallos_page.dart';
import 'package:proyecto_comandero/features/host/presentation/host_home_page.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/catalogo_panel.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/host_formatos.dart';
import 'package:proyecto_comandero/features/host/presentation/widgets/teclado_importe.dart';
import 'package:proyecto_comandero/features/sala/domain/comanda.dart';

import 'support/host_harness.dart';

void main() {
  group('teclearImporte', () {
    test('las cifras entran por la derecha', () {
      var v = 0;
      for (final t in ['1', '2', '5']) {
        v = teclearImporte(v, t);
      }
      expect(v, 125);
      expect(teclearImporte(v, '00'), 12500);
      expect(teclearImporte(v, 'borrar'), 12);
      expect(teclearImporte(v, 'C'), 0);
    });

    test('no supera el máximo y rechaza teclas desconocidas', () {
      expect(teclearImporte(kImporteMaximoCents, '9'), kImporteMaximoCents);
      expect(teclearImporte(kImporteMaximoCents, '00'), kImporteMaximoCents);
      expect(() => teclearImporte(0, 'x'), throwsArgumentError);
      expect(() => teclearImporte(0, '12'), throwsArgumentError);
    });
  });

  test('formatos de hora, duración y porcentaje', () {
    expect(formatHora(DateTime(2026, 10, 7, 9, 5)), '09:05');
    expect(formatFechaHora(DateTime(2026, 1, 2, 13, 0)), '02/01/2026 13:00');
    expect(formatDuracion(const Duration(seconds: 30)), 'ahora');
    expect(formatDuracion(const Duration(minutes: 25)), '25 min');
    expect(formatDuracion(const Duration(minutes: 65)), '1 h 05 min');
    expect(formatDuracion(const Duration(hours: 50)), '2 d 2 h');
    expect(formatPorcentaje(10), '10 %');
    expect(formatPorcentaje(5.5), '5,5 %');
  });

  test('números del usuario y margen', () {
    expect(parseNumeroUsuario('0,25'), 0.25);
    expect(parseNumeroUsuario(' 3 '), 3);
    expect(parseNumeroUsuario(''), isNull);
    expect(parseNumeroUsuario('abc'), isNull);
    expect(margenSobreNeto(precioNeto: 10, coste: 2.5), 0.75);
    expect(margenSobreNeto(precioNeto: 0, coste: 1), isNull);
    expect(formatMargen(0.92), '92,0 %');
  });

  test('filtrarArticulos: vendibles, por familia, texto y código', () {
    final catalogo = catalogoPrueba();
    final todos = filtrarArticulos(catalogo).map((a) => a.referencia);
    expect(todos, isNot(contains('VIEJO')));
    expect(
      filtrarArticulos(catalogo, codfamilia: 'COM').map((a) => a.referencia),
      ['PAELLA'],
    );
    expect(filtrarArticulos(catalogo, texto: 'caf').map((a) => a.referencia), [
      'CAFE',
    ]);
  });

  test('estadoDeMesa', () {
    final abierta = Comanda(id: 'c', mesaId: 'm1', abiertaEn: DateTime(2026));
    expect(estadoDeMesa(null), EstadoMesa.libre);
    expect(estadoDeMesa(abierta), EstadoMesa.ocupada);
    expect(
      estadoDeMesa(abierta.copyWith(cuentaSolicitada: true)),
      EstadoMesa.cuenta,
    );
  });

  testWidgets('el teclado notifica el nuevo importe', (tester) async {
    var valor = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => TecladoImporte(
              valorCents: valor,
              onChanged: (v) => setState(() => valor = v),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('tecla-7')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('tecla-00')));
    await tester.pump();
    expect(valor, 700);
    await tester.tap(find.byKey(const Key('tecla-borrar')));
    await tester.pump();
    expect(valor, 70);
  });
}
