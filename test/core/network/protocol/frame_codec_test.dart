import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/core/network/protocol/frame_codec.dart';
import 'package:test/test.dart';

List<int> _line(String text) => [...utf8.encode(text), 0x0A];

Map<String, Object?> _onlyData(List<FrameEvent> events) {
  expect(events, hasLength(1));
  return (events.single as FrameData).json;
}

void main() {
  group('encodeFrame', () {
    test('termina en un único salto de línea y es JSON UTF-8', () {
      final frame = encodeFrame({'type': 'ping', 'n': 1});
      expect(frame.last, 0x0A);
      expect(frame.where((byte) => byte == 0x0A), hasLength(1));
      expect(jsonDecode(utf8.decode(frame)), {'type': 'ping', 'n': 1});
    });

    test('los saltos de línea dentro de cadenas se escapan', () {
      final frame = encodeFrame({'nota': 'sin sal\nmuy hecho\r\n'});
      expect(frame.where((byte) => byte == 0x0A), hasLength(1));
      expect(_onlyData(JsonLineFramer().add(frame)), {
        'nota': 'sin sal\nmuy hecho\r\n',
      });
    });

    test('rechaza tramas que superan el máximo', () {
      expect(
        () => encodeFrame({'x': 'a' * 64}, maxFrameBytes: 32),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('rechaza objetos no serializables', () {
      expect(
        () => encodeFrame({'when': DateTime(2026)}),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('JsonLineFramer', () {
    test('decodifica una trama completa', () {
      final framer = JsonLineFramer();
      expect(_onlyData(framer.add(_line('{"a":1}'))), {'a': 1});
      expect(framer.pendingBytes, 0);
    });

    test('recompone una trama entregada byte a byte', () {
      final framer = JsonLineFramer();
      final bytes = encodeFrame({'mesa': 'Terraza 4', 'plato': 'Piña asada €'});
      final events = <FrameEvent>[];
      for (final byte in bytes) {
        events.addAll(framer.add([byte]));
      }
      expect(_onlyData(events), {'mesa': 'Terraza 4', 'plato': 'Piña asada €'});
    });

    test('un carácter multibyte partido entre segmentos no se corrompe', () {
      final framer = JsonLineFramer();
      final bytes = encodeFrame({'t': 'ñ€😀'});
      // Parte justo por la mitad de cada secuencia multibyte.
      for (var cut = 1; cut < bytes.length - 1; cut++) {
        final events = [
          ...framer.add(bytes.sublist(0, cut)),
          ...framer.add(bytes.sublist(cut)),
        ];
        expect(_onlyData(events), {'t': 'ñ€😀'}, reason: 'corte en $cut');
      }
    });

    test('separa varias tramas recibidas en un mismo segmento', () {
      final framer = JsonLineFramer();
      final chunk = [
        ..._line('{"n":1}'),
        ..._line('{"n":2}'),
        ...utf8.encode('{"n":'),
      ];
      final events = framer.add(chunk);
      expect(events.map((event) => (event as FrameData).json['n']), [1, 2]);
      expect(framer.pendingBytes, 5);
      expect(_onlyData(framer.add(_line('3}'))), {'n': 3});
    });

    test('acepta CRLF e ignora líneas en blanco', () {
      final framer = JsonLineFramer();
      final events = framer.add(utf8.encode('\n\r\n  \t\n{"ok":true}\r\n\n'));
      expect(_onlyData(events), {'ok': true});
    });

    test('JSON inválido descarta solo esa trama', () {
      final framer = JsonLineFramer();
      final events = framer.add([..._line('{no es json'), ..._line('{"n":1}')]);
      expect(events, hasLength(2));
      expect(events[0], isA<FrameFailure>());
      expect((events[0] as FrameFailure).fatal, isFalse);
      expect((events[1] as FrameData).json, {'n': 1});
      expect(framer.isBroken, isFalse);
    });

    test('un valor JSON que no es objeto se rechaza sin romper el flujo', () {
      final framer = JsonLineFramer();
      for (final text in ['[1,2]', '"hola"', '42', 'null', 'true']) {
        final event = framer.add(_line(text)).single as FrameFailure;
        expect(event.fatal, isFalse, reason: text);
      }
      expect(_onlyData(framer.add(_line('{}'))), <String, Object?>{});
    });

    test('UTF-8 inválido descarta solo esa trama', () {
      final framer = JsonLineFramer();
      final events = framer.add([0xC3, 0x28, 0x0A, ..._line('{"n":1}')]);
      expect((events[0] as FrameFailure).fatal, isFalse);
      expect((events[1] as FrameData).json, {'n': 1});
    });

    test('una trama sin delimitador que supera el máximo es fatal', () {
      final framer = JsonLineFramer(maxFrameBytes: 16);
      expect(framer.add(List.filled(10, 0x61)), isEmpty);
      final events = framer.add(List.filled(10, 0x61));
      expect((events.single as FrameFailure).fatal, isTrue);
      expect(framer.isBroken, isTrue);
      expect(framer.pendingBytes, 0);
      // Tras el fallo fatal se ignora todo, aunque sea válido.
      expect(framer.add(_line('{"n":1}')), isEmpty);
    });

    test('una trama completa que supera el máximo también es fatal', () {
      final framer = JsonLineFramer(maxFrameBytes: 8);
      final events = framer.add(_line('{"abcdefghij":1}'));
      expect((events.single as FrameFailure).fatal, isTrue);
    });

    test('entrega las tramas previas a un fallo fatal del mismo segmento', () {
      final framer = JsonLineFramer(maxFrameBytes: 8);
      final events = framer.add([
        ..._line('{"n":1}'),
        ...List.filled(20, 0x61),
      ]);
      expect((events[0] as FrameData).json, {'n': 1});
      expect((events[1] as FrameFailure).fatal, isTrue);
    });

    test('una trama del tamaño máximo exacto se acepta', () {
      final body = '{"k":"${'a' * 8}"}';
      final framer = JsonLineFramer(maxFrameBytes: body.length);
      expect(_onlyData(framer.add(_line(body))), {'k': 'a' * 8});
    });

    test('close informa de una trama incompleta', () {
      final framer = JsonLineFramer()..add(utf8.encode('{"n":'));
      final failure = framer.close();
      expect(failure, isNotNull);
      expect(failure!.fatal, isTrue);
      expect(framer.close(), isNull);
    });

    test('close sin datos pendientes no informa de nada', () {
      final framer = JsonLineFramer()..add(_line('{"n":1}'));
      expect(framer.close(), isNull);
    });

    test('no retiene referencias al segmento del llamante', () {
      final framer = JsonLineFramer();
      final chunk = Uint8List.fromList(utf8.encode('{"n":'));
      framer.add(chunk);
      chunk.fillRange(0, chunk.length, 0x58); // el socket reutiliza su buffer
      expect(_onlyData(framer.add(_line('7}'))), {'n': 7});
    });
  });

  group('JsonLineDecoder', () {
    test('transforma un stream de segmentos arbitrarios', () async {
      final source = StreamController<Uint8List>();
      final events = const JsonLineDecoder().bind(source.stream).toList();

      final bytes = [
        ...encodeFrame({'n': 1}),
        ...encodeFrame({'n': 2}),
        ...encodeFrame({'n': 3}),
      ];
      for (var i = 0; i < bytes.length; i += 5) {
        final end = i + 5 > bytes.length ? bytes.length : i + 5;
        source.add(Uint8List.fromList(bytes.sublist(i, end)));
      }
      await source.close();

      final decoded = await events;
      expect(decoded.map((event) => (event as FrameData).json['n']), [1, 2, 3]);
    });

    test('al cerrarse el origen emite el fallo de trama incompleta', () async {
      final source = StreamController<List<int>>();
      final events = const JsonLineDecoder().bind(source.stream).toList();
      source.add(utf8.encode('{"n":1}\n{"n":'));
      await source.close();

      final decoded = await events;
      expect(decoded, hasLength(2));
      expect(decoded.last, isA<FrameFailure>());
    });

    test('propaga los errores del socket sin cerrar el stream', () async {
      final source = StreamController<List<int>>();
      final errors = <Object>[];
      final data = <FrameEvent>[];
      final done = Completer<void>();
      const JsonLineDecoder()
          .bind(source.stream)
          .listen(data.add, onError: errors.add, onDone: done.complete);

      source.addError(StateError('socket roto'));
      source.add(_line('{"n":1}'));
      await source.close();
      await done.future;

      expect(errors.single, isA<StateError>());
      expect(data, hasLength(1));
    });
  });
}
