import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:test/test.dart';

void main() {
  group('ErpApiException', () {
    ErpApiErrorKind kindOf(int? status) =>
        ErpApiException('x', statusCode: status).kind;

    test('clasifica por código HTTP', () {
      expect(kindOf(null), ErpApiErrorKind.network);
      expect(kindOf(400), ErpApiErrorKind.validation);
      expect(kindOf(422), ErpApiErrorKind.validation);
      expect(kindOf(401), ErpApiErrorKind.unauthorized);
      expect(kindOf(403), ErpApiErrorKind.forbidden);
      expect(kindOf(404), ErpApiErrorKind.notFound);
      expect(kindOf(409), ErpApiErrorKind.disabled);
      expect(kindOf(429), ErpApiErrorKind.banned);
      expect(kindOf(500), ErpApiErrorKind.server);
      expect(kindOf(503), ErpApiErrorKind.server);
      expect(kindOf(405), ErpApiErrorKind.unexpected);
      expect(kindOf(200), ErpApiErrorKind.unexpected);
    });

    test('solo red y 5xx dejan el resultado incierto', () {
      expect(const ErpApiException('x').outcomeUnknown, isTrue);
      expect(
        const ErpApiException('x', statusCode: 502).outcomeUnknown,
        isTrue,
      );
      expect(
        const ErpApiException('x', statusCode: 422).outcomeUnknown,
        isFalse,
      );
      expect(
        const ErpApiException('x', statusCode: 429).outcomeUnknown,
        isFalse,
      );
    });

    test('los fallos de credenciales no son transitorios', () {
      const unauthorized = ErpApiException('x', statusCode: 401);
      const forbidden = ErpApiException('x', statusCode: 403);
      expect(unauthorized.isAuthFailure, isTrue);
      expect(forbidden.isAuthFailure, isTrue);
      expect(unauthorized.isTransient, isFalse);
      expect(const ErpApiException('x', statusCode: 429).isTransient, isTrue);
      expect(const ErpApiException('x', statusCode: 400).isTransient, isFalse);
    });
  });

  group('DatabaseException', () {
    test('reconoce los errores reintentables de InnoDB', () {
      expect(const DatabaseException('x', errorCode: 1213).isRetryable, isTrue);
      expect(const DatabaseException('x', errorCode: 1205).isRetryable, isTrue);
      expect(
        const DatabaseException('x', errorCode: 1062).isRetryable,
        isFalse,
      );
      expect(
        const DatabaseException('x', errorCode: 1062).isDuplicateKey,
        isTrue,
      );
      expect(const DatabaseException('x').isRetryable, isFalse);
    });
  });

  test('toString incluye el tipo, el mensaje y la causa', () {
    expect(
      const NetworkException('Sin conexión').toString(),
      'NetworkException: Sin conexión',
    );
    expect(
      const PrinterException('Fallo', cause: 'timeout').toString(),
      'PrinterException: Fallo (causa: timeout)',
    );
  });

  test('RemoteRequestException conserva código y reintentabilidad', () {
    const error = RemoteRequestException('Mesa cerrada', code: 'validation');
    expect(error.code, 'validation');
    expect(error.retryable, isFalse);
    expect(error, isA<AppException>());
  });
}
