import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/sala/domain/pases.dart';
import 'package:proyecto_comandero/features/sala/presentation/selector_pase.dart';

const pases = PasesConfig(nombres: ['Primeros', 'Segundos', 'Postres']);

Future<void> montar(WidgetTester tester, Widget selector) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: selector)));
}

ChoiceChip chip(WidgetTester tester, String clave) =>
    tester.widget<ChoiceChip>(find.byKey(Key(clave)));

void main() {
  group('SelectorPase', () {
    testWidgets('muestra «Directo» y los pases configurados con sus claves', (
      tester,
    ) async {
      await montar(
        tester,
        SelectorPase(pases: pases, seleccionado: null, onCambio: (_) {}),
      );

      expect(find.text('Directo'), findsOneWidget);
      expect(find.text('1. Primeros'), findsOneWidget);
      expect(find.text('2. Segundos'), findsOneWidget);
      expect(find.text('3. Postres'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(4));
      expect(find.byKey(const Key('pase-directo')), findsOneWidget);
      for (var n = 1; n <= 3; n++) {
        expect(find.byKey(Key('pase-$n')), findsOneWidget);
      }
      expect(chip(tester, 'pase-directo').selected, isTrue);
      expect(chip(tester, 'pase-1').selected, isFalse);
    });

    testWidgets('marca el seleccionado y notifica el cambio', (tester) async {
      final cambios = <int?>[];
      await montar(
        tester,
        SelectorPase(pases: pases, seleccionado: 2, onCambio: cambios.add),
      );

      expect(chip(tester, 'pase-2').selected, isTrue);
      expect(chip(tester, 'pase-directo').selected, isFalse);

      await tester.tap(find.byKey(const Key('pase-3')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pase-directo')));
      await tester.pump();

      expect(cambios, [3, null]);
    });

    testWidgets('la selección se mueve cuando el padre aplica el cambio', (
      tester,
    ) async {
      int? seleccionado = 1;
      await montar(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SelectorPase(
            pases: pases,
            seleccionado: seleccionado,
            onCambio: (pase) => setState(() => seleccionado = pase),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('pase-3')));
      await tester.pump();

      expect(seleccionado, 3);
      expect(chip(tester, 'pase-3').selected, isTrue);
      expect(chip(tester, 'pase-1').selected, isFalse);
    });

    testWidgets('un pase fuera de la configuración se rotula «n. Pase n»', (
      tester,
    ) async {
      await montar(
        tester,
        SelectorPase(pases: pases, seleccionado: 7, onCambio: (_) {}),
      );

      expect(find.text('7. Pase 7'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(5));
      expect(chip(tester, 'pase-7').selected, isTrue);
      expect(chip(tester, 'pase-directo').selected, isFalse);
    });

    testWidgets('no pinta nada con los pases desactivados', (tester) async {
      await montar(
        tester,
        SelectorPase(
          pases: const PasesConfig(activos: false),
          seleccionado: 2,
          onCambio: (_) {},
        ),
      );

      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Directo'), findsNothing);
      expect(find.text('Pase:'), findsNothing);
    });

    testWidgets('en modo compacto muestra solo los nombres', (tester) async {
      await montar(
        tester,
        SelectorPase(
          pases: pases,
          seleccionado: 9,
          onCambio: (_) {},
          compacto: true,
        ),
      );

      expect(find.text('Directo'), findsOneWidget);
      expect(find.text('Primeros'), findsOneWidget);
      expect(find.text('1. Primeros'), findsNothing);
      expect(find.text('Pase 9'), findsOneWidget);
      expect(find.byKey(const Key('pase-9')), findsOneWidget);
    });
  });
}
