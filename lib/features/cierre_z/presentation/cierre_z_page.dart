import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/isolates/cierre_z/cierre_z_models.dart' as cz;
import '../../../core/money/money.dart';
import '../../host/application/cierre_z_service.dart';
import '../../host/domain/host_snapshot.dart';
import '../../host/presentation/providers.dart';
import '../../host/presentation/widgets/forma_cobro.dart';
import '../../host/presentation/widgets/host_feedback.dart';
import '../../host/presentation/widgets/host_formatos.dart';
import '../../host/presentation/widgets/teclado_importe.dart';
import '../../host/presentation/widgets/ticket_detalle_dialog.dart';
import '../../sala/domain/ticket.dart';

Duration? _sinReintentos(int retryCount, Object error) => null;

/// Previsualización del Cierre Z con el efectivo contado indicado (nulo =
/// sin arqueo). Se recalcula cuando cambian los tickets o el turno.
final cierreZPreviewProvider = FutureProvider.autoDispose
    .family<CierreZPreview, int?>((ref, contadoCents) {
      ref.watch(
        hostSnapshotProvider.select(
          (s) => (s.value?.ticketsTurno, s.value?.cierreAbierto),
        ),
      );
      return ref
          .watch(cierreZServiceProvider)
          .previsualizar(efectivoContadoCents: contadoCents);
    }, retry: _sinReintentos);

/// Caja y Cierre Z: turno (fondo y retiradas), tickets del turno, informe,
/// arqueo, asiento propuesto (Debe/Haber) e historial de cierres.
class CierreZPage extends ConsumerStatefulWidget {
  const CierreZPage({super.key});

  @override
  ConsumerState<CierreZPage> createState() => _CierreZPageState();
}

class _CierreZPageState extends ConsumerState<CierreZPage> {
  int? _contadoCents;
  bool _cerrando = false;

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(hostSnapshotProvider).value;
    final preview = ref.watch(cierreZPreviewProvider(_contadoCents));
    if (snapshot == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final secciones = <Widget>[
      _seccionTurno(context, snapshot),
      _seccionArqueo(context, preview.value),
      switch (preview) {
        AsyncData(:final value) => _seccionInforme(context, value),
        AsyncError(:final error) => _Seccion(
          titulo: 'Informe',
          child: Text(
            'No se pudo calcular el cierre: ${mensajeDeError(error)}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        _ => const _Seccion(
          titulo: 'Informe',
          child: Center(child: CircularProgressIndicator()),
        ),
      },
      if (preview.value case final CierreZPreview p)
        _seccionAsiento(context, p),
      _seccionTickets(context, snapshot.ticketsTurno),
      _seccionHistorial(context, snapshot.historialCierres),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Caja y Cierre Z')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 1000) {
            final mitad = (secciones.length / 2).ceil();
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(children: secciones.sublist(0, mitad)),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: Column(children: secciones.sublist(mitad))),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: secciones,
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('imprimir-z'),
                  onPressed: preview.value == null
                      ? null
                      : () => unawaited(_imprimir(preview.value!)),
                  icon: const Icon(Icons.print_outlined),
                  label: const Text('Imprimir'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  key: const Key('cerrar-turno'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed:
                      _cerrando ||
                          preview.value == null ||
                          !_hayAlgoQueCerrar(snapshot)
                      ? null
                      : () => unawaited(_cerrar(preview.value!)),
                  icon: const Icon(Icons.lock_clock),
                  label: const Text('Cerrar turno'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Sin turno abierto ni tickets (por ejemplo, justo después de un cierre)
  /// no hay nada que cerrar: un segundo Z vacío contabilizaría como sobrante
  /// el fondo que queda en caja.
  static bool _hayAlgoQueCerrar(HostSnapshot snapshot) =>
      snapshot.cierreAbierto != null || snapshot.ticketsTurno.isNotEmpty;

  // ---------------------------------------------------------------------------
  // Secciones

  Widget _seccionTurno(BuildContext context, HostSnapshot snapshot) {
    final turno = snapshot.cierreAbierto;
    return _Seccion(
      titulo: 'Turno',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_hayAlgoQueCerrar(snapshot))
            const Text(
              'No hay nada que cerrar: no hay turno abierto ni tickets '
              'cobrados. Abre un turno para empezar.',
              key: Key('nada-que-cerrar'),
            )
          else if (turno == null)
            const Text(
              'No hay turno abierto. Si cobras sin abrirlo, el cierre usará '
              'un fondo de caja de 0 €.',
            )
          else ...[
            _Fila('Abierto', formatFechaHora(turno.abiertoEn)),
            _Fila('Fondo de caja', formatCents(turno.fondoCajaCents)),
            _Fila('Retiradas', formatCents(turno.retiradasCents)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (turno == null)
                FilledButton.icon(
                  key: const Key('abrir-turno'),
                  onPressed: () => unawaited(_abrirTurno()),
                  icon: const Icon(Icons.lock_open),
                  label: const Text('Abrir turno'),
                ),
              OutlinedButton.icon(
                key: const Key('registrar-retirada'),
                onPressed: () => unawaited(_retirada()),
                icon: const Icon(Icons.outbox_outlined),
                label: const Text('Retirada de efectivo'),
              ),
              OutlinedButton.icon(
                key: const Key('abrir-cajon'),
                onPressed: () => unawaited(_abrirCajon()),
                icon: const Icon(Icons.point_of_sale),
                label: const Text('Abrir cajón'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seccionArqueo(BuildContext context, CierreZPreview? preview) {
    final informe = preview?.informe;
    final theme = Theme.of(context);
    final descuadre = informe?.descuadreCents ?? 0;
    final contado = _contadoCents;
    return _Seccion(
      titulo: 'Arqueo',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (informe != null)
            _Fila(
              'Efectivo esperado',
              formatCents(informe.efectivoEsperadoCents),
              valorKey: const Key('efectivo-esperado'),
            ),
          _Fila(
            'Efectivo contado',
            contado == null ? 'Sin contar' : formatCents(contado),
            valorKey: const Key('efectivo-contado'),
          ),
          if (informe != null && contado != null)
            _Fila(
              descuadre < 0
                  ? 'Faltante'
                  : (descuadre > 0 ? 'Sobrante' : 'Descuadre'),
              formatCents(descuadre),
              valorKey: const Key('descuadre'),
              color: descuadre == 0 ? null : theme.colorScheme.error,
              destacado: true,
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const Key('contar-efectivo'),
              onPressed: () => unawaited(_contar()),
              icon: const Icon(Icons.calculate_outlined),
              label: Text(
                contado == null ? 'Contar efectivo' : 'Corregir recuento',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seccionInforme(BuildContext context, CierreZPreview preview) {
    final i = preview.informe;
    final theme = Theme.of(context);
    return _Seccion(
      titulo: 'Informe del turno',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Fila('Tickets', '${i.numTickets}', valorKey: const Key('z-tickets')),
          if (i.numAnulados > 0)
            _Fila(
              'Anulados',
              '${i.numAnulados} (${formatCents(i.importeAnuladoCents)})',
            ),
          _Fila(
            'Ventas totales',
            formatCents(i.ventasTotalCents),
            valorKey: const Key('z-ventas'),
            destacado: true,
          ),
          _Fila(
            'Efectivo',
            formatCents(i.ventasEfectivoCents),
            valorKey: const Key('z-efectivo'),
          ),
          _Fila(
            'Tarjeta',
            formatCents(i.ventasTarjetaCents),
            valorKey: const Key('z-tarjeta'),
          ),
          if (i.numTicketsMixtos > 0)
            // Sus partes ya están sumadas en efectivo y tarjeta.
            _Fila(
              'Tickets con cobro mixto',
              '${i.numTicketsMixtos}',
              valorKey: const Key('z-mixtos'),
            ),
          _Fila('Ticket medio', formatCents(i.ticketMedioCents)),
          if (i.porIva.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Ventas por tipo de IVA', style: theme.textTheme.titleSmall),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('IVA')),
                  DataColumn(label: Text('Base'), numeric: true),
                  DataColumn(label: Text('Cuota'), numeric: true),
                  DataColumn(label: Text('Total'), numeric: true),
                ],
                rows: [
                  for (final v in i.porIva)
                    DataRow(
                      cells: [
                        DataCell(
                          Text(formatPorcentaje(basisPointsToPercent(v.ivaBp))),
                        ),
                        DataCell(Text(formatCents(v.baseCents))),
                        DataCell(Text(formatCents(v.cuotaCents))),
                        DataCell(Text(formatCents(v.totalCents))),
                      ],
                    ),
                ],
              ),
            ),
          ],
          for (final aviso in i.avisos)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Aviso: $aviso',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _seccionAsiento(BuildContext context, CierreZPreview preview) {
    final asiento = preview.asiento;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final modo = switch (asiento.modo) {
      cz.ModoAsientoZ.soloDescuadre =>
        'Modo "solo descuadre": las ventas e IVA ya los contabiliza '
            'FacturaScripts con cada factura; el Cierre Z solo registra el '
            'descuadre de caja (659/759 contra 570).',
      cz.ModoAsientoZ.resumenCompleto =>
        'Modo "resumen completo" (570/572 contra 700/477): solo es correcto '
            'si las facturas NO generan asiento en FacturaScripts; de lo '
            'contrario duplicaría ventas e IVA.',
    };
    return _Seccion(
      titulo: 'Asiento propuesto',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: asiento.modo == cz.ModoAsientoZ.resumenCompleto
                  ? scheme.errorContainer
                  : scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(modo),
          ),
          const SizedBox(height: 8),
          if (asiento.vacio)
            const Text(
              'Sin descuadre: no hay nada que contabilizar.',
              key: Key('asiento-vacio'),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 20,
                columns: const [
                  DataColumn(label: Text('Subcuenta')),
                  DataColumn(label: Text('Concepto')),
                  DataColumn(label: Text('Debe'), numeric: true),
                  DataColumn(label: Text('Haber'), numeric: true),
                ],
                rows: [
                  for (final p in asiento.partidas)
                    DataRow(
                      cells: [
                        DataCell(Text(p.codsubcuenta)),
                        DataCell(Text(p.concepto)),
                        DataCell(
                          Text(
                            p.debeCents == 0 ? '' : formatCents(p.debeCents),
                          ),
                        ),
                        DataCell(
                          Text(
                            p.haberCents == 0 ? '' : formatCents(p.haberCents),
                          ),
                        ),
                      ],
                    ),
                  DataRow(
                    cells: [
                      const DataCell(
                        Text(
                          'Total',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const DataCell(Text('')),
                      DataCell(
                        Text(
                          formatCents(asiento.debeCents),
                          key: const Key('asiento-debe-total'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      DataCell(
                        Text(
                          formatCents(asiento.haberCents),
                          key: const Key('asiento-haber-total'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                asiento.cuadrado ? Icons.check_circle : Icons.error,
                color: asiento.cuadrado ? scheme.primary : scheme.error,
              ),
              const SizedBox(width: 8),
              Text(
                asiento.cuadrado ? 'Cuadrado (Debe = Haber)' : 'Descuadrado',
                key: const Key('asiento-cuadrado'),
                style: theme.textTheme.titleSmall,
              ),
            ],
          ),
          if (!asiento.vacio) ...[
            const SizedBox(height: 4),
            Text(
              preview.asientoContabilizable
                  ? 'Se contabilizará en FacturaScripts como '
                        '${asiento.documento} al cerrar el turno.'
                  : 'No se contabilizará: '
                        '${preview.motivoNoContabilizable ?? 'motivo desconocido'}.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _seccionTickets(BuildContext context, List<Ticket> tickets) {
    return _Seccion(
      titulo: 'Tickets del turno (${tickets.length})',
      child: tickets.isEmpty
          ? const Text('Todavía no hay tickets en este turno.')
          : Column(
              children: [
                for (final t in tickets.reversed)
                  ListTile(
                    key: Key('ticket-${t.id}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(iconoFormaCobro(t)),
                    title: Text(
                      'Nº ${t.numeroLocal} · ${t.nombreMesa} · '
                      '${formatHora(t.fechaHora)}',
                    ),
                    subtitle: Text(
                      t.esMixto
                          ? '${formatFormaCobro(t)}\n${_estadoFactura(t)}'
                          : _estadoFactura(t),
                      key: Key('ticket-${t.id}-detalle'),
                    ),
                    isThreeLine: t.esMixto,
                    trailing: Text(formatCents(t.totalCents)),
                    onTap: () => unawaited(mostrarDetalleTicket(context, t)),
                  ),
              ],
            ),
    );
  }

  static String _estadoFactura(Ticket t) {
    final f = t.factura;
    if (f == null) return 'Sin factura';
    return switch (f.estado) {
      EstadoSincronizacion.pendiente => 'Factura pendiente de enviar',
      EstadoSincronizacion.sincronizado =>
        'Factura ${f.codigo ?? f.idfactura?.toString() ?? ''}'.trim(),
      EstadoSincronizacion.error => 'Factura con error: ${f.error ?? ''}',
    };
  }

  Widget _seccionHistorial(BuildContext context, List<ResumenCierre> cierres) {
    return _Seccion(
      titulo: 'Historial de cierres',
      child: cierres.isEmpty
          ? const Text('Todavía no se ha cerrado ningún turno.')
          : Column(
              children: [
                for (final c in cierres)
                  ListTile(
                    key: Key('cierre-${c.id}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.history),
                    title: Text(
                      '${formatFechaHora(c.cerradoEn)} · ${c.numTickets} '
                      'tickets · ${formatCents(c.ventasTotalCents)}',
                    ),
                    subtitle: Text(
                      'Descuadre ${formatCents(c.descuadreCents)} · '
                      '${c.documentoAsiento == null ? 'sin asiento' : (c.asientoEncolado ? 'asiento ${c.documentoAsiento} en cola' : 'asiento ${c.documentoAsiento} no contabilizado')}',
                    ),
                  ),
              ],
            ),
    );
  }

  // ---------------------------------------------------------------------------
  // Acciones

  Future<void> _abrirTurno() async {
    final fondo = await pedirImporte(
      context,
      titulo: 'Fondo de caja',
      inicialCents: ref.read(fondoCajaPropuestoProvider),
      textoAceptar: 'Abrir turno',
    );
    if (fondo == null || !mounted) return;
    await ejecutarAccion(
      context,
      () => ref.read(cierreZServiceProvider).iniciarTurno(fondo),
      exito: 'Turno abierto con ${formatCents(fondo)}',
    );
  }

  Future<void> _retirada() async {
    final importe = await pedirImporte(
      context,
      titulo: 'Retirada de efectivo',
      minimoCents: 1,
      textoAceptar: 'Registrar',
    );
    if (importe == null || !mounted) return;
    await ejecutarAccion(
      context,
      () => ref.read(cierreZServiceProvider).registrarRetirada(importe),
      exito: 'Retirada de ${formatCents(importe)} registrada',
    );
  }

  /// Apertura manual del cajón (cambio, arqueo): un trabajo propio con el
  /// pulso en la impresora de tickets, sin registrar nada en el turno. Sin
  /// impresora de tickets, el error de `PrintingService.abrirCajon` lo dice.
  Future<void> _abrirCajon() => ejecutarAccion(
    context,
    () => ref.read(printingServiceProvider).abrirCajon(),
    exito: 'Apertura del cajón enviada a la impresora',
  );

  Future<int?> _contar() async {
    final contado = await pedirImporte(
      context,
      titulo: 'Efectivo contado en caja',
      inicialCents: _contadoCents ?? 0,
    );
    if (contado != null && mounted) setState(() => _contadoCents = contado);
    return contado;
  }

  Future<void> _imprimir(CierreZPreview preview) => ejecutarAccion(
    context,
    () => ref.read(printingServiceProvider).imprimirInformeZ(preview.result),
    exito: 'Informe enviado a la impresora',
  );

  Future<void> _cerrar(CierreZPreview preview) async {
    final contado = _contadoCents ?? await _contar();
    if (contado == null || !mounted) return;
    final esperado = preview.informe.efectivoEsperadoCents;
    final descuadre = contado - esperado;
    final ok = await confirmar(
      context,
      titulo: 'Cerrar turno',
      mensaje:
          '${preview.informe.numTickets} tickets · ventas '
          '${formatCents(preview.informe.ventasTotalCents)}.\n'
          'Efectivo esperado ${formatCents(esperado)}, contado '
          '${formatCents(contado)}, descuadre ${formatCents(descuadre)}.\n\n'
          'Se archivará el turno, se imprimirá el informe Z y se encolará el '
          'asiento si procede. No se puede deshacer.',
      textoAceptar: 'Cerrar turno',
      peligroso: true,
    );
    if (!ok || !mounted) return;
    setState(() => _cerrando = true);
    final hecho = await ejecutarAccion(
      context,
      () => ref
          .read(cierreZServiceProvider)
          .cerrar(efectivoContadoCents: contado),
      exito: 'Turno cerrado',
    );
    if (!mounted) return;
    setState(() {
      _cerrando = false;
      if (hecho) _contadoCents = null;
    });
  }
}

class _Seccion extends StatelessWidget {
  const _Seccion({required this.titulo, required this.child});

  final String titulo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titulo, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  const _Fila(
    this.etiqueta,
    this.valor, {
    this.valorKey,
    this.color,
    this.destacado = false,
  });

  final String etiqueta;
  final String valor;
  final Key? valorKey;
  final Color? color;
  final bool destacado;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final estilo =
        (destacado ? theme.textTheme.titleLarge : theme.textTheme.bodyLarge)
            ?.copyWith(color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta, style: theme.textTheme.bodyLarge)),
          Text(valor, key: valorKey, style: estilo),
        ],
      ),
    );
  }
}
