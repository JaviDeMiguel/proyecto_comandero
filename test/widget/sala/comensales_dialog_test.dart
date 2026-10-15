import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/sala/presentation/comensales_dialog.dart';

const mensajeError = 'Indica un número entre 1 y 99';

/// Monta una página con un botón que abre el diálogo, lo abre y devuelve el
/// futuro con su resultado.
Future<Future<int?>> abrir(WidgetTester tester, {int? inicial}) async {
  late Future<int?> resultado;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                resultado = pedirComensales(context, inicial: inicial),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('abrir'));
  await tester.pumpAndSettle();
  return resultado;
}

Finder campo() => find.byKey(const Key('comensales-campo'));

Finder aceptar() => find.byKey(const Key('comensales-aceptar'));

bool aceptarActivo(WidgetTester tester) =>
    tester.widget<FilledButton>(aceptar()).onPressed != null;

void main() {
  group('parsearComensales', () {
    test('acepta enteros de 1 a 99 y recorta espacios', () {
      expect(parsearComensales('1'), 1);
      expect(parsearComensales(' 42 '), 42);
      expect(parsearComensales('99'), 99);
    });

    test('rechaza vacío, cero, negativos, más de 99 y lo que no es número', () {
      expect(parsearComensales(''), isNull);
      expect(parsearComensales('0'), isNull);
      expect(parsearComensales('-3'), isNull);
      expect(parsearComensales('100'), isNull);
      expect(parsearComensales('4,5'), isNull);
      expect(parsearComensales('dos'), isNull);
      // `int.tryParse` aceptaría el signo y el prefijo hexadecimal.
      expect(parsearComensales('+5'), isNull);
      expect(parsearComensales('0x5'), isNull);
      expect(parsearComensales('0x63'), isNull);
    });
  });

  group('pedirComensales', () {
    testWidgets('muestra el valor inicial en el campo y resalta su tecla', (
      tester,
    ) async {
      final resultado = await abrir(tester, inicial: 4);

      expect(find.text('Comensales'), findsOneWidget);
      expect(tester.widget<TextField>(campo()).controller?.text, '4');
      expect(
        tester.widget(find.byKey(const Key('comensales-4'))),
        isA<FilledButton>(),
      );
      expect(
        tester.widget(find.byKey(const Key('comensales-5'))),
        isA<OutlinedButton>(),
      );
      expect(aceptarActivo(tester), isTrue);

      await tester.tap(aceptar());
      await tester.pumpAndSettle();

      expect(await resultado, 4);
    });

    testWidgets('sin valor inicial el campo está vacío y «Aceptar» inactivo', (
      tester,
    ) async {
      await abrir(tester);

      expect(tester.widget<TextField>(campo()).controller?.text, isEmpty);
      expect(find.byType(FilledButton), findsOneWidget); // solo «Aceptar»
      expect(aceptarActivo(tester), isFalse);
      expect(find.text(mensajeError), findsNothing);
    });

    testWidgets('un valor inicial fuera de rango se ignora', (tester) async {
      await abrir(tester, inicial: 0);

      expect(tester.widget<TextField>(campo()).controller?.text, isEmpty);
      expect(aceptarActivo(tester), isFalse);
    });

    testWidgets('la rejilla devuelve el número al instante', (tester) async {
      final resultado = await abrir(tester, inicial: 2);

      await tester.tap(find.byKey(const Key('comensales-6')));
      await tester.pumpAndSettle();

      expect(await resultado, 6);
      expect(find.text('Comensales'), findsNothing);
    });

    testWidgets('valida vacío, cero, negativo y más de 99', (tester) async {
      await abrir(tester, inicial: 3);

      Future<void> escribir(String texto) async {
        await tester.enterText(campo(), texto);
        await tester.pump();
      }

      await escribir('');
      expect(aceptarActivo(tester), isFalse);
      expect(find.text(mensajeError), findsNothing);

      await escribir('0');
      expect(aceptarActivo(tester), isFalse);
      expect(find.text(mensajeError), findsOneWidget);

      await escribir('-2');
      expect(aceptarActivo(tester), isFalse);
      expect(find.text(mensajeError), findsOneWidget);

      await escribir('100');
      expect(aceptarActivo(tester), isFalse);
      expect(find.text(mensajeError), findsOneWidget);

      await escribir('12');
      expect(aceptarActivo(tester), isTrue);
      expect(find.text(mensajeError), findsNothing);
      expect(
        tester.widget(find.byKey(const Key('comensales-12'))),
        isA<FilledButton>(),
      );
    });

    testWidgets('aceptar devuelve el entero del campo', (tester) async {
      final resultado = await abrir(tester);

      await tester.enterText(campo(), '15');
      await tester.pump();
      await tester.tap(aceptar());
      await tester.pumpAndSettle();

      expect(await resultado, 15);
    });

    testWidgets('intro en el campo acepta si el valor es válido', (
      tester,
    ) async {
      final resultado = await abrir(tester);

      await tester.enterText(campo(), '8');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(await resultado, 8);
    });

    testWidgets('cancelar devuelve null', (tester) async {
      final resultado = await abrir(tester, inicial: 5);

      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      expect(await resultado, isNull);
      expect(find.text('Comensales'), findsNothing);
    });
  });
}
