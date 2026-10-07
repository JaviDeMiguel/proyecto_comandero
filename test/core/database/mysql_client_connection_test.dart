import 'dart:async';
import 'dart:io';

import 'package:mysql_client/exception.dart';
import 'package:mysql_client/mysql_protocol.dart';
import 'package:proyecto_comandero/core/database/mysql_client_connection.dart';
import 'package:proyecto_comandero/core/database/mysql_config.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:test/test.dart';

void main() {
  group('decodeMysqlTextValue', () {
    Object? decode(String? raw, int type, [int length = 11]) =>
        decodeMysqlTextValue(raw, typeCode: type, columnLength: length);

    test('NULL es null sea cual sea el tipo', () {
      expect(decode(null, mysqlColumnTypeLong), isNull);
      expect(decode(null, mysqlColumnTypeVarString), isNull);
      expect(decode('x', mysqlColumnTypeNull), isNull);
    });

    test('enteros: INT, BIGINT, SMALLINT, MEDIUMINT, YEAR', () {
      expect(decode('42', mysqlColumnTypeLong), 42);
      expect(decode('-7', mysqlColumnTypeLongLong), -7);
      expect(decode('3', mysqlColumnTypeShort), 3);
      expect(decode('5', mysqlColumnTypeInt24), 5);
      expect(decode('2026', mysqlColumnTypeYear), 2026);
      expect(
        decode('9223372036854775807', mysqlColumnTypeLongLong),
        9223372036854775807,
      );
    });

    test('BIGINT UNSIGNED fuera de rango se devuelve como texto', () {
      expect(
        decode('18446744073709551615', mysqlColumnTypeLongLong),
        '18446744073709551615',
      );
    });

    test('TINYINT(1) es bool; TINYINT de otra anchura es int', () {
      expect(decode('1', mysqlColumnTypeTiny, 1), isTrue);
      expect(decode('0', mysqlColumnTypeTiny, 1), isFalse);
      expect(decode('2', mysqlColumnTypeTiny, 1), isTrue);
      expect(decode('5', mysqlColumnTypeTiny, 4), 5);
      expect(decode('-1', mysqlColumnTypeTiny, 4), -1);
    });

    test('DOUBLE, FLOAT y DECIMAL son double', () {
      expect(decode('12.5', mysqlColumnTypeDouble), 12.5);
      expect(decode('1', mysqlColumnTypeDouble), 1.0);
      expect(decode('0.333', mysqlColumnTypeFloat), 0.333);
      expect(decode('10.90909', mysqlColumnTypeNewDecimal), 10.90909);
      expect(decode('-3', mysqlColumnTypeDecimal), -3.0);
      expect(decode('1e21', mysqlColumnTypeDouble), 1e21);
    });

    test('fechas y horas son DateTime local; fecha cero es null', () {
      expect(
        decode('2026-10-07 12:34:56', mysqlColumnTypeDateTime),
        DateTime(2026, 10, 7, 12, 34, 56),
      );
      expect(
        decode('2026-10-07 12:34:56', mysqlColumnTypeTimestamp),
        DateTime(2026, 10, 7, 12, 34, 56),
      );
      expect(decode('2026-10-07', mysqlColumnTypeDate), DateTime(2026, 10, 7));
      expect(
        decode('2026-10-07 12:34:56.123456', mysqlColumnTypeDateTime2),
        DateTime(2026, 10, 7, 12, 34, 56, 123, 456),
      );
      expect(decode('0000-00-00', mysqlColumnTypeDate), isNull);
      expect(decode('0000-00-00 00:00:00', mysqlColumnTypeTimestamp), isNull);
      final parsed = decode('2026-01-01 00:00:00', mysqlColumnTypeDateTime);
      expect((parsed! as DateTime).isUtc, isFalse);
    });

    test('texto, TIME, BIT, JSON y blobs se devuelven tal cual', () {
      expect(decode('PAELLA', mysqlColumnTypeVarString), 'PAELLA');
      expect(decode('Arroz "bomba"', mysqlColumnTypeBlob), 'Arroz "bomba"');
      expect(decode('12:30:00', mysqlColumnTypeTime), '12:30:00');
      expect(decode('{"a":1}', mysqlColumnTypeString), '{"a":1}');
      expect(decode('', mysqlColumnTypeVarChar), '');
    });

    test('un valor numérico mal formado no rompe: se devuelve el texto', () {
      expect(decode('abc', mysqlColumnTypeLong), 'abc');
      expect(decode('abc', mysqlColumnTypeDouble), 'abc');
      expect(decode('ayer', mysqlColumnTypeDateTime), 'ayer');
    });
  });

  group('encodeMysqlParam', () {
    test('tipos admitidos', () {
      expect(encodeMysqlParam(null), isNull);
      expect(encodeMysqlParam(true), 1);
      expect(encodeMysqlParam(false), 0);
      expect(encodeMysqlParam(7), 7);
      expect(encodeMysqlParam(-2.5), -2.5);
      expect(encodeMysqlParam("O'Brien"), "O'Brien");
      expect(
        encodeMysqlParam(DateTime(2026, 3, 9, 8, 5, 3, 999)),
        '2026-03-09 08:05:03',
      );
    });

    test('rechaza números no finitos y tipos desconocidos', () {
      expect(() => encodeMysqlParam(double.nan), throwsArgumentError);
      expect(() => encodeMysqlParam(double.infinity), throwsArgumentError);
      expect(() => encodeMysqlParam(const Duration()), throwsArgumentError);
      expect(() => encodeMysqlParam([1, 2]), throwsArgumentError);
    });
  });

  test('formatMysqlDateTime rellena con ceros', () {
    expect(
      formatMysqlDateTime(DateTime(999, 1, 2, 3, 4, 5)),
      '0999-01-02 03:04:05',
    );
  });

  group('translateMysqlError', () {
    test('MySQLServerException -> DatabaseException con errno y sqlState', () {
      final e = translateMysqlError(
        const MySQLServerException('Deadlock found', 1213),
        context: 'confirmar',
      );
      expect(e, isA<DatabaseException>());
      final d = e as DatabaseException;
      expect(d.errorCode, 1213);
      expect(d.sqlState, '40001');
      expect(d.isDeadlock, isTrue);
      expect(d.isRetryable, isTrue);
      expect(d.message, contains('1213'));
      expect(d.message, contains('confirmar'));
      expect(d.cause, isA<MySQLServerException>());
    });

    test('errnos conocidos llevan su SQLSTATE; desconocidos, null', () {
      DatabaseException t(int errno) =>
          translateMysqlError(MySQLServerException('x', errno))
              as DatabaseException;
      expect(t(1062).sqlState, '23000');
      expect(t(1062).isDuplicateKey, isTrue);
      expect(t(1452).sqlState, '23000');
      expect(t(1205).isLockWaitTimeout, isTrue);
      expect(t(1146).sqlState, '42S02');
      expect(t(9999).sqlState, isNull);
      expect(t(9999).isRetryable, isFalse);
    });

    test('conexión cerrada del cliente -> NetworkException', () {
      final e = translateMysqlError(
        const MySQLClientException('Can not execute query: connection closed'),
      );
      expect(e, isA<NetworkException>());
    });

    test('caching_sha2_password sin TLS -> DatabaseException explicativa', () {
      final e = translateMysqlError(
        const MySQLClientException(
          'Auth plugin caching_sha2_password is supported only with secure '
          'connections. Pass secure: true or use another auth method',
        ),
      );
      expect(e, isA<DatabaseException>());
      expect(e.message, contains('secure'));
    });

    test('otros errores del cliente -> DatabaseException', () {
      final e = translateMysqlError(
        const MySQLProtocolException('Unexpected payload'),
      );
      expect(e, isA<DatabaseException>());
      expect((e as DatabaseException).errorCode, isNull);
    });

    test('red: SocketException, TimeoutException, HandshakeException', () {
      expect(
        translateMysqlError(const SocketException('refused')),
        isA<NetworkException>(),
      );
      expect(
        translateMysqlError(TimeoutException('t')),
        isA<NetworkException>(),
      );
      expect(
        translateMysqlError(const HandshakeException('tls')),
        isA<NetworkException>(),
      );
    });

    test('una AppException se devuelve tal cual', () {
      const original = ValidationException('ya tipada');
      expect(translateMysqlError(original), same(original));
    });

    test('cualquier otra cosa -> DatabaseException con causa', () {
      final e = translateMysqlError(StateError('raro'));
      expect(e, isA<DatabaseException>());
      expect(e.cause, isA<StateError>());
      expect(translateMysqlError(ArgumentError('p')), isA<DatabaseException>());
    });
  });

  group('MysqlClientConnection.connect', () {
    test('conexión rechazada -> NetworkException', () async {
      // Puerto efímero reservado y cerrado: nadie escucha.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final config = MysqlConfig(
        host: '127.0.0.1',
        port: port,
        user: 'u',
        password: 'p',
        database: 'd',
        connectTimeout: const Duration(seconds: 3),
      );
      await expectLater(
        MysqlClientConnection.connect(config),
        throwsA(isA<NetworkException>()),
      );
    });

    test('servidor que no habla MySQL (silencio) -> NetworkException por '
        'timeout', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      server.listen(sockets.add);
      addTearDown(() async {
        for (final s in sockets) {
          s.destroy();
        }
        await server.close();
      });
      final config = MysqlConfig(
        host: '127.0.0.1',
        port: server.port,
        user: 'u',
        password: 'p',
        database: 'd',
        connectTimeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        MysqlClientConnection.connect(config),
        throwsA(isA<NetworkException>()),
      );
    });

    test(
      'paquete de error del servidor en el saludo -> DatabaseException',
      () async {
        // Paquete ERR de MySQL: header 0xff, errno 1040 "Too many connections".
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final sockets = <Socket>[];
        server.listen((socket) {
          sockets.add(socket);
          const message = 'Too many connections';
          final payload = <int>[
            0xff,
            1040 & 0xff,
            1040 >> 8,
            ...message.codeUnits,
          ];
          final packet = <int>[
            payload.length & 0xff,
            (payload.length >> 8) & 0xff,
            (payload.length >> 16) & 0xff,
            0,
            ...payload,
          ];
          socket.add(packet);
        });
        addTearDown(() async {
          for (final s in sockets) {
            s.destroy();
          }
          await server.close();
        });
        final config = MysqlConfig(
          host: '127.0.0.1',
          port: server.port,
          user: 'u',
          password: 'p',
          database: 'd',
          connectTimeout: const Duration(seconds: 3),
        );
        await expectLater(
          MysqlClientConnection.connect(config),
          throwsA(
            isA<DatabaseException>().having((e) => e.errorCode, 'errno', 1040),
          ),
        );
      },
    );
  });
}
