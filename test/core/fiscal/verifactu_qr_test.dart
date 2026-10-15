import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/fiscal/verifactu_qr.dart';
import 'package:test/test.dart';

/// Consulta de los ejemplos de §6.3: NIF `B12345678`, serie `F2026S12`,
/// fecha 09-10-2026 e importe 67,00 €.
const String _consulta =
    'nif=B12345678&numserie=F2026S12&fecha=09-10-2026&importe=67.00';

QrTributario _qr({
  String nif = 'B12345678',
  String numSerie = 'F2026S12',
  DateTime? fecha,
  int importeCents = 6700,
  bool verifactu = true,
  bool pruebas = false,
}) => QrTributario(
  nif: nif,
  numSerie: numSerie,
  fecha: fecha ?? DateTime(2026, 10, 9),
  importeCents: importeCents,
  verifactu: verifactu,
  pruebas: pruebas,
);

Matcher _validacion(String fragmento) => throwsA(
  isA<ValidationException>().having(
    (e) => e.message,
    'message',
    contains(fragmento),
  ),
);

void main() {
  group('QrTributario.url', () {
    test('producción VERI*FACTU', () {
      expect(
        _qr().url,
        'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR'
        '?$_consulta',
      );
    });

    test('producción NO VERI*FACTU', () {
      expect(
        _qr(verifactu: false).url,
        'https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/'
        'ValidarQRNoVerifactu?$_consulta',
      );
    });

    test('pruebas VERI*FACTU', () {
      expect(
        _qr(pruebas: true).url,
        'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?$_consulta',
      );
    });

    test('pruebas NO VERI*FACTU', () {
      expect(
        _qr(verifactu: false, pruebas: true).url,
        'https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQRNoVerifactu'
        '?$_consulta',
      );
    });

    test('las bases no llevan barra final y son las de la AEAT', () {
      expect(_qr().base, urlBaseVerifactuProduccion);
      expect(_qr(verifactu: false).base, urlBaseNoVerifactuProduccion);
      expect(_qr(pruebas: true).base, urlBaseVerifactuPruebas);
      expect(
        _qr(verifactu: false, pruebas: true).base,
        urlBaseNoVerifactuPruebas,
      );
      expect(urlBaseNoVerifactuProduccion, endsWith('/ValidarQRNoVerifactu'));
      expect(urlBaseVerifactuPruebas, endsWith('/ValidarQR'));
    });

    test('exactamente cuatro parámetros, en orden y sin idioma', () {
      final uri = Uri.parse(_qr(numSerie: 'F 2026/12').url);
      final claves = uri.query
          .split('&')
          .map((parametro) => parametro.split('=').first)
          .toList();
      expect(claves, ['nif', 'numserie', 'fecha', 'importe']);
      expect(uri.queryParameters, {
        'nif': 'B12345678',
        'numserie': 'F 2026/12',
        'fecha': '09-10-2026',
        'importe': '67.00',
      });
      expect(_qr().parametros.keys.toList(), [
        'nif',
        'numserie',
        'fecha',
        'importe',
      ]);
    });

    test('numserie codificada: espacio → + y / → %2F', () {
      expect(
        _qr(numSerie: 'F 2026/12').url,
        endsWith(
          '?nif=B12345678&numserie=F+2026%2F12&fecha=09-10-2026&importe=67.00',
        ),
      );
      expect(_qr(numSerie: 'A&B=C').url, contains('&numserie=A%26B%3DC&'));
    });

    test('fecha en DD-MM-AAAA, sin la hora', () {
      expect(
        _qr(fecha: DateTime(2026, 1, 5, 23, 59, 58)).url,
        contains('&fecha=05-01-2026&'),
      );
      expect(_qr(fecha: DateTime(2026, 1, 5)).fechaTexto, '05-01-2026');
      expect(_qr(fecha: DateTime(2026, 12, 31)).fechaTexto, '31-12-2026');
    });

    test('importe con punto decimal y dos decimales', () {
      expect(_qr(importeCents: 6700).url, endsWith('&importe=67.00'));
      expect(_qr(importeCents: 5).url, endsWith('&importe=0.05'));
      expect(_qr(importeCents: -320).url, endsWith('&importe=-3.20'));
    });

    test('admite 12 dígitos enteros', () {
      expect(
        _qr(importeCents: importeQrMaximoCents).url,
        endsWith('&importe=999999999999.99'),
      );
      expect(
        _qr(importeCents: -importeQrMaximoCents).importeTexto,
        '-999999999999.99',
      );
    });

    test('el NIF va normalizado', () {
      expect(_qr(nif: 'es b-1234567-8').url, contains('?nif=B12345678&'));
      expect(_qr(nif: 'es b-1234567-8').nif, 'B12345678');
    });
  });

  group('importeQr', () {
    test('punto decimal, dos decimales y signo', () {
      expect(importeQr(6700), '67.00');
      expect(importeQr(5), '0.05');
      expect(importeQr(-320), '-3.20');
      expect(importeQr(0), '0.00');
      expect(importeQr(-5), '-0.05');
      expect(importeQr(123456), '1234.56');
      expect(importeQr(100), '1.00');
    });
  });

  group('normalizarNif', () {
    test('mayúsculas y sin espacios, guiones, puntos ni barras', () {
      expect(normalizarNif('b-1234567-8'), 'B12345678');
      expect(normalizarNif(' 12345678z '), '12345678Z');
      expect(normalizarNif('B.12.345.678'), 'B12345678');
      expect(normalizarNif('B12/345/678'), 'B12345678');
      expect(normalizarNif('B 12 345 678'), 'B12345678');
    });

    test('quita el prefijo ES solo si quedan 11 caracteres', () {
      expect(normalizarNif('ES B12345678'), 'B12345678');
      expect(normalizarNif('ESB12345678'), 'B12345678');
      expect(normalizarNif('es-b12345678'), 'B12345678');
      // 9 caracteres: no es un prefijo, es parte del NIF.
      expect(normalizarNif('ES1234567'), 'ES1234567');
      // 10 caracteres: se deja tal cual (y la validación lo rechaza).
      expect(normalizarNif('ESB1234567'), 'ESB1234567');
    });
  });

  group('errores de validación', () {
    test('NIF de 8 caracteres', () {
      expect(() => _qr(nif: 'B1234567'), _validacion('9 letras o cifras'));
    });

    test('NIF con símbolos o letras no ASCII', () {
      expect(() => _qr(nif: 'B1234567*'), _validacion('NIF'));
      expect(() => _qr(nif: 'B123456Ñ8'), _validacion('NIF'));
      expect(() => _qr(nif: 'B1234_678'), _validacion('NIF'));
    });

    test('NIF de 10 caracteres o vacío', () {
      expect(() => _qr(nif: 'B123456789'), _validacion('NIF'));
      expect(() => _qr(nif: ''), _validacion('NIF'));
      expect(() => _qr(nif: ' - '), _validacion('NIF'));
    });

    test('serie vacía', () {
      expect(() => _qr(numSerie: ''), _validacion('vacío'));
    });

    test('serie de más de 60 caracteres', () {
      expect(() => _qr(numSerie: 'A' * 61), _validacion('60'));
      expect(_qr(numSerie: 'A' * 60).numSerie.length, 60);
    });

    test('serie con caracteres fuera de ASCII imprimible', () {
      expect(() => _qr(numSerie: 'F2026Ñ12'), _validacion('ASCII'));
      expect(() => _qr(numSerie: 'F2026€12'), _validacion('ASCII'));
      expect(() => _qr(numSerie: 'F2026\t12'), _validacion('ASCII'));
      expect(() => _qr(numSerie: 'F2026\u007F12'), _validacion('ASCII'));
      // Los límites 0x20 y 0x7E sí se admiten.
      expect(_qr(numSerie: ' F2026~12').numSerie, ' F2026~12');
    });

    test('importe fuera de rango', () {
      expect(
        () => _qr(importeCents: importeQrMaximoCents + 1),
        _validacion('12 dígitos'),
      );
      expect(
        () => _qr(importeCents: -(importeQrMaximoCents + 1)),
        _validacion('12 dígitos'),
      );
    });

    test('segunAjustes valida igual que el constructor', () {
      expect(
        () => QrTributario.segunAjustes(
          modo: ModoQrVerifactu.verifactu,
          entorno: EntornoVerifactu.produccion,
          nif: 'B1234567',
          numSerie: 'F2026S12',
          fecha: DateTime(2026, 10, 9),
          importeCents: 6700,
        ),
        _validacion('NIF'),
      );
    });
  });

  group('leyenda', () {
    test('solo en VERI*FACTU, en cualquier entorno', () {
      expect(_qr().leyenda, 'VERI*FACTU');
      expect(_qr(pruebas: true).leyenda, 'VERI*FACTU');
      expect(_qr(verifactu: false).leyenda, isNull);
      expect(_qr(verifactu: false, pruebas: true).leyenda, isNull);
      expect(leyendaVerifactu, 'VERI*FACTU');
    });
  });

  group('segunAjustes', () {
    QrTributario? segun(ModoQrVerifactu modo, EntornoVerifactu entorno) =>
        QrTributario.segunAjustes(
          modo: modo,
          entorno: entorno,
          nif: 'B12345678',
          numSerie: 'F2026S12',
          fecha: DateTime(2026, 10, 9),
          importeCents: 6700,
        );

    test('desactivado → null, en ambos entornos', () {
      expect(
        segun(ModoQrVerifactu.desactivado, EntornoVerifactu.produccion),
        isNull,
      );
      expect(
        segun(ModoQrVerifactu.desactivado, EntornoVerifactu.pruebas),
        isNull,
      );
    });

    test('verifactu + produccion', () {
      final qr = segun(ModoQrVerifactu.verifactu, EntornoVerifactu.produccion);
      expect(qr, _qr());
      expect(qr?.modo, ModoQrVerifactu.verifactu);
      expect(qr?.entorno, EntornoVerifactu.produccion);
      expect(qr?.leyenda, 'VERI*FACTU');
      expect(qr?.url, startsWith(urlBaseVerifactuProduccion));
    });

    test('noVerifactu + pruebas', () {
      final qr = segun(ModoQrVerifactu.noVerifactu, EntornoVerifactu.pruebas);
      expect(qr, _qr(verifactu: false, pruebas: true));
      expect(qr?.modo, ModoQrVerifactu.noVerifactu);
      expect(qr?.entorno, EntornoVerifactu.pruebas);
      expect(qr?.leyenda, isNull);
      expect(qr?.url, startsWith(urlBaseNoVerifactuPruebas));
    });
  });

  group('igualdad', () {
    test('por valor, con el NIF normalizado y la fecha truncada al día', () {
      expect(
        _qr(nif: 'b-1234567-8', fecha: DateTime(2026, 10, 9, 13, 45, 7)),
        _qr(),
      );
      expect(_qr().hashCode, _qr().hashCode);
      expect(_qr().fecha, DateTime(2026, 10, 9));
      expect(_qr(), isNot(_qr(importeCents: 6701)));
      expect(_qr(), isNot(_qr(numSerie: 'F2026S13')));
      expect(_qr(), isNot(_qr(fecha: DateTime(2026, 10, 10))));
      expect(_qr(), isNot(_qr(verifactu: false)));
      expect(_qr(), isNot(_qr(pruebas: true)));
    });
  });
}
