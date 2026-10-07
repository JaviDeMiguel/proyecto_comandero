import 'dart:convert';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:test/test.dart';

Map<String, Object?> ida(Map<String, Object?> json) =>
    (jsonDecode(jsonEncode(json)) as Map).cast<String, Object?>();

void main() {
  const bebidasABarra = EnrutamientoComandas(
    porFamilia: {'BEB': DestinoPreparacion.barra},
    porDefecto: DestinoPreparacion.cocina,
  );

  group('PrintingSettings.enrutamiento', () {
    test('por defecto todo a cocina', () {
      expect(
        const PrintingSettings().enrutamiento,
        const EnrutamientoComandas(),
      );
    });

    test('ajustes guardados sin enrutamiento (versión anterior) cargan con '
        'el defecto', () {
      final antiguo = {
        'cocina': {'host': '10.0.0.10', 'port': 9100},
        'paper': 'mm58',
        'imprimirComandaCocina': true,
      };
      final leido = PrintingSettings.fromJson(antiguo);
      expect(leido.enrutamiento, const EnrutamientoComandas());
      expect(leido.cocina, PrinterEndpoint('10.0.0.10'));
      expect(leido.paper, PaperWidth.mm58);
    });

    test('ida y vuelta con enrutamiento', () {
      final ajustes = const PrintingSettings().copyWith(
        enrutamiento: bebidasABarra,
      );
      final json = ida(ajustes.toJson());
      expect(json['enrutamiento'], {
        'porDefecto': 'cocina',
        'porFamilia': {'BEB': 'barra'},
      });
      expect(PrintingSettings.fromJson(json), ajustes);
    });

    test('copyWith conserva el enrutamiento al cambiar otras cosas', () {
      final ajustes = const PrintingSettings().copyWith(
        enrutamiento: bebidasABarra,
      );
      final cambiado = ajustes.copyWith(
        cocina: PrinterEndpoint('10.0.0.10'),
        abrirCajon: false,
      );
      expect(cambiado.enrutamiento, bebidasABarra);
      expect(cambiado == ajustes, isFalse);
      expect(
        ajustes.copyWith(enrutamiento: const EnrutamientoComandas()) ==
            const PrintingSettings(),
        isTrue,
      );
    });
  });

  group('AppSettings con enrutamiento', () {
    AppSettings base() =>
        const AppSettings(deviceId: 'tablet-1', deviceName: 'Tablet');

    test('JSON con enrutamiento', () {
      final ajustes = base().copyWith(
        impresion: base().impresion.copyWith(enrutamiento: bebidasABarra),
      );
      final leido = AppSettings.fromJson(ida(ajustes.toJson()));
      expect(leido.impresion.enrutamiento, bebidasABarra);
      expect(leido, ajustes);
    });

    test('JSON sin enrutamiento (ni sección de impresión) usa el defecto', () {
      final json = ida(base().toJson());
      (json['impresion']! as Map<String, Object?>).remove('enrutamiento');
      expect(
        AppSettings.fromJson(json).impresion.enrutamiento,
        const EnrutamientoComandas(),
      );
      json.remove('impresion');
      expect(
        AppSettings.fromJson(json).impresion.enrutamiento,
        const EnrutamientoComandas(),
      );
    });

    test('un enrutamiento inválido es un error de configuración de la '
        'sección impresión', () {
      final json = ida(base().toJson());
      (json['impresion']! as Map<String, Object?>)['enrutamiento'] = {
        'porDefecto': 'terraza',
      };
      expect(
        () => AppSettings.fromJson(json),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('impresion'), contains('terraza')),
          ),
        ),
      );
    });
  });
}
