/// Detalle de un ticket del turno (§7.7 del diseño de impresión): se abre al
/// tocar una fila de «Tickets del turno» en «Caja y Cierre Z».
///
/// Muestra los datos del ticket y sus precuentas, el estado de la factura
/// (con «Reintentar factura» si FacturaScripts la rechazó), el estado de
/// impresión, la vista previa del documento que saldría ahora y las mismas
/// acciones que el resultado del cobro.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/isolates/escpos/escpos_builder.dart' show PaperWidth;
import '../../../../core/money/money.dart';
import '../../../sala/domain/ticket.dart';
import '../../../settings/presentation/settings_providers.dart';
import '../../application/impresion/mapeo_documentos.dart'
    show motivoNoImprimible;
import '../impresion_providers.dart';
import '../providers.dart';
import '../resultado_cobro_dialog.dart';
import 'forma_cobro.dart';
import 'host_feedback.dart';
import 'host_formatos.dart';
import 'vista_previa_escpos.dart';

/// Sin reintentos automáticos: una vista previa que falla (ticket fuera del
/// turno, QR no válido) no se arregla sola.
Duration? _sinReintentos(int retryCount, Object error) => null;

/// Bytes del documento que saldría ahora para el ticket
/// (`PrintingService.vistaPreviaTicket`). Se recalcula cuando cambia el
/// ticket en el diario, la cabecera del emisor o los ajustes.
final _vistaPreviaProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, ticketId) {
      ref
        ..watch(
          hostSnapshotProvider.select((s) => s.value?.ticketPorId(ticketId)),
        )
        ..watch(cabeceraEmisorProvider)
        ..watch(appSettingsProvider.select((a) => a.value?.impresion));
      return ref.watch(printingServiceProvider).vistaPreviaTicket(ticketId);
    }, retry: _sinReintentos);

/// Abre el detalle del [ticket] (§7.7).
Future<void> mostrarDetalleTicket(BuildContext context, Ticket ticket) =>
    showDialog<void>(
      context: context,
      builder: (_) => TicketDetalleDialog(ticket: ticket),
    );

/// Detalle de un ticket del turno. Se actualiza solo con el diario; si el
/// ticket sale del turno (Cierre Z), conserva el recibido y lo indica.
class TicketDetalleDialog extends ConsumerWidget {
  const TicketDetalleDialog({super.key, required this.ticket});

  /// Ticket de la fila: respaldo si el diario ya no lo tiene.
  final Ticket ticket;

  /// Ancho de la columna de datos.
  static const double _anchoDatos = 340;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (:ticket, :enTurno) = observarTicket(ref, this.ticket);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Ticket nº ${ticket.numeroLocal}',
                key: const Key('detalle-titulo'),
                style: theme.textTheme.headlineSmall,
              ),
              if (!enTurno)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    textoTurnoCerrado,
                    key: const Key('detalle-turno-cerrado'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 24,
                    runSpacing: 16,
                    children: [
                      SizedBox(
                        width: _anchoDatos,
                        child: _DatosTicket(ticket: ticket, enTurno: enTurno),
                      ),
                      if (enTurno) _VistaPreviaTicket(ticket: ticket),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  AccionesImpresionTicket(ticket: ticket, enTurno: enTurno),
                  TextButton(
                    key: const Key('detalle-cerrar'),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cerrar'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Datos, precuentas, factura e impresión del ticket.
class _DatosTicket extends ConsumerWidget {
  const _DatosTicket({required this.ticket, required this.enTurno});

  final Ticket ticket;
  final bool enTurno;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final factura = ticket.factura;
    final enError = factura?.estado == EstadoSincronizacion.error;
    final esperando = observarEmisionPendiente(ref, ticket.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${ticket.nombreMesa} · ${formatHora(ticket.fechaHora)}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 4),
        Text(
          'Total ${formatCents(ticket.totalCents)} · '
          '${formatFormaCobro(ticket)}',
          key: const Key('detalle-total'),
          style: theme.textTheme.titleMedium,
        ),
        _titulo(context, 'Precuentas'),
        if (ticket.precuentas.isEmpty)
          const Text('Sin precuentas', key: Key('detalle-sin-precuentas'))
        else
          for (final p in ticket.precuentas)
            Text(
              'Precuenta nº ${p.numero} · ${formatHora(p.emitidaEn)} · '
              '${formatCents(p.totalCents)}',
              key: Key('detalle-precuenta-${p.numero}'),
            ),
        _titulo(context, 'Factura'),
        FilaEstadoTicket(
          icono: iconoEstadoFactura(ticket),
          texto: textoEstadoFactura(ticket),
          textoKey: const Key('detalle-factura'),
          error: enError,
        ),
        if (enError && enTurno)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: OutlinedButton.icon(
              key: const Key('reintentar-factura'),
              onPressed: () => ejecutarAccion(
                context,
                () => ref
                    .read(billingServiceProvider)
                    .reintentarFactura(ticket.id),
                exito: 'Factura reenviada a la cola de sincronización',
              ),
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar factura'),
            ),
          ),
        _titulo(context, 'Impresión'),
        Text(
          lineasImpresionDetalle(
            ticket.impresion,
            esperandoFactura: esperando,
            esperaSegundos: observarEsperaFactura(ref),
          ).join('\n'),
          key: const Key('detalle-impresion'),
        ),
      ],
    );
  }

  static Widget _titulo(BuildContext context, String texto) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Text(texto, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Estado de impresión del detalle, una línea por documento: provisional
/// (con la hora y las copias), ORIGINAL (con la hora) y duplicados.
List<String> lineasImpresionDetalle(
  ImpresionTicket impresion, {
  required bool esperandoFactura,
  required int esperaSegundos,
}) {
  final provisional = impresion.provisionalEn;
  final original = impresion.facturaOriginalEn;
  final copias = impresion.copiasProvisional;
  final textoCopias = switch (copias) {
    0 => '',
    1 => ' · 1 copia',
    _ => ' · $copias copias',
  };
  return [
    if (esperandoFactura) 'Esperando la factura ($esperaSegundos s)…',
    if (provisional == null)
      'Provisional sin imprimir'
    else
      'Provisional impreso a las ${formatHora(provisional)}$textoCopias',
    if (original == null)
      'Factura sin imprimir'
    else
      'Original impreso a las ${formatHora(original)}',
    if (original != null) 'Duplicados: ${impresion.duplicados}',
  ];
}

/// Vista previa del documento que saldría ahora, en el papel del perfil de
/// tickets. Si la factura no es imprimible, la del provisional y el motivo.
class _VistaPreviaTicket extends ConsumerWidget {
  const _VistaPreviaTicket({required this.ticket});

  final Ticket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final motivo = motivoNoImprimible(
      ticket,
      ref.watch(cabeceraEmisorProvider),
    );
    final vista = ref.watch(_vistaPreviaProvider(ticket.id));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Vista previa', style: theme.textTheme.titleSmall),
        if (motivo != null)
          SizedBox(
            width: TicketDetalleDialog._anchoDatos,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Se muestra el documento provisional: $motivo',
                key: const Key('detalle-motivo'),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        const SizedBox(height: 8),
        // Mientras se recalcula, se mantiene la vista anterior.
        if (vista.hasError && !vista.isLoading)
          SizedBox(
            width: TicketDetalleDialog._anchoDatos,
            child: Text(
              'No se pudo generar la vista previa: '
              '${mensajeDeError(vista.error!)}',
              key: const Key('detalle-vista-previa-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          )
        else if (vista.value case final Uint8List bytes)
          VistaPreviaEscPos(
            key: const Key('detalle-vista-previa'),
            bytes: bytes,
            papel: _papelTickets(ref),
          )
        else
          const Text('Generando la vista previa…'),
      ],
    );
  }

  /// Papel del perfil de la impresora de tickets o, sin ella, el heredado
  /// (el mismo criterio que `vistaPreviaTicket`).
  static PaperWidth _papelTickets(WidgetRef ref) {
    final ajustes = ref.watch(printingServiceProvider).settings;
    final endpoint = ajustes.paraTickets;
    return endpoint == null
        ? ajustes.paper
        : ajustes.perfilPara(endpoint).papel;
  }
}
