import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/frame_codec.dart';
import 'package:proyecto_comandero/core/network/protocol/message.dart';
import 'package:proyecto_comandero/core/network/protocol/transport_messages.dart';
import 'package:test/test.dart';

void main() {
  group('ProtocolMessage', () {
    test('create genera ids únicos y marca la hora', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1790000000000);
      final a = ProtocolMessage.create('ping', now: now);
      final b = ProtocolMessage.create('ping', now: now);
      expect(a.id, isNot(b.id));
      expect(a.timestampMs, 1790000000000);
      expect(a.version, kProtocolVersion);
      expect(a.payload, isEmpty);
    });

    test('sobrevive a un viaje completo por el cable', () {
      final original = ProtocolMessage.create(
        'comanda.submit',
        payload: {
          'mesa': 'T4',
          'lineas': [
            {'ref': 'PAELLA', 'cantidad': 2, 'nota': 'sin marisco\npoco hecha'},
          ],
        },
        replyTo: 'abc',
      );
      final frame = encodeFrame(original.toJson());
      final json = (JsonLineFramer().add(frame).single as FrameData).json;
      final decoded = ProtocolMessage.fromJson(json);

      expect(decoded.id, original.id);
      expect(decoded.type, 'comanda.submit');
      expect(decoded.replyTo, 'abc');
      expect(decoded.timestampMs, original.timestampMs);
      expect(decoded.payload, original.payload);
    });

    test('reply enlaza con el mensaje original', () {
      final request = ProtocolMessage.create('comanda.submit');
      final reply = request.reply(TransportMessageTypes.ack, payload: {'n': 1});
      expect(reply.replyTo, request.id);
      expect(reply.id, isNot(request.id));
      expect(reply.type, 'ack');
    });

    test('toJson omite replyTo cuando no hay', () {
      final json = ProtocolMessage.create('ping').toJson();
      expect(json.containsKey('replyTo'), isFalse);
      expect(json.keys, containsAll(['v', 'id', 'type', 'ts', 'payload']));
    });

    test('el payload ausente equivale a vacío', () {
      final message = ProtocolMessage.fromJson({
        'v': 1,
        'id': 'x',
        'type': 'ping',
        'ts': 0,
      });
      expect(message.payload, isEmpty);
    });

    test('fromJson rechaza sobres mal formados', () {
      const valid = <String, Object?>{
        'v': 1,
        'id': 'x',
        'type': 'ping',
        'ts': 0,
        'payload': <String, Object?>{},
      };
      final invalid = <Map<String, Object?>>[
        {...valid}..remove('v'),
        {...valid, 'v': '1'},
        {...valid, 'v': 0},
        {...valid}..remove('id'),
        {...valid, 'id': ''},
        {...valid, 'id': 'x' * 65},
        {...valid, 'id': 7},
        {...valid}..remove('type'),
        {...valid, 'type': ''},
        {...valid, 'type': 'x' * 65},
        {...valid}..remove('ts'),
        {...valid, 'ts': '0'},
        {...valid, 'ts': 1.5},
        {...valid, 'replyTo': 5},
        {...valid, 'replyTo': ''},
        {...valid, 'payload': <Object?>[]},
        {...valid, 'payload': 'x'},
      ];
      for (final json in invalid) {
        expect(
          () => ProtocolMessage.fromJson(json),
          throwsA(isA<ProtocolException>()),
          reason: '$json',
        );
      }
      expect(ProtocolMessage.fromJson(valid).type, 'ping');
    });
  });

  group('payloads de transporte', () {
    test('HelloPayload ida y vuelta', () {
      const hello = HelloPayload(
        deviceId: 'dev-1',
        deviceName: 'Comandero terraza',
        appVersion: '0.1.0',
        pairingCode: '4821',
      );
      final decoded = HelloPayload.fromJson(hello.toJson());
      expect(decoded.deviceId, 'dev-1');
      expect(decoded.deviceName, 'Comandero terraza');
      expect(decoded.protocolVersion, kProtocolVersion);
      expect(decoded.appVersion, '0.1.0');
      expect(decoded.pairingCode, '4821');
    });

    test('HelloPayload omite los opcionales nulos', () {
      const hello = HelloPayload(deviceId: 'd', deviceName: 'n');
      expect(hello.toJson().keys, [
        'deviceId',
        'deviceName',
        'protocolVersion',
      ]);
    });

    test('HelloPayload inválido lanza ProtocolException', () {
      for (final json in <Map<String, Object?>>[
        {},
        {'deviceId': '', 'deviceName': 'n', 'protocolVersion': 1},
        {'deviceId': 'd', 'deviceName': 'n'},
        {'deviceId': 'd', 'deviceName': 'n', 'protocolVersion': '1'},
        {'deviceId': 'd', 'deviceName': 3, 'protocolVersion': 1},
        {
          'deviceId': 'd',
          'deviceName': 'n',
          'protocolVersion': 1,
          'pairingCode': 1,
        },
      ]) {
        expect(
          () => HelloPayload.fromJson(json),
          throwsA(isA<ProtocolException>()),
          reason: '$json',
        );
      }
    });

    test('WelcomePayload ida y vuelta y validación', () {
      const welcome = WelcomePayload(
        hostId: 'host-1',
        hostName: 'TPV Barra',
        sessionId: 's-1',
        serverTimeMs: 123,
        heartbeatIntervalMs: 5000,
        idleTimeoutMs: 15000,
      );
      final decoded = WelcomePayload.fromJson(welcome.toJson());
      expect(decoded.hostId, 'host-1');
      expect(decoded.hostName, 'TPV Barra');
      expect(decoded.sessionId, 's-1');
      expect(decoded.serverTimeMs, 123);
      expect(decoded.heartbeatIntervalMs, 5000);
      expect(decoded.idleTimeoutMs, 15000);

      expect(
        () => WelcomePayload.fromJson({
          ...welcome.toJson(),
          'heartbeatIntervalMs': 0,
        }),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('RejectPayload y ErrorPayload toleran el mensaje ausente', () {
      final reject = RejectPayload.fromJson({'code': RejectCodes.serverFull});
      expect(reject.code, 'server_full');
      expect(reject.message, '');

      final error = ErrorPayload.fromJson({'code': ErrorCodes.internal});
      expect(error.retryable, isFalse);
      expect(error.message, '');
    });

    test('ErrorPayload se convierte en RemoteRequestException', () {
      const payload = ErrorPayload(
        code: ErrorCodes.validation,
        message: 'Mesa cerrada',
      );
      final exception = ErrorPayload.fromJson(payload.toJson()).toException();
      expect(exception.code, 'validation');
      expect(exception.message, 'Mesa cerrada');
      expect(exception.retryable, isFalse);
    });

    test('los tipos de transporte están reservados', () {
      expect(TransportMessageTypes.isReserved('hello'), isTrue);
      expect(TransportMessageTypes.isReserved('ack'), isTrue);
      expect(TransportMessageTypes.isReserved('comanda.submit'), isFalse);
    });
  });

  group('pairingCodesMatch', () {
    test('solo acepta el código exacto', () {
      expect(pairingCodesMatch('4821', '4821'), isTrue);
      expect(pairingCodesMatch('4821', '4822'), isFalse);
      expect(pairingCodesMatch('4821', '482'), isFalse);
      expect(pairingCodesMatch('4821', '48211'), isFalse);
      expect(pairingCodesMatch('4821', ''), isFalse);
      expect(pairingCodesMatch('4821', null), isFalse);
      expect(pairingCodesMatch('', ''), isTrue);
    });
  });
}
