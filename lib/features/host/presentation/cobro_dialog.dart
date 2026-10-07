import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money/money.dart';
import '../../sala/domain/ticket.dart';
import '../application/sala_service.dart';
import 'providers.dart';
import 'widgets/forma_cobro.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';
import 'widgets/teclado_importe.dart';

/// Billetes de acceso rápido en el cobro en efectivo.
const List<int> kBilletesRapidosCents = [500, 1000, 2000, 5000];

/// Cobra una mesa: muestra el total legal (réplica del `Calculator` de
/// FacturaScripts) y permite cobrar en efectivo (con teclado y cambio), con
/// tarjeta o de forma mixta (parte en efectivo y el resto con tarjeta, en un
/// único ticket). Al confirmar llama a `SalaService.cobrar` o
/// `SalaService.cobrarMixto`. Devuelve el [Ticket] creado o `null` si se
/// cancela.
Future<Ticket?> mostrarCobro(BuildContext context, {required String mesaId}) =>
    showDialog<Ticket>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CobroDialog(mesaId: mesaId),
    );

/// Forma de cobro elegida en el diálogo.
enum ModoCobro { efectivo, tarjeta, mixto }

/// Qué importe escribe el teclado en el cobro mixto.
enum CampoMixto { efectivo, tarjeta, entregado }

/// Reparto de un cobro mixto: se teclea una de las dos partes (la otra es
/// el resto del total) y, si se quiere, el efectivo entregado.
///
/// Es puro (sin Flutter) para poder probar sus reglas por separado.
final class RepartoMixto {
  /// [parteCents] es el importe tecleado de la parte en efectivo o, si
  /// [parteEnTarjeta], de la parte con tarjeta. [entregadoTecleadoCents] es
  /// `0` si no se tecleó (se entiende el importe exacto de la parte en
  /// efectivo).
  RepartoMixto({
    required this.totalCents,
    required int parteCents,
    required bool parteEnTarjeta,
    int entregadoTecleadoCents = 0,
  }) : efectivoCents = parteEnTarjeta ? totalCents - parteCents : parteCents,
       entregadoCents = entregadoTecleadoCents == 0
           ? (parteEnTarjeta ? totalCents - parteCents : parteCents)
           : entregadoTecleadoCents,
       problema = _problema(totalCents, parteCents, parteEnTarjeta),
       problemaEsError = totalCents < 2 || parteCents >= totalCents;

  final int totalCents;
  final int efectivoCents;
  int get tarjetaCents => totalCents - efectivoCents;

  /// Lo que entrega el cliente para la parte en efectivo.
  final int entregadoCents;

  /// Por qué no se puede confirmar todavía el reparto (o `null`).
  final String? problema;

  /// [problema] es un error de lo tecleado y no una simple indicación.
  final bool problemaEsError;

  /// El entregado no cubre la parte en efectivo.
  bool get falta => problema == null && entregadoCents < efectivoCents;
  int get cambioCents => entregadoCents - efectivoCents;
  bool get valido => problema == null && !falta;

  static String? _problema(int total, int parte, bool enTarjeta) {
    final que = enTarjeta ? 'con tarjeta' : 'en efectivo';
    if (total < 2) {
      return 'Con un total de ${formatCents(total)} no se puede repartir '
          'el cobro';
    }
    if (parte <= 0) return 'Teclea el importe $que; el resto se calcula solo';
    if (parte >= total) {
      return 'El importe $que debe ser menor que el total '
          '(${formatCents(total)}): ninguna parte puede quedar a cero';
    }
    return null;
  }
}

class CobroDialog extends ConsumerStatefulWidget {
  const CobroDialog({super.key, required this.mesaId});

  final String mesaId;

  @override
  ConsumerState<CobroDialog> createState() => _CobroDialogState();
}

class _CobroDialogState extends ConsumerState<CobroDialog> {
  ModoCobro _modo = ModoCobro.efectivo;
  int _entregadoCents = 0;
  bool _cobrando = false;
  String? _error;

  // Cobro mixto.
  CampoMixto _campo = CampoMixto.efectivo;
  int _parteCents = 0;
  bool _parteEnTarjeta = false;
  int _entregadoMixtoCents = 0;

  /// El importe del campo activo es el propuesto: la primera tecla lo
  /// sustituye en lugar de añadirle cifras (como en una caja registradora).
  bool _sinTocar = false;

  @override
  Widget build(BuildContext context) {
    // Mientras se cobra no se puede cerrar el diálogo (ni con el botón
    // atrás): se perdería el resultado con el cambio que hay que devolver.
    return PopScope(canPop: !_cobrando, child: _dialogo(context));
  }

  Widget _dialogo(BuildContext context) {
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final comanda = snapshot?.comandaDeMesa(widget.mesaId);
    final mesa = snapshot?.mesaPorId(widget.mesaId);
    final theme = Theme.of(context);

    if (comanda == null || comanda.estaVacia) {
      // El cobro retira la comanda del diario antes de terminar de
      // guardarlo: no es que no haya nada pendiente, es que se está cobrando.
      if (_cobrando) {
        return AlertDialog(
          key: const Key('cobro-en-curso'),
          title: Text('Cobrar ${mesa?.nombre ?? ''}'.trim()),
          content: const Row(
            children: [
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              SizedBox(width: 16),
              Expanded(child: Text('Registrando el cobro…')),
            ],
          ),
        );
      }
      return AlertDialog(
        title: const Text('Cobrar'),
        content: Text(
          _error ?? 'La mesa no tiene nada pendiente de cobro.',
          key: _error == null ? null : const Key('cobro-error'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      );
    }

    final totales = ref
        .watch(salaServiceProvider)
        .calcularTotales(comanda.lineasActivas.toList());
    final total = totales.totalCents;
    final efectivo = _modo == ModoCobro.efectivo;
    final mixto = _modo == ModoCobro.mixto;
    // Sin importe tecleado se cobra el exacto.
    final entregado = _entregadoCents == 0 ? total : _entregadoCents;
    final falta = efectivo && entregado < total;
    final cambio = efectivo && !falta ? entregado - total : 0;
    final reparto = RepartoMixto(
      totalCents: total,
      parteCents: _parteCents,
      parteEnTarjeta: _parteEnTarjeta,
      entregadoTecleadoCents: _entregadoMixtoCents,
    );

    final resumen = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Total', style: theme.textTheme.titleMedium),
        Text(
          formatCents(total),
          key: const Key('cobro-total'),
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        for (final d in totales.desglose)
          Text(
            'IVA ${formatPorcentaje(basisPointsToPercent(d.ivaBp))}: base '
            '${formatCents(d.baseCents)} · cuota ${formatCents(d.cuotaCents)}',
            style: theme.textTheme.bodySmall,
          ),
        const SizedBox(height: 16),
        SegmentedButton<ModoCobro>(
          segments: const [
            ButtonSegment(
              value: ModoCobro.efectivo,
              icon: Icon(Icons.payments_outlined),
              label: Text('Efectivo'),
            ),
            ButtonSegment(
              value: ModoCobro.tarjeta,
              icon: Icon(Icons.credit_card),
              label: Text('Tarjeta'),
            ),
            ButtonSegment(
              value: ModoCobro.mixto,
              icon: Icon(Icons.call_split),
              label: Text('Mixto', key: Key('cobro-modo-mixto')),
            ),
          ],
          selected: {_modo},
          onSelectionChanged: _cobrando
              ? null
              : (s) => setState(() {
                  _modo = s.first;
                  _error = null;
                  _sinTocar = false;
                }),
        ),
        const SizedBox(height: 16),
        if (efectivo) ...[
          _fila(
            context,
            'Entregado',
            formatCents(entregado),
            key: const Key('cobro-entregado'),
          ),
          _fila(
            context,
            falta ? 'Falta' : 'Cambio',
            formatCents(falta ? total - entregado : cambio),
            key: const Key('cobro-cambio'),
            destacado: true,
            error: falta,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                label: const Text('Exacto'),
                onPressed: () => setState(() => _entregadoCents = 0),
              ),
              for (final billete in kBilletesRapidosCents)
                if (billete >= total)
                  ActionChip(
                    key: Key('billete-$billete'),
                    label: Text(formatCents(billete)),
                    onPressed: () => setState(() => _entregadoCents = billete),
                  ),
            ],
          ),
        ] else if (mixto)
          ..._resumenMixto(context, reparto)
        else
          Text(
            'Cobra ${formatCents(total)} en el datáfono y confirma.',
            style: theme.textTheme.bodyLarge,
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const Key('cobro-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ],
      ],
    );

    final teclado = mixto
        ? TecladoImporte(
            key: const Key('teclado-mixto'),
            valorCents: _sinTocar ? 0 : _valorCampoMixto(),
            onChanged: _cobrando
                ? (_) {}
                : (v) => setState(() {
                    if (_campo == CampoMixto.entregado) {
                      _entregadoMixtoCents = v;
                    } else {
                      _parteCents = v;
                    }
                    _sinTocar = false;
                    _error = null;
                  }),
          )
        : TecladoImporte(
            valorCents: _entregadoCents,
            onChanged: (v) => setState(() {
              _entregadoCents = v;
              _error = null;
            }),
          );
    final conTeclado = _modo != ModoCobro.tarjeta;

    final puedeConfirmar = switch (_modo) {
      ModoCobro.efectivo => !falta,
      ModoCobro.tarjeta => true,
      ModoCobro.mixto => reparto.valido,
    };

    return AlertDialog(
      title: Text('Cobrar ${mesa?.nombre ?? ''}'.trim()),
      content: SizedBox(
        width: 640,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final ancho = constraints.maxWidth >= 560;
            if (ancho && conTeclado) {
              return SingleChildScrollView(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: resumen),
                    const SizedBox(width: 24),
                    SizedBox(width: 260, child: teclado),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  resumen,
                  if (conTeclado) ...[const SizedBox(height: 12), teclado],
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cobrando ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton.icon(
          key: const Key('cobro-confirmar'),
          onPressed: _cobrando || !puedeConfirmar
              ? null
              : () => unawaited(
                  _cobrar(
                    (sala) => switch (_modo) {
                      ModoCobro.efectivo => sala.cobrar(
                        widget.mesaId,
                        MetodoPago.efectivo,
                        entregadoCents: entregado,
                        totalEsperadoCents: total,
                      ),
                      ModoCobro.tarjeta => sala.cobrar(
                        widget.mesaId,
                        MetodoPago.tarjeta,
                        totalEsperadoCents: total,
                      ),
                      ModoCobro.mixto => sala.cobrarMixto(
                        widget.mesaId,
                        efectivoCents: reparto.efectivoCents,
                        entregadoCents: reparto.entregadoCents,
                        totalEsperadoCents: reparto.totalCents,
                      ),
                    },
                  ),
                ),
          icon: _cobrando
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check),
          label: const Text('Confirmar cobro'),
        ),
      ],
    );
  }

  int _valorCampoMixto() =>
      _campo == CampoMixto.entregado ? _entregadoMixtoCents : _parteCents;

  /// Cambia el importe que escribe el teclado. Al pasar de una parte a la
  /// otra se conserva el reparto: el valor actual queda propuesto y la
  /// primera tecla lo sustituye.
  void _elegirCampo(CampoMixto campo, RepartoMixto reparto) {
    if (_cobrando) return;
    setState(() {
      _campo = campo;
      _error = null;
      if (campo == CampoMixto.efectivo && _parteEnTarjeta) {
        _parteEnTarjeta = false;
        _parteCents = _acotar(reparto.efectivoCents, reparto.totalCents);
      } else if (campo == CampoMixto.tarjeta && !_parteEnTarjeta) {
        _parteEnTarjeta = true;
        _parteCents = _acotar(reparto.tarjetaCents, reparto.totalCents);
      }
      _sinTocar = _valorCampoMixto() != 0;
    });
  }

  static int _acotar(int cents, int total) =>
      cents < 0 ? 0 : (cents > total ? total : cents);

  List<Widget> _resumenMixto(BuildContext context, RepartoMixto reparto) {
    final theme = Theme.of(context);
    final repartoValido = reparto.problema == null;
    return [
      _campoMixto(
        context,
        CampoMixto.efectivo,
        _parteEnTarjeta ? 'Efectivo (resto)' : 'Efectivo',
        formatCents(reparto.efectivoCents),
        reparto,
      ),
      _campoMixto(
        context,
        CampoMixto.tarjeta,
        _parteEnTarjeta ? 'Con tarjeta' : 'Con tarjeta (resto)',
        formatCents(reparto.tarjetaCents),
        reparto,
      ),
      _campoMixto(
        context,
        CampoMixto.entregado,
        _entregadoMixtoCents == 0
            ? 'Entregado en efectivo (exacto)'
            : 'Entregado en efectivo',
        formatCents(reparto.entregadoCents),
        reparto,
      ),
      if (repartoValido)
        _fila(
          context,
          reparto.falta ? 'Falta' : 'Cambio',
          formatCents(
            reparto.falta ? -reparto.cambioCents : reparto.cambioCents,
          ),
          key: const Key('mixto-cambio'),
          destacado: true,
          error: reparto.falta,
        ),
      if (reparto.problema case final problema?) ...[
        const SizedBox(height: 4),
        Text(
          problema,
          key: const Key('cobro-mixto-aviso'),
          style: reparto.problemaEsError
              ? TextStyle(color: theme.colorScheme.error)
              : theme.textTheme.bodyMedium,
        ),
      ],
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (reparto.totalCents >= 2)
            ActionChip(
              key: const Key('mixto-mitad'),
              label: const Text('Mitad y mitad'),
              onPressed: _cobrando
                  ? null
                  : () => setState(() {
                      _parteEnTarjeta = false;
                      _parteCents = reparto.totalCents ~/ 2;
                      _campo = CampoMixto.efectivo;
                      _sinTocar = true;
                      _error = null;
                    }),
            ),
          if (repartoValido) ...[
            ActionChip(
              key: const Key('mixto-exacto'),
              label: const Text('Exacto'),
              onPressed: _cobrando
                  ? null
                  : () => setState(() {
                      _entregadoMixtoCents = 0;
                      _sinTocar = _campo != CampoMixto.entregado && _sinTocar;
                    }),
            ),
            for (final billete in kBilletesRapidosCents)
              if (billete >= reparto.efectivoCents)
                ActionChip(
                  key: Key('mixto-billete-$billete'),
                  label: Text(formatCents(billete)),
                  onPressed: _cobrando
                      ? null
                      : () => setState(() {
                          _entregadoMixtoCents = billete;
                          _campo = CampoMixto.entregado;
                          _sinTocar = true;
                        }),
                ),
          ],
        ],
      ),
    ];
  }

  /// Fila del cobro mixto que, al tocarla, recibe lo que se teclea. Su clave
  /// es `mixto-campo-<campo>` y la de su importe `mixto-<campo>`.
  Widget _campoMixto(
    BuildContext context,
    CampoMixto campo,
    String etiqueta,
    String valor,
    RepartoMixto reparto,
  ) {
    final theme = Theme.of(context);
    final activo = _campo == campo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: activo
            ? theme.colorScheme.secondaryContainer
            : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: activo
                ? theme.colorScheme.secondary
                : theme.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          key: Key('mixto-campo-${campo.name}'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _elegirCampo(campo, reparto),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  activo ? Icons.keyboard : Icons.edit_outlined,
                  size: 18,
                  semanticLabel: activo
                      ? 'Se teclea aquí'
                      : 'Tocar para teclear',
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(etiqueta, style: theme.textTheme.titleMedium),
                ),
                Text(
                  valor,
                  key: Key('mixto-${campo.name}'),
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: activo && _sinTocar
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _cobrar(Future<Ticket> Function(SalaService sala) accion) async {
    setState(() {
      _cobrando = true;
      _error = null;
    });
    try {
      final ticket = await accion(ref.read(salaServiceProvider));
      if (!mounted) return;
      // Solo si el diálogo sigue arriba: nunca desapilar la pantalla de debajo.
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        Navigator.of(context).pop(ticket);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _cobrando = false;
          _error = mensajeDeError(error);
        });
      }
    }
  }

  Widget _fila(
    BuildContext context,
    String etiqueta,
    String valor, {
    Key? key,
    bool destacado = false,
    bool error = false,
  }) {
    final theme = Theme.of(context);
    final estilo =
        (destacado ? theme.textTheme.headlineSmall : theme.textTheme.titleLarge)
            ?.copyWith(color: error ? theme.colorScheme.error : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta, style: theme.textTheme.titleMedium)),
          Text(valor, key: key, style: estilo),
        ],
      ),
    );
  }
}

/// Resultado del cobro: número local, total, forma de pago (con el reparto
/// si es mixto) y cambio.
class ResultadoCobroDialog extends ConsumerWidget {
  const ResultadoCobroDialog({super.key, required this.ticket});

  final Ticket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final conEfectivo = ticket.pagos.any(
      (pago) => pago.metodo == MetodoPago.efectivo,
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
          Text(
            ticket.esMixto
                ? 'La factura simplificada se enviará a FacturaScripts desde '
                      'la cola de sincronización, con un cobro por cada forma '
                      'de pago.'
                : 'La factura simplificada se enviará a FacturaScripts desde '
                      'la cola de sincronización.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () => unawaited(
            ejecutarAccion(
              context,
              () => ref.read(billingServiceProvider).reimprimir(ticket.id),
              exito: 'Ticket enviado a la impresora',
            ),
          ),
          icon: const Icon(Icons.print),
          label: const Text('Imprimir copia'),
        ),
        FilledButton(
          key: const Key('volver-salon'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Volver al salón'),
        ),
      ],
    );
  }
}
