import 'package:proyecto_comandero/core/database/mysql_config.dart';
import 'package:test/test.dart';

void main() {
  const config = MysqlConfig(
    host: '192.168.1.10',
    user: 'tpv',
    password: 'muy-secreta',
    database: 'facturascripts',
  );

  test('valores por defecto', () {
    expect(config.port, 3306);
    expect(config.secure, isFalse);
    expect(config.connectTimeout, const Duration(seconds: 5));
    expect(config.queryTimeout, const Duration(seconds: 15));
  });

  test('toJson / fromJson son inversos', () {
    final full = config.copyWith(
      port: 3307,
      secure: true,
      connectTimeout: const Duration(seconds: 2),
      queryTimeout: const Duration(seconds: 30),
    );
    expect(MysqlConfig.fromJson(full.toJson()), full);
    expect(full.toJson(), {
      'host': '192.168.1.10',
      'port': 3307,
      'user': 'tpv',
      'password': 'muy-secreta',
      'database': 'facturascripts',
      'secure': true,
      'connectTimeoutMs': 2000,
      'queryTimeoutMs': 30000,
    });
  });

  test('fromJson aplica defectos y exige los campos obligatorios', () {
    final parsed = MysqlConfig.fromJson({
      'host': 'h',
      'user': 'u',
      'database': 'd',
    });
    expect(parsed.password, '');
    expect(parsed.port, 3306);
    expect(parsed.secure, isFalse);
    expect(
      () => MysqlConfig.fromJson({'host': 'h', 'user': 'u'}),
      throwsFormatException,
    );
    expect(
      () => MysqlConfig.fromJson({'host': 'h', 'user': 'u', 'database': 1}),
      throwsFormatException,
    );
  });

  test('toString no incluye la contraseña', () {
    expect(
      config.toString(),
      'MysqlConfig(tpv@192.168.1.10:3306/facturascripts)',
    );
    expect(config.toString(), isNot(contains('secreta')));
    expect(config.copyWith(secure: true).toString(), contains('TLS'));
  });
}
