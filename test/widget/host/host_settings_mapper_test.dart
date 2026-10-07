import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/features/host/domain/host_settings.dart'
    as host;
import 'package:proyecto_comandero/features/host/presentation/host_settings_mapper.dart';
import 'package:proyecto_comandero/features/sala/domain/enrutamiento_comandas.dart';
import 'package:proyecto_comandero/features/sala/domain/linea_comanda.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';

void main() {
  test('mapea todos los campos equivalentes de AppSettings', () {
    final cocina = PrinterEndpoint('10.0.0.20');
    final barra = PrinterEndpoint('10.0.0.21', port: 9101);
    final tickets = PrinterEndpoint('10.0.0.22');
    const mesas = [
      Mesa(id: 't1', nombre: 'Terraza 1', zona: 'Terraza', orden: 1),
    ];
    final fsApi = FsApiConfig(baseUrl: 'http://erp.local/fs', token: 'tok');
    final mysql = MysqlConfig(
      host: 'db.local',
      user: 'fs',
      password: 'pw',
      database: 'facturascripts',
    );
    final app = AppSettings(
      deviceId: 'dev-1',
      deviceName: 'Tablet barra',
      rol: DeviceRole.host,
      red: const NetworkSettings(
        tcpPort: 5050,
        discoveryPort: 5051,
        pairingCode: ' 1234 ',
      ),
      fsApi: fsApi,
      mysql: mysql,
      fiscal: const FiscalSettings(
        codserie: 'T',
        codcliente: 'VARIOS',
        codalmacen: 'ALG',
        codpagoEfectivo: 'EFE',
        codpagoTarjeta: 'TAR',
        idempresa: 3,
        emitirFacturas: false,
        modoAsientoZ: ModoAsientoZ.resumenCompleto,
        subcuentasOverride: {CuentaZ.caja570: '5700000001'},
        nombreTpv: 'Caja 2',
      ),
      impresion: PrintingSettings(
        tickets: tickets,
        cocina: cocina,
        barra: barra,
        paper: PaperWidth.mm58,
        abrirCajon: false,
        imprimirTicketAlCobrar: false,
        imprimirComandaCocina: false,
        enrutamiento: const EnrutamientoComandas(
          porFamilia: {'BEB': DestinoPreparacion.barra},
          porDefecto: DestinoPreparacion.barra,
        ),
      ),
      reposicion: const ReposicionSettings(
        automatica: false,
        enCierre: false,
        politica: PoliticaReposicion(factorSinMaximo: 3),
      ),
      fondoCajaCents: 15000,
      mesas: mesas,
    );

    final s = hostSettingsFromApp(app);

    expect(s.deviceId, 'dev-1');
    expect(s.nombreTpv, 'Caja 2');
    expect(s.tcpPort, 5050);
    expect(s.discoveryPort, 5051);
    expect(s.pairingCode, '1234');
    expect(s.requiresPairing, isTrue);
    expect(s.erp, same(fsApi));
    expect(s.mysql, same(mysql));
    expect(
      s.fiscal,
      const host.FiscalSettings(
        codcliente: 'VARIOS',
        codserie: 'T',
        codpagoEfectivo: 'EFE',
        codpagoTarjeta: 'TAR',
        codalmacen: 'ALG',
        idempresa: 3,
        emitirFacturas: false,
      ),
    );
    expect(
      s.cierre,
      const host.CierreSettings(
        modoAsientoZ: ModoAsientoZ.resumenCompleto,
        overridesSubcuentas: {CuentaZ.caja570: '5700000001'},
      ),
    );
    expect(
      s.impresion,
      host.ImpresionSettings(
        cocina: cocina,
        barra: barra,
        tickets: tickets,
        imprimirComandas: false,
        imprimirTicketAlCobrar: false,
        abrirCajonEfectivo: false,
        paper: PaperWidth.mm58,
        enrutamiento: const EnrutamientoComandas(
          porFamilia: {'BEB': DestinoPreparacion.barra},
          porDefecto: DestinoPreparacion.barra,
        ),
      ),
    );
    expect(
      s.reposicion,
      const host.ReposicionSettings(
        automatica: false,
        enCierre: false,
        politica: PoliticaReposicion(factorSinMaximo: 3),
      ),
    );
    expect(s.mesas, mesas);
  });

  test('valores por defecto: sin ERP, sin almacén, empresa 1', () {
    final app = AppSettings.defaults(deviceId: 'dev-2', deviceName: 'Tablet');

    final s = hostSettingsFromApp(app);

    expect(s.nombreTpv, 'TPV 1');
    expect(s.erp, isNull);
    expect(s.mysql, isNull);
    expect(s.pairingCode, isNull);
    expect(s.requiresPairing, isFalse);
    expect(s.fiscal.codalmacen, isEmpty);
    expect(s.fiscal.completa, isFalse);
    expect(s.fiscal.idempresa, kIdEmpresaPorDefecto);
    expect(s.cierre.modoAsientoZ, ModoAsientoZ.soloDescuadre);
    expect(s.impresion.hayImpresora, isFalse);
    expect(s.mesas, AppSettings.mesasPorDefecto());
  });

  test('nombre vacío usa el del dispositivo; pairing en blanco se ignora', () {
    final app = AppSettings.defaults(deviceId: 'dev-3', deviceName: 'Tablet 3')
        .copyWith(
          fiscal: const FiscalSettings(nombreTpv: '  '),
          red: const NetworkSettings(pairingCode: '   '),
        );

    final s = hostSettingsFromApp(app);

    expect(s.nombreTpv, 'Tablet 3');
    expect(s.pairingCode, isNull);
  });

  test('es determinista: los mismos ajustes producen HostSettings iguales', () {
    final app = AppSettings.defaults(deviceId: 'dev-4', deviceName: 'X');
    expect(hostSettingsFromApp(app), hostSettingsFromApp(app));
  });
}
