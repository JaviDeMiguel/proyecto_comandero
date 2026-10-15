/// Proveedores derivados de la impresión del host (§7.11 del diseño de
/// impresión): pases, nombre del TPV, cabecera del emisor y su NIF, y las
/// emisiones automáticas de factura en curso.
///
/// Cambian al guardar los ajustes o al llegar datos de FacturaScripts.
/// Ninguno usa `hostRuntimeReadyProvider`, así que todos funcionan (y no
/// lanzan) aunque el TPV no haya arrancado: los pases y el nombre salen de
/// los ajustes, la cabecera se compone sin la empresa en caché y las
/// emisiones pendientes quedan vacías.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/isolates/escpos/ticket_documents.dart' show EmpresaTicket;
import '../../impresion/domain/formato_impresion.dart';
import '../../sala/domain/pases.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/host_runtime.dart';
import '../application/impresion/mapeo_documentos.dart' show componerCabecera;
import '../domain/host_settings.dart';
import 'host_settings_mapper.dart';
import 'providers.dart';

/// Ajustes efectivos del host según los ajustes guardados (nulo mientras
/// cargan).
final _hostSettingsProvider = Provider<HostSettings?>((ref) {
  final ajustes = ref.watch(appSettingsProvider).value;
  return ajustes == null ? null : hostSettingsFromApp(ajustes);
});

/// Pases efectivos: `hostSettingsFromApp(ajustes).impresion.pases`; los de
/// por defecto si aún no hay ajustes.
final pasesConfigProvider = Provider<PasesConfig>(
  (ref) =>
      ref.watch(_hostSettingsProvider)?.impresion.pases ?? const PasesConfig(),
);

/// Nombre del TPV (`fiscal.nombreTpv` o, si está vacío, el del dispositivo).
/// Mientras cargan los ajustes, el del runtime si ya está en marcha (como la
/// pantalla de inicio del host) y, si no, vacío. No exige el runtime.
final nombreTpvProvider = Provider<String>(
  (ref) =>
      ref.watch(_hostSettingsProvider)?.nombreTpv ??
      ref.watch(hostRuntimeProvider).value?.settings.nombreTpv ??
      '',
);

/// Cabecera del emisor de los documentos de cliente: `componerCabecera` con
/// los ajustes, la empresa guardada en el diario (si el runtime está en
/// marcha y la tiene) y el formato del ticket.
final cabeceraEmisorProvider = Provider<EmpresaTicket>((ref) {
  final host = ref.watch(_hostSettingsProvider);
  final empresaErp = ref.watch(
    hostSnapshotProvider.select((snapshot) => snapshot.value?.empresa),
  );
  return componerCabecera(
    empresaAjustes: host?.empresa,
    empresaErp: empresaErp,
    formato: host?.impresion.formato.ticket ?? const FormatoTicket(),
    nombreTpv: host?.nombreTpv ?? '',
  );
});

/// La cabecera del emisor tiene NIF: sin él no se imprimen facturas
/// simplificadas. Sustituye al getter no reactivo
/// `PrintingService.cabeceraFiscalCompleta`.
final cabeceraFiscalCompletaProvider = Provider<bool>(
  (ref) => ref.watch(cabeceraEmisorProvider).cifnif?.trim().isNotEmpty ?? false,
);

/// Tickets con una emisión automática de factura en curso (§5.4). Como
/// `hostSnapshotProvider`, espera al runtime y emite
/// `printing.emisionesPendientes`; sin runtime (no es el host o no se pudo
/// crear), un conjunto vacío.
final emisionesPendientesProvider = StreamProvider<Set<String>>((ref) async* {
  final HostRuntime runtime;
  try {
    runtime = await ref.watch(hostRuntimeProvider.future);
  } on Object {
    yield const <String>{};
    return;
  }
  yield* runtime.printing.emisionesPendientes;
});
