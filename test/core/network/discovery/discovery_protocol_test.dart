import 'dart:convert';
import 'dart:math';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/discovery/discovery_protocol.dart';
import 'package:test/test.dart';

import 'discovery_test_support.dart';

const String _nonce = '0123456789abcdef';

Map<String, Object?> _probeJson() => {
  'magic': kDiscoveryMagic,
  'v': kDiscoveryVersion,
  'kind': 'probe',
  'nonce': _nonce,
};

Map<String, Object?> _responseJson() => {
  'magic': kDiscoveryMagic,
  'v': kDiscoveryVersion,
  'kind': 'response',
  'nonce': _nonce,
  'hostId': 'host-1',
  'hostName': 'Barra',
  'tcpPort': 4040,
  'requiresPairing': false,
};

Map<String, Object?> _without(Map<String, Object?> json, String key) =>
    {...json}..remove(key);

/// Datagramas que ni la sonda ni la respuesta deben aceptar, construidos a
/// partir de un datagrama válido de cada tipo ([base]).
Map<String, List<int>> _invalidEnvelopes(Map<String, Object?> base) => {
  'vacío': const [],
  'binario que no es UTF-8': const [0xFF, 0xFE, 0x00, 0x80],
  'valores que no son bytes': const [256, -1, 70000],
  'texto que no es JSON': utf8.encode('hola, ¿hay alguien?'),
  'JSON truncado': jsonBytes(base).sublist(0, 20),
  'lista JSON': jsonBytes([base]),
  'cadena JSON': jsonBytes('probe'),
  'número JSON': jsonBytes(1),
  'null JSON': jsonBytes(null),
  'sin magic': jsonBytes(_without(base, 'magic')),
  'magic de otro protocolo': jsonBytes({...base, 'magic': 'ssdp'}),
  'magic que no es cadena': jsonBytes({...base, 'magic': 7}),
  'sin versión': jsonBytes(_without(base, 'v')),
  'versión posterior': jsonBytes({...base, 'v': kDiscoveryVersion + 1}),
  'versión como cadena': jsonBytes({...base, 'v': '1'}),
  'versión decimal': utf8.encode(
    jsonEncode(base).replaceFirst('"v":1', '"v":1.0'),
  ),
  'sin kind': jsonBytes(_without(base, 'kind')),
  'kind desconocido': jsonBytes({...base, 'kind': 'announce'}),
  'sin nonce': jsonBytes(_without(base, 'nonce')),
  'nonce vacío': jsonBytes({...base, 'nonce': ''}),
  'nonce numérico': jsonBytes({...base, 'nonce': 1234}),
  'nonce no hexadecimal': jsonBytes({...base, 'nonce': 'no-es-hexadecimal'}),
  'nonce demasiado largo': jsonBytes({
    ...base,
    'nonce': 'a' * (kMaxDiscoveryNonceLength + 1),
  }),
  'mayor que el máximo': jsonBytes({
    ...base,
    'relleno': 'x' * kMaxDiscoveryDatagramBytes,
  }),
};

/// Datagrama válido de exactamente [kMaxDiscoveryDatagramBytes] bytes.
List<int> _paddedToLimit(Map<String, Object?> base) {
  final overhead = jsonBytes({...base, 'relleno': ''}).length;
  final bytes = jsonBytes({
    ...base,
    'relleno': 'x' * (kMaxDiscoveryDatagramBytes - overhead),
  });
  expect(bytes, hasLength(kMaxDiscoveryDatagramBytes));
  return bytes;
}

void main() {
  group('DiscoveryProbe', () {
    test('sobrevive a un viaje de ida y vuelta', () {
      const probe = DiscoveryProbe(nonce: _nonce);
      expect(DiscoveryProbe.tryParse(probe.toBytes()), probe);
    });

    test('en el cable es el objeto JSON documentado', () {
      const probe = DiscoveryProbe(nonce: _nonce);
      expect(jsonDecode(utf8.decode(probe.toBytes())), _probeJson());
    });

    test('random genera nonces hexadecimales distintos', () {
      final nonces = {
        for (var i = 0; i < 200; i++) DiscoveryProbe.random().nonce,
      };
      expect(nonces, hasLength(200));
      for (final nonce in nonces) {
        expect(nonce, matches(RegExp(r'^[0-9a-f]{16}$')));
      }
    });

    test('random es reproducible con un generador con semilla', () {
      final a = DiscoveryProbe.random(Random(42));
      final b = DiscoveryProbe.random(Random(42));
      final c = DiscoveryProbe.random(Random(43));
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(DiscoveryProbe.tryParse(a.toBytes()), a);
    });

    test('tolera campos desconocidos y nonces en mayúsculas', () {
      final probe = DiscoveryProbe.tryParse(
        jsonBytes({..._probeJson(), 'nonce': 'ABCDEF0123', 'futuro': true}),
      );
      expect(probe?.nonce, 'ABCDEF0123');
    });

    test('acepta un datagrama justo en el tamaño máximo', () {
      expect(DiscoveryProbe.tryParse(_paddedToLimit(_probeJson())), isNotNull);
    });

    group('tryParse devuelve null con', () {
      final cases = {
        ..._invalidEnvelopes(_probeJson()),
        'una respuesta': jsonBytes(_responseJson()),
      };
      cases.forEach((name, bytes) {
        test(name, () => expect(DiscoveryProbe.tryParse(bytes), isNull));
      });
    });

    test('toBytes rechaza un nonce inválido', () {
      for (final nonce in ['', 'xyz', 'a' * (kMaxDiscoveryNonceLength + 1)]) {
        expect(
          () => DiscoveryProbe(nonce: nonce).toBytes(),
          throwsA(isA<ProtocolException>()),
          reason: 'nonce "$nonce"',
        );
      }
    });
  });

  group('DiscoveryResponse', () {
    const response = DiscoveryResponse(
      nonce: _nonce,
      hostId: 'host-1',
      hostName: 'Barra',
      tcpPort: 4040,
    );

    test('sobrevive a un viaje de ida y vuelta', () {
      const original = DiscoveryResponse(
        nonce: _nonce,
        hostId: '6f1c2a9e-0b7d-4c55-9a51-1f2e3d4c5b6a',
        hostName: 'Barra «El Rincón» ☕ ñ€',
        tcpPort: 65535,
        requiresPairing: true,
      );
      final parsed = DiscoveryResponse.tryParse(original.toBytes());
      expect(parsed, original);
      expect(parsed.hashCode, original.hashCode);
      expect(parsed?.requiresPairing, isTrue);
      expect(parsed?.hostName, 'Barra «El Rincón» ☕ ñ€');
    });

    test('en el cable es el objeto JSON documentado', () {
      expect(jsonDecode(utf8.decode(response.toBytes())), _responseJson());
    });

    test('tolera campos desconocidos', () {
      final parsed = DiscoveryResponse.tryParse(
        jsonBytes({..._responseJson(), 'appVersion': '2.0'}),
      );
      expect(parsed, response);
    });

    test('acepta los puertos TCP límite', () {
      for (final port in [1, 65535]) {
        final parsed = DiscoveryResponse.tryParse(
          jsonBytes({..._responseJson(), 'tcpPort': port}),
        );
        expect(parsed?.tcpPort, port);
      }
    });

    test('acepta un datagrama justo en el tamaño máximo', () {
      expect(
        DiscoveryResponse.tryParse(_paddedToLimit(_responseJson())),
        isNotNull,
      );
    });

    test('la respuesta más larga posible cabe en un datagrama', () {
      // Los caracteres de control son el peor caso: JSON los escapa como
      // \u00XX (6 bytes por carácter).
      final worst = DiscoveryResponse(
        nonce: 'f' * kMaxDiscoveryNonceLength,
        hostId: '\u0001' * kMaxDiscoveryHostIdLength,
        hostName: 'a${'\u0001' * (kMaxDiscoveryHostNameLength - 1)}',
        tcpPort: 65535,
        requiresPairing: true,
      );
      final bytes = worst.toBytes();
      expect(bytes.length, lessThanOrEqualTo(kMaxDiscoveryDatagramBytes));
      expect(DiscoveryResponse.tryParse(bytes), worst);
    });

    group('tryParse devuelve null con', () {
      final base = _responseJson();
      final cases = {
        ..._invalidEnvelopes(base),
        'una sonda': jsonBytes(_probeJson()),
        'sin hostId': jsonBytes(_without(base, 'hostId')),
        'hostId vacío': jsonBytes({...base, 'hostId': ''}),
        'hostId en blanco': jsonBytes({...base, 'hostId': '   '}),
        'hostId numérico': jsonBytes({...base, 'hostId': 42}),
        'hostId demasiado largo': jsonBytes({
          ...base,
          'hostId': 'h' * (kMaxDiscoveryHostIdLength + 1),
        }),
        'sin hostName': jsonBytes(_without(base, 'hostName')),
        'hostName vacío': jsonBytes({...base, 'hostName': ''}),
        'hostName nulo': jsonBytes({...base, 'hostName': null}),
        'hostName demasiado largo': jsonBytes({
          ...base,
          'hostName': 'n' * (kMaxDiscoveryHostNameLength + 1),
        }),
        'sin tcpPort': jsonBytes(_without(base, 'tcpPort')),
        'tcpPort 0': jsonBytes({...base, 'tcpPort': 0}),
        'tcpPort negativo': jsonBytes({...base, 'tcpPort': -4040}),
        'tcpPort 65536': jsonBytes({...base, 'tcpPort': 65536}),
        'tcpPort como cadena': jsonBytes({...base, 'tcpPort': '4040'}),
        'tcpPort decimal': jsonBytes({...base, 'tcpPort': 4040.5}),
        'sin requiresPairing': jsonBytes(_without(base, 'requiresPairing')),
        'requiresPairing como cadena': jsonBytes({
          ...base,
          'requiresPairing': 'false',
        }),
        'requiresPairing numérico': jsonBytes({...base, 'requiresPairing': 0}),
      };
      cases.forEach((name, bytes) {
        test(name, () => expect(DiscoveryResponse.tryParse(bytes), isNull));
      });
    });

    test('toBytes rechaza los mismos campos que tryParse', () {
      final invalid = [
        const DiscoveryResponse(
          nonce: 'no-hex',
          hostId: 'h',
          hostName: 'n',
          tcpPort: 4040,
        ),
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: ' ',
          hostName: 'n',
          tcpPort: 4040,
        ),
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: 'h',
          hostName: '',
          tcpPort: 4040,
        ),
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: 'h',
          hostName: 'n',
          tcpPort: 0,
        ),
        const DiscoveryResponse(
          nonce: _nonce,
          hostId: 'h',
          hostName: 'n',
          tcpPort: 70000,
        ),
        DiscoveryResponse(
          nonce: _nonce,
          hostId: 'h',
          hostName: 'n' * (kMaxDiscoveryHostNameLength + 1),
          tcpPort: 4040,
        ),
      ];
      for (final response in invalid) {
        expect(
          response.toBytes,
          throwsA(isA<ProtocolException>()),
          reason: '$response',
        );
      }
    });
  });
}
