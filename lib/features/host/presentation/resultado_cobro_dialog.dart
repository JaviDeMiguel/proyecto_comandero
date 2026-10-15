/// Diálogo de resultado del cobro (§7.6 del diseño de impresión) y piezas
/// que comparte con el detalle del ticket (§7.7): el ticket vivo del diario,
/// los textos del estado de la factura y de la impresión, y los botones
/// «Imprimir factura» / «Imprimir duplicado» y «Copia provisional».
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/isolates/escpos/ticket_documents.dart' show EmpresaTicket;
import '../../../core/money/money.dart';
import '../../impresion/domain/formato_impresion.dart' show EmisionTicket;
import '../../sala/domain/ticket.dart';
import '../../settings/presentation/settings_providers.dart';
import '../application/impresion/mapeo_documentos.dart' show motivoNoImprimible;
import 'impresion_providers.dart';
import 'providers.dart';
import 'widgets/forma_cobro.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';

/// Texto del botón de la factura cuando ya salió el ORIGINAL.
const String textoImprimirDuplicado = 'Imprimir duplicado';

/// Texto del botón de la factura antes del ORIGINAL.
const String textoImprimirFactura = 'Imprimir factura';

/// Motivo de los botones desactivados cuando el ticket ya salió del turno.
const String textoTurnoCerrado = 'Este ticket pertenece a un turno cerrado';

/// Motivo de «Imprimir factura» desactivado mientras la emisión automática
/// del cobro está en curso (§5.4).
const String textoEmisionEnCurso = 'Imprimiendo la factura automáticamente…';

/// Ticket tal como está ahora en el diario del host.
///
/// [enTurno] es `false` si el diario ya no lo tiene (tras el Cierre Z):
/// entonces [ticket] es el recibido como respaldo.
typedef TicketVivo = ({Ticket ticket, bool enTurno});

/// Observa el ticket [respaldo] en el diario (`hostSnapshotProvider`) y se
/// reconstruye cuando cambia (llega la factura, se imprime...). Mientras el
/// diario carga, se toma el respaldo como si siguiera en el turno.
TicketVivo observarTicket(WidgetRef ref, Ticket respaldo) {
  final estado = ref.watch(
    hostSnapshotProvider.select(
      (s) =>
          (cargado: s.value != null, ticket: s.value?.ticketPorId(respaldo.id)),
    ),
  );
  if (!estado.cargado) return (ticket: respaldo, enTurno: true);
  return (ticket: estado.ticket ?? respaldo, enTurno: estado.ticket != null);
}

/// El ticket tiene una emisión automática de factura en curso
/// (`emisionesPendientesProvider`).
bool observarEmisionPendiente(WidgetRef ref, String ticketId) => ref.watch(
  emisionesPendientesProvider.select(
    (pendientes) => pendientes.value?.contains(ticketId) ?? false,
  ),
);

/// Segundos de espera de la factura en el modo «Emitir factura al cobrar».
int observarEsperaFactura(WidgetRef ref) =>
    ref.watch(
      appSettingsProvider.select(
        (ajustes) => ajustes.value?.impresion.formato.emision.esperaSegundos,
      ),
    ) ??
    const EmisionTicket().esperaSegundos;

/// Estado de la factura del ticket en una línea: «Enviando a
/// FacturaScripts…», «Factura F2026S12» o «Factura con error: …».
String textoEstadoFactura(Ticket ticket) {
  final factura = ticket.factura;
  if (factura == null) return 'Sin factura';
  return switch (factura.estado) {
    EstadoSincronizacion.pendiente => 'Enviando a FacturaScripts…',
    EstadoSincronizacion.sincronizado =>
      'Factura ${factura.codigo ?? factura.idfactura?.toString() ?? ''}'.trim(),
    EstadoSincronizacion.error =>
      'Factura con error: ${factura.error ?? 'sin detalle'}',
  };
}

/// Estado de impresión del ticket en una línea. Con [esperandoFactura]
/// (emisión automática en curso), «Esperando la factura (N s)…».
String textoEstadoImpresion(
  ImpresionTicket impresion, {
  required bool esperandoFactura,
  required int esperaSegundos,
}) {
  if (esperandoFactura) return 'Esperando la factura ($esperaSegundos s)…';
  if (impresion.originalImpreso) {
    final n = impresion.duplicados;
    return 'Factura impresa (original)'
        '${n == 0 ? '' : ' · $n ${n == 1 ? 'duplicado' : 'duplicados'}'}';
  }
  if (impresion.provisionalEn != null) {
    final n = impresion.copiasProvisional;
    return 'Documento provisional impreso'
        '${n == 0 ? '' : ' · $n ${n == 1 ? 'copia' : 'copias'}'}';
  }
  return 'Sin imprimir';
}

/// Qué botones de impresión ofrece un ticket y por qué la factura no se
/// puede imprimir (§7.6). Puro: lo comparten el resultado del cobro y el
/// detalle del ticket.
final class EstadoAccionesTicket {
  const EstadoAccionesTicket._({
    required this.etiquetaFactura,
    required this.motivoFacturaInactiva,
    required this.mostrarProvisional,
    required this.provisionalActiva,
  });

  /// [cabecera] es la del emisor (`cabeceraEmisorProvider`), [enTurno] si el
  /// diario aún tiene el ticket y [emisionPendiente] si hay una emisión
  /// automática de su factura en curso.
  factory EstadoAccionesTicket.de(
    Ticket ticket, {
    required EmpresaTicket cabecera,
    required bool enTurno,
    required bool emisionPendiente,
  }) {
    final motivo = motivoNoImprimible(ticket, cabecera);
    final sinCodigo = ticket.factura?.codigo?.trim().isNotEmpty != true;
    return EstadoAccionesTicket._(
      etiquetaFactura: ticket.impresion.originalImpreso
          ? textoImprimirDuplicado
          : textoImprimirFactura,
      motivoFacturaInactiva: !enTurno
          ? textoTurnoCerrado
          : emisionPendiente
          ? textoEmisionEnCurso
          : motivo,
      mostrarProvisional: sinCodigo || motivo != null,
      provisionalActiva: enTurno,
    );
  }

  /// «Imprimir factura» o, tras el ORIGINAL, «Imprimir duplicado».
  final String etiquetaFactura;

  /// Por qué «Imprimir factura» está desactivado (`null` = activo).
  final String? motivoFacturaInactiva;

  /// «Copia provisional» se ofrece sin código o si la factura no se puede
  /// imprimir.
  final bool mostrarProvisional;
  final bool provisionalActiva;

  bool get facturaActiva => motivoFacturaInactiva == null;

  bool get esDuplicado => etiquetaFactura == textoImprimirDuplicado;
}

/// Botones «Copia provisional» (clave `copia-provisional`) e «Imprimir
/// factura» / «Imprimir duplicado» (clave `imprimir-factura`) del [ticket]
/// vivo. Un tooltip explica por qué la factura no se puede imprimir. Los
/// errores llegan a la interfaz con `ejecutarAccion` y, mientras una
/// petición está en curso, ambos botones se desactivan.
class AccionesImpresionTicket extends ConsumerStatefulWidget {
  const AccionesImpresionTicket({
    super.key,
    required this.ticket,
    required this.enTurno,
  });

  final Ticket ticket;
  final bool enTurno;

  @override
  ConsumerState<AccionesImpresionTicket> createState() =>
      _AccionesImpresionTicketState();
}

class _AccionesImpresionTicketState
    extends ConsumerState<AccionesImpresionTicket> {
  bool _enCurso = false;

  Future<void> _ejecutar(
    Future<void> Function(String ticketId) accion,
    String exito,
  ) async {
    setState(() => _enCurso = true);
    await ejecutarAccion(context, () => accion(widget.ticket.id), exito: exito);
    if (mounted) setState(() => _enCurso = false);
  }

  @override
  Widget build(BuildContext context) {
    final estado = EstadoAccionesTicket.de(
      widget.ticket,
      cabecera: ref.watch(cabeceraEmisorProvider),
      enTurno: widget.enTurno,
      emisionPendiente: observarEmisionPendiente(ref, widget.ticket.id),
    );
    final botonFactura = FilledButton.tonalIcon(
      key: const Key('imprimir-factura'),
      onPressed: _enCurso || !estado.facturaActiva
          ? null
          : () => unawaited(
              _ejecutar(
                (id) => ref.read(printingServiceProvider).imprimirFactura(id),
                estado.esDuplicado
                    ? 'Duplicado de la factura enviado a la impresora'
                    : 'Factura enviada a la impresora',
              ),
            ),
      icon: const Icon(Icons.receipt_long),
      label: Text(estado.etiquetaFactura),
    );
    final motivo = estado.motivoFacturaInactiva;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: [
        if (estado.mostrarProvisional)
          TextButton.icon(
            key: const Key('copia-provisional'),
            onPressed: _enCurso || !estado.provisionalActiva
                ? null
                : () => unawaited(
                    _ejecutar(
                      (id) => ref
                          .read(printingServiceProvider)
                          .reimprimirProvisional(id),
                      'Copia provisional enviada a la impresora',
                    ),
                  ),
            icon: const Icon(Icons.print),
            label: const Text('Copia provisional'),
          ),
        if (motivo == null)
          botonFactura
        else
          Tooltip(message: motivo, child: botonFactura),
      ],
    );
  }
}

/// Resultado del cobro: número local, total, forma de pago (con el reparto
/// si es mixto), cambio y, en vivo, el estado de la factura y de la
/// impresión, con los botones de impresión (§7.6).
///
/// Contrato estable: el título `Ticket nº N cobrado` y las claves
/// `resultado-total`, `resultado-efectivo`, `resultado-tarjeta`,
/// `resultado-entregado`, `resultado-cambio` y `volver-salon`. Lo nuevo:
/// `resultado-factura`, `resultado-impresion`, `imprimir-factura` y
/// `copia-provisional`.
class ResultadoCobroDialog extends ConsumerWidget {
  const ResultadoCobroDialog({super.key, required this.ticket});

  /// Ticket devuelto por el cobro: respaldo si el diario ya no lo tiene.
  final Ticket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (:ticket, :enTurno) = observarTicket(ref, this.ticket);
    final conEfectivo = ticket.pagos.any(
      (pago) => pago.metodo == MetodoPago.efectivo,
    );
    final impresion = textoEstadoImpresion(
      ticket.impresion,
      esperandoFactura: observarEmisionPendiente(ref, ticket.id),
      esperaSegundos: observarEsperaFactura(ref),
    );
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: theme.colorScheme.primary),
      title: Text('Ticket nº ${ticket.numeroLocal} cobrado'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${ticket.nombreMesa} · ${formatHora(ticket.fechaHora)}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
          Text(
            'Total ${formatCents(ticket.totalCents)} · '
            '${ticket.esMixto ? 'Mixto' : nombreMetodoPago(ticket.metodoPago)}',
            key: const Key('resultado-total'),
            style: theme.textTheme.titleMedium,
          ),
          if (ticket.esMixto)
            for (final pago in ticket.pagos)
              Text(
                '${nombreMetodoPago(pago.metodo)} '
                '${formatCents(pago.importeCents)}',
                key: Key('resultado-${pago.metodo.name}'),
                style: theme.textTheme.titleMedium,
              ),
          if (conEfectivo && ticket.entregadoCents != null) ...[
            const SizedBox(height: 4),
            Text(
              'Entregado ${formatCents(ticket.entregadoCents!)}',
              key: const Key('resultado-entregado'),
            ),
            const SizedBox(height: 8),
            Text(
              'Cambio ${formatCents(ticket.cambioCents)}',
              key: const Key('resultado-cambio'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilaEstadoTicket(
            icono: iconoEstadoFactura(ticket),
            texto: textoEstadoFactura(ticket),
            textoKey: const Key('resultado-factura'),
            error: ticket.factura?.estado == EstadoSincronizacion.error,
          ),
          FilaEstadoTicket(
            icono: Icons.print_outlined,
            texto: impresion,
            textoKey: const Key('resultado-impresion'),
          ),
        ],
      ),
      actions: [
        AccionesImpresionTicket(ticket: ticket, enTurno: enTurno),
        FilledButton(
          key: const Key('volver-salon'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Volver al salón'),
        ),
      ],
    );
  }
}

/// Icono del estado de la factura (estático: nada de animaciones infinitas
/// mientras la factura está pendiente).
IconData iconoEstadoFactura(Ticket ticket) => switch (ticket.factura?.estado) {
  EstadoSincronizacion.pendiente => Icons.sync,
  EstadoSincronizacion.sincronizado => Icons.receipt_long,
  EstadoSincronizacion.error => Icons.error_outline,
  null => Icons.receipt_long_outlined,
};

/// Fila de estado con icono: el [texto] lleva la clave [textoKey].
class FilaEstadoTicket extends StatelessWidget {
  const FilaEstadoTicket({
    super.key,
    required this.icono,
    required this.texto,
    required this.textoKey,
    this.error = false,
  });

  final IconData icono;
  final String texto;
  final Key textoKey;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icono, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              key: textoKey,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}
