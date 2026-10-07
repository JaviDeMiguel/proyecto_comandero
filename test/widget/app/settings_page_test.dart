import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proyecto_comandero/app/theme.dart';
import 'package:proyecto_comandero/core/errors/app_exception.dart';
import 'package:proyecto_comandero/features/settings/data/in_memory_settings_repository.dart';
import 'package:proyecto_comandero/features/settings/domain/app_settings.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_diagnostics.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_page.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_providers.dart';
import 'package:proyecto_comandero/features/settings/presentation/settings_widgets.dart';

import 'app_fakes.dart';

AppSettings ajustesHost() => AppSettings.defaults(
  deviceId: 'tablet-1',
  deviceName: 'Tablet',
).copyWith(rol: DeviceRole.host);

AppSettings ajustesComandero() => AppSettings.defaults(
  deviceId: 'movil-1',
  deviceName: 'Móvil',
).copyWith(rol: DeviceRole.comandero);

Future<void> asentar(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Finder campo(String clave) => find.byKey(Key('ajustes-$clave'));

Future<void> escribir(WidgetTester tester, String clave, String texto) async {
  await tester.ensureVisible(campo(clave));
  await tester.pump();
  await tester.enterText(campo(clave), texto);
  await tester.pump();
}

Future<void> pulsar(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await asentar(tester);
}

Future<void> guardar(WidgetTester tester) async {
  await tester.tap(campo('guardar'));
  await asentar(tester);
}

/// Cierra el diálogo de resumen si se mostró.
Future<void> cerrarResumen(WidgetTester tester) async {
  if (find.text('Entendido').evaluate().isNotEmpty) {
    await tester.tap(find.text('Entendido'));
    await asentar(tester);
  }
}

void main() {
  late FakeSettingsDiagnostics diagnostics;

  setUp(() => diagnostics = FakeSettingsDiagnostics());

  Future<InMemorySettingsRepository> montar(
    WidgetTester tester,
    AppSettings ajustes, {
    Set<String> Function()? mesasOcupadas,
  }) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = InMemorySettingsRepository(initial: ajustes);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith((ref) => repo),
          settingsDiagnosticsProvider.overrideWithValue(diagnostics),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: SettingsPage(mesasOcupadas: mesasOcupadas),
        ),
      ),
    );
    await asentar(tester);
    return repo;
  }

  testWidgets('valida los campos: con errores no guarda; corregidos, guarda', (
    tester,
  ) async {
    final repo = await montar(tester, ajustesHost());
    final guardadosAntes = repo.saveCount;

    await escribir(tester, 'tcp', '70000');
    await escribir(tester, 'nombre', '');
    await escribir(tester, 'fondo', '12,345');
    await guardar(tester);

    expect(find.text('Puerto entre 1 y 65535'), findsOneWidget);
    expect(find.text('Obligatorio'), findsOneWidget);
    expect(find.text('Importe no válido (p. ej. 150,00)'), findsOneWidget);
    expect(find.text('Revisa los campos marcados en rojo'), findsOneWidget);
    expect(repo.saveCount, guardadosAntes);

    await escribir(tester, 'tcp', '5000');
    await escribir(tester, 'nombre', 'Caja 1');
    await escribir(tester, 'fondo', '150,5');
    await escribir(tester, 'pairing', 'abc12');
    await escribir(tester, 'impresora-tickets', '192.168.1.50');
    await guardar(tester);

    expect(find.text('Ajustes guardados'), findsOneWidget);
    expect(find.textContaining('nuevos puertos'), findsOneWidget);
    expect(
      find.textContaining('nuevo código de emparejamiento'),
      findsOneWidget,
    );
    await cerrarResumen(tester);

    final guardados = (await repo.load())!;
    expect(guardados.deviceName, 'Caja 1');
    expect(guardados.red.tcpPort, 5000);
    expect(guardados.red.pairingCode, 'abc12');
    expect(guardados.fondoCajaCents, 15050);
    expect(guardados.impresion.tickets, PrinterEndpoint('192.168.1.50'));
    expect(guardados.impresion.cocina, isNull);
    expect(guardados.mesas, AppSettings.mesasPorDefecto());
    expect(guardados.fsApi, isNull);
  });

  testWidgets('los puertos TCP y UDP deben ser distintos', (tester) async {
    final repo = await montar(tester, ajustesHost());
    final guardadosAntes = repo.saveCount;

    await escribir(tester, 'tcp', '4041');
    await guardar(tester);

    expect(find.text('Debe ser distinto del puerto UDP'), findsOneWidget);
    expect(repo.saveCount, guardadosAntes);
  });

  testWidgets('ERP: prueba la conexión, elige formas de pago reales, resuelve '
      'subcuentas y guarda', (tester) async {
    final repo = await montar(tester, ajustesHost());

    await pulsar(tester, campo('erp-activo'));
    await escribir(tester, 'erp-url', 'http://192.168.1.10/facturascripts/');
    await escribir(tester, 'erp-token', 'clave-secreta');
    // El token se oculta.
    final token = tester.widget<EditableText>(
      find.descendant(
        of: campo('erp-token'),
        matching: find.byType(EditableText),
      ),
    );
    expect(token.obscureText, isTrue);

    await pulsar(tester, campo('erp-probar'));

    expect(diagnostics.ultimoErp!.token, 'clave-secreta');
    expect(
      diagnostics.ultimoErp!.baseUrl,
      'http://192.168.1.10/facturascripts',
    );
    expect(find.text('API accesible'), findsOneWidget);
    expect(find.byKey(const ValueKey('diagnostico-cliente')), findsOneWidget);

    // Formas de pago y almacén reales: desplegables.
    final tarjeta = find.byKey(const Key('ajustes-pago-tarjeta-3'));
    expect(tarjeta, findsOneWidget);
    expect(find.text('La factura nace cobrada.'), findsOneWidget);
    await pulsar(tester, tarjeta);
    await tester.tap(find.text('TARJ · Tarjeta').last);
    await asentar(tester);
    expect(find.textContaining('el TPV registrará el cobro'), findsOneWidget);

    await pulsar(tester, find.byKey(const Key('ajustes-almacen-1')));
    await tester.tap(find.text('ALG · Almacén general').last);
    await asentar(tester);

    await pulsar(tester, campo('erp-cliente'));
    expect(
      find.text('Cliente TPV (CLIENTES VARIOS (TPV)) disponible'),
      findsOneWidget,
    );

    await escribir(tester, 'subcuenta-659', '6590000099');
    await pulsar(tester, campo('subcuentas-resolver'));
    expect(diagnostics.llamadas, contains('subcuentas:1'));
    expect(find.text('Automática: 5700000000'), findsOneWidget);
    expect(find.text('Automática: 6590000099'), findsOneWidget);

    await pulsar(tester, find.text('Resumen completo'));
    expect(find.textContaining('Riesgo de duplicidad'), findsOneWidget);

    await guardar(tester);
    expect(find.textContaining('modo resumen completo'), findsOneWidget);
    await cerrarResumen(tester);

    final guardados = (await repo.load())!;
    expect(guardados.fsApi!.baseUrl, 'http://192.168.1.10/facturascripts');
    expect(guardados.fsApi!.token, 'clave-secreta');
    expect(guardados.fiscal.codpagoEfectivo, 'CONT');
    expect(guardados.fiscal.codpagoTarjeta, 'TARJ');
    expect(guardados.fiscal.codalmacen, 'ALG');
    expect(guardados.fiscal.modoAsientoZ, ModoAsientoZ.resumenCompleto);
    expect(guardados.fiscal.subcuentasOverride, {
      CuentaZ.perdidas659: '6590000099',
    });
  });

  group('cortafuegos del ERP', () {
    final clave = FsApiConfig(baseUrl: 'http://erp.local', token: 'malo');
    AppSettings conErp() => ajustesHost().copyWith(fsApi: clave);
    FsGuardAuthLocked rechazo(int status) => FsGuardAuthLocked(
      since: DateTime(2026, 10, 7, 12, 30),
      error: ErpApiException('Token no válido', statusCode: status),
    );

    testWidgets('u1: con la clave rechazada, Probar conexión no la reenvía '
        'sin confirmar y "Probar de nuevo" avisa del bloqueo de IP', (
      tester,
    ) async {
      diagnostics.estados[clave] = rechazo(403);
      await montar(tester, conErp());

      expect(
        find.byKey(const Key('ajustes-erp-clave-rechazada')),
        findsOneWidget,
      );
      expect(find.textContaining('07/10/2026 12:30'), findsOneWidget);
      expect(find.textContaining('o uno de sus permisos'), findsWidgets);

      // "Probar conexión" no sale a la red: pide confirmación.
      await pulsar(tester, campo('erp-probar'));
      expect(find.text('Probar de nuevo esta clave'), findsOneWidget);
      expect(find.textContaining('5 en 10'), findsWidgets);
      await tester.tap(find.text('Cancelar'));
      await asentar(tester);
      expect(diagnostics.llamadas, isEmpty);

      // Reintento explícito: se olvida el rechazo y se prueba.
      await pulsar(tester, campo('erp-reintentar'));
      await tester.tap(campo('erp-reintentar-confirmar'));
      await asentar(tester);
      expect(diagnostics.llamadas, ['desbloquear', 'probarErp']);
      expect(
        find.byKey(const Key('ajustes-erp-clave-rechazada')),
        findsNothing,
      );
      expect(find.text('API accesible'), findsOneWidget);
    });

    testWidgets('u1: con la IP bloqueada (429) se indica hasta cuándo', (
      tester,
    ) async {
      diagnostics.estados[clave] = FsGuardCooldown(
        until: DateTime(2026, 10, 7, 12, 40),
      );
      await montar(tester, conErp());

      expect(find.byKey(const Key('ajustes-erp-bloqueo-ip')), findsOneWidget);
      expect(find.textContaining('07/10/2026 12:40'), findsOneWidget);
      expect(campo('erp-reintentar'), findsNothing);
    });

    testWidgets('u2: las acciones del ERP son excluyentes: mientras una '
        'trabaja, las demás están desactivadas', (tester) async {
      final espera = Completer<void>();
      diagnostics.esperaErp = espera;
      await montar(tester, conErp());

      await pulsar(tester, campo('erp-probar'));
      expect(diagnostics.llamadas, ['probarErp']);
      for (final boton in [
        'erp-probar',
        'erp-cliente',
        'subcuentas-resolver',
      ]) {
        expect(
          tester.widget<BotonDiagnostico>(campo(boton)).onPressed,
          isNull,
          reason: boton,
        );
      }
      await pulsar(tester, campo('erp-cliente'));
      await pulsar(tester, campo('subcuentas-resolver'));
      expect(diagnostics.llamadas, ['probarErp'], reason: 'una sola petición');

      espera.complete();
      await asentar(tester);
      expect(
        tester.widget<BotonDiagnostico>(campo('erp-cliente')).onPressed,
        isNotNull,
      );
      diagnostics.esperaErp = null;
      await pulsar(tester, campo('erp-cliente'));
      expect(diagnostics.llamadas, ['probarErp', 'crearCliente:TPV']);
    });

    testWidgets('u2: guardar una clave recién rechazada pide confirmación', (
      tester,
    ) async {
      diagnostics.estados[clave] = rechazo(401);
      final repo = await montar(tester, conErp());

      await escribir(tester, 'nombre', 'Caja 2');
      await guardar(tester);
      expect(find.text('Clave del ERP rechazada'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await asentar(tester);
      expect((await repo.load())!.deviceName, 'Tablet');

      await guardar(tester);
      await tester.tap(campo('guardar-clave-rechazada'));
      await asentar(tester);
      await cerrarResumen(tester);
      expect((await repo.load())!.deviceName, 'Caja 2');
    });

    testWidgets('u2: una clave sin rechazo se guarda sin preguntar', (
      tester,
    ) async {
      final repo = await montar(tester, conErp());

      await escribir(tester, 'nombre', 'Caja 3');
      await guardar(tester);
      await cerrarResumen(tester);
      expect(find.text('Clave del ERP rechazada'), findsNothing);
      expect((await repo.load())!.deviceName, 'Caja 3');
    });
  });

  testWidgets('ERP: sin URL válida no llama a la API', (tester) async {
    await montar(tester, ajustesHost());

    await pulsar(tester, campo('erp-activo'));
    await escribir(tester, 'erp-url', 'ftp://erp');
    await escribir(tester, 'erp-token', 'x');
    await pulsar(tester, campo('erp-probar'));

    expect(diagnostics.llamadas, isEmpty);
    expect(
      find.text('Escribe una URL válida y el token de la API'),
      findsOneWidget,
    );
  });

  testWidgets('MySQL: prueba la conexión, verifica las tablas y muestra los '
      'errores', (tester) async {
    final repo = await montar(tester, ajustesHost());

    await pulsar(tester, campo('mysql-activo'));
    await escribir(tester, 'mysql-host', '192.168.1.10');
    await escribir(tester, 'mysql-usuario', 'tpv');
    await escribir(tester, 'mysql-password', 'secreto');
    await escribir(tester, 'mysql-bd', 'facturascripts');

    await pulsar(tester, campo('mysql-probar'));
    expect(find.text('Conexión correcta con facturascripts'), findsOneWidget);
    expect(diagnostics.ultimoMysql!.port, 3306);
    expect(diagnostics.ultimoMysql!.password, 'secreto');

    await pulsar(tester, campo('mysql-tablas'));
    expect(diagnostics.llamadas, contains('tablas:true'));
    expect(find.text('Tablas del TPV completas'), findsOneWidget);
    expect(find.text('Tablas del TPV verificadas'), findsOneWidget);

    diagnostics.fallo = const NetworkException('MySQL no responde');
    await pulsar(tester, campo('mysql-probar'));
    expect(find.text('MySQL no responde'), findsOneWidget);

    await guardar(tester);
    await cerrarResumen(tester);
    final guardados = (await repo.load())!;
    expect(guardados.mysql!.host, '192.168.1.10');
    expect(guardados.mysql!.database, 'facturascripts');
    expect(guardados.mysql!.password, 'secreto');
  });

  testWidgets('Ticket de prueba se envía a la impresora escrita', (
    tester,
  ) async {
    await montar(tester, ajustesHost());

    await escribir(tester, 'impresora-cocina', '10.0.0.5:9101');
    await pulsar(tester, find.text('Papel 58 mm'));
    await pulsar(tester, campo('prueba-cocina'));

    final (endpoint, data) = diagnostics.impresiones.single;
    expect(endpoint, PrinterEndpoint('10.0.0.5', port: 9101));
    expect(data.destino, 'Cocina');
    expect(data.paper, PaperWidth.mm58);
    expect(find.text('Página de prueba enviada a Cocina'), findsOneWidget);

    diagnostics.fallo = const PrinterException('Impresora apagada');
    await pulsar(tester, campo('prueba-cocina'));
    expect(find.text('Impresora apagada'), findsOneWidget);

    await escribir(tester, 'impresora-barra', 'impresora barra');
    await pulsar(tester, campo('prueba-barra'));
    expect(diagnostics.impresiones, hasLength(1));
  });

  testWidgets('Mesas: añade mesas conservando las existentes y no deja quitar '
      'una ocupada', (tester) async {
    final repo = await montar(
      tester,
      ajustesHost(),
      mesasOcupadas: () => {'mesa-12'},
    );

    expect(find.byKey(const Key('ajustes-zona-1-cantidad')), findsOneWidget);
    await pulsar(tester, campo('zona-1-mas'));
    await guardar(tester);
    await cerrarResumen(tester);

    var mesas = (await repo.load())!.mesas;
    expect(mesas, hasLength(14));
    expect(mesas.take(13), AppSettings.mesasPorDefecto());
    expect(mesas.last.nombre, 'Mesa 13');
    expect(mesas.last.zona, 'Salón');

    await pulsar(tester, campo('zona-1-menos'));
    await pulsar(tester, campo('zona-1-menos'));
    final guardadosAntes = repo.saveCount;
    await guardar(tester);

    expect(
      find.text('No se pueden quitar mesas con comanda abierta: Mesa 12'),
      findsOneWidget,
    );
    expect(repo.saveCount, guardadosAntes);

    await pulsar(tester, campo('zona-nueva'));
    await escribir(tester, 'zona-2', 'Terraza');
    await pulsar(tester, campo('zona-1-mas'));
    await guardar(tester);
    await cerrarResumen(tester);

    mesas = (await repo.load())!.mesas;
    expect(mesas.where((m) => m.zona == 'Salón'), hasLength(12));
    expect(mesas.where((m) => m.zona == 'Terraza').single.nombre, 'Terraza 1');
  });

  testWidgets('comandero: solo dispositivo y red; normaliza el host manual', (
    tester,
  ) async {
    final repo = await montar(tester, ajustesComandero());

    expect(find.text('ERP FacturaScripts'), findsNothing);
    expect(find.text('Mesas'), findsNothing);
    expect(campo('tcp'), findsNothing);

    await escribir(tester, 'host-manual', 'a b');
    await guardar(tester);
    expect(find.text('La dirección no puede tener espacios'), findsOneWidget);

    await escribir(tester, 'host-manual', '192.168.1.20');
    await escribir(tester, 'pairing', '1234');
    await guardar(tester);
    await cerrarResumen(tester);

    final guardados = (await repo.load())!;
    expect(guardados.red.hostManual, '192.168.1.20:4040');
    expect(guardados.red.pairingCode, '1234');
    expect(guardados.rol, DeviceRole.comandero);
  });

  testWidgets('salir con cambios sin guardar pide confirmación', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1000, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = InMemorySettingsRepository(initial: ajustesHost());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWith((ref) => repo),
          settingsDiagnosticsProvider.overrideWithValue(diagnostics),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
                ),
                child: const Text('abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();

    await escribir(tester, 'nombre', 'Otro nombre');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Cambios sin guardar'), findsOneWidget);

    await tester.tap(find.text('Seguir editando'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Descartar'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsNothing);
    expect((await repo.load())!.deviceName, 'Tablet');
  });
}
