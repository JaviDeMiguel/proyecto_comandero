import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_form.dart';

void main() {
  group('importes y números', () {
    test('parseImporteCents acepta coma o punto y hasta dos decimales', () {
      expect(parseImporteCents('150'), 15000);
      expect(parseImporteCents('150,5'), 15050);
      expect(parseImporteCents(' 0.05 '), 5);
      expect(parseImporteCents('12,345'), isNull);
      expect(parseImporteCents('-1'), isNull);
      expect(parseImporteCents('abc'), isNull);
      expect(parseImporteCents('99999999'), isNull);
    });

    test('formatImporteEditable es el inverso', () {
      expect(formatImporteEditable(15050), '150,50');
      expect(formatImporteEditable(5), '0,05');
      expect(parseImporteCents(formatImporteEditable(123456)), 123456);
    });

    test('decimales de la reposición', () {
      expect(parseDecimal('2,5'), 2.5);
      expect(parseDecimal('1e3'), isNull);
      expect(formatDecimalEditable(2), '2');
      expect(formatDecimalEditable(0.25), '0,25');
      expect(validarFactor('0,5'), 'Entre 1 y 100');
      expect(validarMultiplo('0,001'), isNull);
      expect(validarMultiplo('0'), 'Entre 0,001 y 10000');
    });
  });

  group('validadores', () {
    test('puertos, códigos y subcuentas', () {
      expect(validarPuerto('4040'), isNull);
      expect(validarPuerto('0'), 'Puerto entre 1 y 65535');
      expect(validarPuerto(''), 'Obligatorio');
      expect(validarCodigo('S'), isNull);
      expect(validarCodigo('A B'), 'Sin espacios');
      expect(validarCodigo('', opcional: true), isNull);
      expect(validarSubcuenta('5700000000'), isNull);
      expect(validarSubcuenta('57a'), 'Solo dígitos (4 a 15)');
      expect(validarPairingCode('12'), 'Entre 4 y 32 caracteres');
      expect(validarPairingCode(''), isNull);
      expect(validarEnteroPositivoOpcional('0'), 'Número entero mayor que 0');
    });

    test('URL del ERP', () {
      expect(validarUrlErp('http://192.168.1.10/facturascripts'), isNull);
      expect(validarUrlErp('https://erp.local/api/3'), isNull);
      expect(validarUrlErp('erp.local'), isNotNull);
      expect(validarUrlErp(''), 'Obligatorio');
    });
  });

  group('direcciones', () {
    test('host manual: puerto por defecto, IPv6 y errores', () {
      expect(normalizarDireccionHost('192.168.1.5'), '192.168.1.5:4040');
      expect(normalizarDireccionHost('tablet.local:5000'), 'tablet.local:5000');
      expect(normalizarDireccionHost('[fe80::1]:4040'), '[fe80::1]:4040');
      expect(normalizarDireccionHost('fe80::1'), '[fe80::1]:4040');
      expect(
        () => normalizarDireccionHost('host:99999'),
        throwsA(isA<ValidationException>()),
      );
      expect(validarHostManual('a b'), 'La dirección no puede tener espacios');
      // El formato guardado lo acepta el dominio de ajustes.
      expect(
        NetworkSettings.parseHostManual(normalizarDireccionHost('fe80::1')),
        (host: 'fe80::1', port: 4040),
      );
    });

    test('impresoras: 9100 por defecto y vacío = sin impresora', () {
      expect(parseImpresora(''), isNull);
      expect(parseImpresora('10.0.0.9'), PrinterEndpoint('10.0.0.9'));
      expect(
        parseImpresora('10.0.0.9:9101'),
        PrinterEndpoint('10.0.0.9', port: 9101),
      );
      expect(formatImpresora(PrinterEndpoint('10.0.0.9')), '10.0.0.9:9100');
      expect(validarImpresora('10.0.0.9:'), 'Puerto entre 1 y 65535');
    });
  });

  group('mesas', () {
    final porDefecto = AppSettings.mesasPorDefecto();

    test('zonasDe agrupa en orden de aparición', () {
      expect(zonasDe(porDefecto), const [
        ZonaMesas(zona: 'Barra', cantidad: 1),
        ZonaMesas(zona: 'Salón', cantidad: 12),
      ]);
    });

    test('sin cambios devuelve las mismas mesas', () {
      expect(mesasDesdeZonas(zonasDe(porDefecto), porDefecto), porDefecto);
    });

    test('añadir conserva ids y nombres; quitar elimina las últimas', () {
      final mas = mesasDesdeZonas(const [
        ZonaMesas(zona: 'Barra', cantidad: 3),
        ZonaMesas(zona: 'Salón', cantidad: 10),
        ZonaMesas(zona: 'Terraza', cantidad: 2),
      ], porDefecto);
      expect(mas.where((m) => m.zona == 'Barra').map((m) => m.nombre), [
        'Barra',
        'Barra 2',
        'Barra 3',
      ]);
      expect(mas.where((m) => m.zona == 'Salón').map((m) => m.id), [
        for (var i = 1; i <= 10; i++) 'mesa-$i',
      ]);
      final terraza = mas.where((m) => m.zona == 'Terraza').toList();
      expect(terraza.map((m) => m.nombre), ['Terraza 1', 'Terraza 2']);
      expect(terraza.map((m) => m.id), ['terraza-1', 'terraza-2']);
      expect(mas.map((m) => m.id).toSet(), hasLength(mas.length));
      expect(mesasQuitadas(porDefecto, mas).map((m) => m.id), [
        'mesa-11',
        'mesa-12',
      ]);
    });

    test('validarZonas', () {
      expect(validarZonas(zonasDe(porDefecto)), isNull);
      expect(
        validarZonas(const [ZonaMesas(zona: 'Salón', cantidad: 0)]),
        'Configura al menos una mesa',
      );
      expect(
        validarZonas(const [
          ZonaMesas(zona: 'Salón', cantidad: 1),
          ZonaMesas(zona: 'salón', cantidad: 1),
        ]),
        "La zona 'salón' está repetida",
      );
      expect(
        validarZonas(const [ZonaMesas(zona: ' ', cantidad: 1)]),
        'Hay una zona sin nombre',
      );
    });
  });

  group('resumirCambios', () {
    final host = AppSettings.defaults(
      deviceId: 'd',
      deviceName: 'Tablet',
    ).copyWith(rol: DeviceRole.host);

    test('sin cambios no hay avisos ni reinicio', () {
      expect(resumirCambios(host, host), const ResumenCambios());
    });

    test('puertos, emparejamiento, ERP y rol', () {
      final despues = host.copyWith(
        red: host.red.copyWith(tcpPort: 5000, pairingCode: '1234'),
        fsApi: FsApiConfig(baseUrl: 'http://erp', token: 't'),
      );
      final resumen = resumirCambios(host, despues);
      expect(resumen.requiereReinicio, isFalse);
      expect(resumen.avisos, hasLength(3));

      final comandero = resumirCambios(
        host,
        host.copyWith(rol: DeviceRole.comandero),
      );
      expect(comandero.avisos, [
        'El dispositivo pasa a funcionar como Comandero.',
      ]);
    });
  });
}
