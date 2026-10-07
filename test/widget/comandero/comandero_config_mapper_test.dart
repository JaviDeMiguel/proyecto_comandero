import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/comandero/domain/comandero_config.dart';
import 'package:proyecto_comandero/features/comandero/presentation/comandero_config_mapper.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';

void main() {
  group('comanderoConfigFromApp', () {
    test('copia identidad, emparejamiento, host manual y puerto UDP', () {
      final ajustes =
          AppSettings.defaults(
            deviceId: 'dev-9',
            deviceName: 'Terraza',
          ).copyWith(
            red: const NetworkSettings(
              discoveryPort: 5041,
              pairingCode: '1234',
              hostManual: '10.0.0.5:4040',
            ),
          );

      final config = comanderoConfigFromApp(ajustes, appVersion: '1.2.0');

      expect(
        config,
        const ComanderoConfig(
          deviceId: 'dev-9',
          deviceName: 'Terraza',
          appVersion: '1.2.0',
          pairingCode: '1234',
          hostManual: '10.0.0.5:4040',
          discoveryPort: 5041,
        ),
      );
      expect(config.identity.deviceId, 'dev-9');
    });

    test('trata los textos vacíos como ausentes', () {
      final ajustes = AppSettings.defaults(
        deviceId: 'dev-1',
        deviceName: 'Móvil',
      ).copyWith(red: const NetworkSettings(pairingCode: '  '));

      final config = comanderoConfigFromApp(ajustes);

      expect(config.pairingCode, isNull);
      expect(config.hostManual, isNull);
      expect(config.discoveryPort, NetworkSettings.defaultDiscoveryPort);
    });

    test('mapea el enrutamiento de los ajustes de impresión', () {
      final base = AppSettings.defaults(deviceId: 'dev-1', deviceName: 'M');
      expect(comanderoConfigFromApp(base).destinoPorFamilia, isEmpty);
      expect(
        comanderoConfigFromApp(base).destinoPorDefecto,
        DestinoPreparacion.cocina,
      );

      const enrutamiento = EnrutamientoComandas(
        porFamilia: {'BEB': DestinoPreparacion.barra},
        porDefecto: DestinoPreparacion.barra,
      );
      final config = comanderoConfigFromApp(
        base.copyWith(
          impresion: base.impresion.copyWith(enrutamiento: enrutamiento),
        ),
      );
      expect(config.destinoPorFamilia, {'BEB': DestinoPreparacion.barra});
      expect(config.destinoPorDefecto, DestinoPreparacion.barra);
      expect(config.enrutamiento, enrutamiento);
    });
  });

  test('identidadComandero no cambia con el enrutamiento local', () {
    const a = ComanderoConfig(
      deviceId: 'd',
      deviceName: 'n',
      destinoPorFamilia: {'BEB': DestinoPreparacion.barra},
      destinoPorDefecto: DestinoPreparacion.barra,
    );
    const b = ComanderoConfig(deviceId: 'd', deviceName: 'n');
    expect(identidadComandero(a), identidadComandero(b));
  });

  test('identidadComandero ignora el código y el host manual', () {
    const a = ComanderoConfig(
      deviceId: 'd',
      deviceName: 'n',
      pairingCode: '1',
      hostManual: '1.2.3.4:4040',
    );
    const b = ComanderoConfig(deviceId: 'd', deviceName: 'n');

    expect(identidadComandero(a), identidadComandero(b));
    expect(
      identidadComandero(a),
      isNot(identidadComandero(b.copyWith(deviceName: 'otro'))),
    );
  });

  group('normalizarHostManual', () {
    test('añade el puerto por defecto y respeta el indicado', () {
      expect(normalizarHostManual(' 192.168.1.20 '), '192.168.1.20:4040');
      expect(normalizarHostManual('192.168.1.20:5000'), '192.168.1.20:5000');
      expect(normalizarHostManual('[fe80::1]:4040'), '[fe80::1]:4040');
    });

    test('el resultado es aceptado por los ajustes', () {
      final normalizado = normalizarHostManual('caja.local');
      expect(NetworkSettings.parseHostManual(normalizado), (
        host: 'caja.local',
        port: 4040,
      ));
    });

    test('lanza ValidationException si no es válido', () {
      for (final texto in ['', '   ', ':4040', '1.2.3.4:0', '1.2.3.4:abc']) {
        expect(
          () => normalizarHostManual(texto),
          throwsA(isA<ValidationException>()),
          reason: texto,
        );
      }
    });
  });
}
