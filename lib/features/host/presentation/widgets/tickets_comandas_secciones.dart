/// Secciones de ajustes de la página «Tickets y comandas» (§7.2 del diseño
/// de impresión): impresoras, ticket del cliente, emisión al cobrar, QR
/// VeriFactu y pases, y los controles que comparten.
///
/// Son widgets sin estado: reciben los valores del borrador y avisan de cada
/// cambio con un callback. El borrador, el guardado, el runtime, la tarjeta
/// del emisor y la columna de la vista previa viven en `TicketsComandasPage`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../core/fiscal/verifactu_qr.dart'
    show EntornoVerifactu, ModoQrVerifactu;
import '../../../../core/isolates/escpos/escpos_builder.dart'
    show PaperWidth, ZumbadorModo;
import '../../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../../impresion/domain/formato_impresion.dart';
import '../../../sala/domain/pases.dart';
import '../../../settings/presentation/settings_impresoras.dart'
    show EtiquetaRolImpresora;

/// Explicación de por qué no se ofrece el zumbador en el conector del cajón.
const String textoZumbadorBloqueado =
    'Esta impresora lleva el cajón: un zumbador en ese conector lo abriría en '
    'cada comanda';

/// Primera nota fija del QR VeriFactu (decisión B).
const String textoQrAlcance =
    'Solo en la factura simplificada (original y duplicado). Este TPV no '
    'registra la factura en VeriFactu: actívalo solo si FacturaScripts tiene '
    'el plugin Verifactu configurado en el mismo modo';

/// Nota del QR: validarlo en la impresora real antes de activarlo (§9.3).
const String textoQrNota =
    'Antes de activarlo, imprime la factura de muestra en la impresora real '
    '(entorno de pruebas) y pasa la lista de comprobación de impresoras: el '
    'QR debe leerse y medir entre 30 y 40 mm';

/// Aviso de la tarjeta del emisor cuando la cabecera no tiene NIF.
const String textoSinNif =
    'Sin NIF no se pueden imprimir facturas simplificadas';

/// Motivo de los botones que necesitan el runtime cuando no está listo.
const String textoSinRuntime = 'El TPV no está en marcha';

/// Una impresora física de los ajustes, con los roles que la usan y el
/// perfil que le aplica `resolverPerfil` con el borrador.
final class ImpresoraFormato {
  const ImpresoraFormato({
    required this.endpoint,
    required this.roles,
    required this.perfil,
    required this.sirveATickets,
    this.rolesConPerfilesDistintos = const [],
  });

  final PrinterEndpoint endpoint;

  /// Roles cuya dirección es [endpoint] (orden tickets, cocina, barra).
  final List<RolImpresora> roles;

  /// Perfil resuelto (con la guarda del cajón ya aplicada).
  final PerfilImpresora perfil;

  /// Es la impresora que imprime los tickets (`paraTickets`).
  final bool sirveATickets;

  /// Roles de [roles] con perfiles guardados distintos entre sí (vacío si
  /// coinciden o solo hay uno).
  final List<RolImpresora> rolesConPerfilesDistintos;

  /// Primer rol: da nombre a las claves de los controles de la tarjeta.
  RolImpresora get rol => roles.first;

  /// Sirve comandas (cocina o barra): admite avance, copias y aviso.
  bool get preparacion =>
      roles.contains(RolImpresora.cocina) || roles.contains(RolImpresora.barra);

  bool get perfilesDistintos => rolesConPerfilesDistintos.isNotEmpty;
}

/// «Tickets», «Tickets y Cocina», «Tickets, Cocina y Barra».
String enumerarRoles(List<RolImpresora> roles) {
  final nombres = [for (final rol in roles) rol.etiqueta];
  if (nombres.length < 2) return nombres.join();
  return '${nombres.sublist(0, nombres.length - 1).join(', ')} y '
      '${nombres.last}';
}

/// Icono de un botón o, mientras dura su acción, un indicador de progreso.
Widget iconoOProgreso({required bool cargando, required IconData icono}) =>
    cargando
    ? const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      )
    : Icon(icono);

/// Selector de una opción entre [opciones] (valor y texto), con la clave
/// [clave]; las de [desactivadas] se ven pero no se pueden elegir. En un
/// ancho de móvil que no le basta, se desplaza en horizontal.
Widget selectorOpciones<T extends Object>({
  required String clave,
  required T valor,
  required List<(T, String)> opciones,
  required ValueChanged<T> onChanged,
  Set<T> desactivadas = const {},
}) => SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  child: SegmentedButton<T>(
    key: Key(clave),
    showSelectedIcon: false,
    segments: [
      for (final (v, texto) in opciones)
        ButtonSegment(
          value: v,
          label: Text(texto),
          enabled: !desactivadas.contains(v),
        ),
    ],
    selected: {valor},
    onSelectionChanged: (s) => onChanged(s.first),
  ),
);

/// Selector de papel de 58 mm, 80 mm y 80 mm a 180 ppp.
Widget selectorPapel({
  required String clave,
  required PaperWidth papel,
  required ValueChanged<PaperWidth> onChanged,
}) => selectorOpciones(
  clave: clave,
  valor: papel,
  opciones: [for (final p in PaperWidth.values) (p, p.etiqueta)],
  onChanged: onChanged,
);

Widget _interruptor(
  String clave,
  String titulo,
  bool valor,
  ValueChanged<bool>? onChanged, {
  String? subtitulo,
}) => SwitchListTile(
  key: Key(clave),
  contentPadding: EdgeInsets.zero,
  title: Text(titulo),
  subtitle: subtitulo == null ? null : Text(subtitulo),
  value: valor,
  onChanged: onChanged,
);

/// Título de sección.
class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 8),
    child: Text(
      texto.toUpperCase(),
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        letterSpacing: 1.2,
      ),
    ),
  );
}

/// Texto secundario de ayuda.
class TextoAyuda extends StatelessWidget {
  const TextoAyuda(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(texto, style: Theme.of(context).textTheme.bodySmall),
  );
}

/// Banda de aviso con icono.
class BandaAviso extends StatelessWidget {
  const BandaAviso(this.texto, {super.key});

  final String texto;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              texto,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fila con una etiqueta a la izquierda y el control a la derecha.
class _Fila extends StatelessWidget {
  const _Fila(this.etiqueta, this.control);

  final String etiqueta;
  final Widget control;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(width: 150, child: Text(etiqueta)),
        control,
      ],
    ),
  );
}

/// Contador `[-] n [+]` acotado a [min]..[max]. Los botones llevan las
/// claves `<clave>-menos` y `<clave>-mas`; [descripcion] («copias de
/// comandas») da sus tooltips («Menos copias de comandas») y la etiqueta
/// accesible del valor.
class Contador extends StatelessWidget {
  Contador({
    required this.clave,
    required this.descripcion,
    required this.valor,
    required this.min,
    required this.max,
    required this.onChanged,
    this.sufijo,
  }) : super(key: ValueKey<String>(clave));

  final String clave;
  final String descripcion;
  final int valor;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  final String? sufijo;

  // Wrap y no Row: en un móvil estrecho el sufijo baja de línea.
  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      IconButton(
        key: ValueKey<String>('$clave-menos'),
        tooltip: 'Menos $descripcion',
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: valor > min ? () => onChanged(valor - 1) : null,
      ),
      Semantics(
        label: descripcion,
        value: '$valor${sufijo == null ? '' : ' $sufijo'}',
        excludeSemantics: true,
        child: SizedBox(
          width: 40,
          child: Text(
            '$valor',
            key: ValueKey<String>('$clave-valor'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ),
      IconButton(
        key: ValueKey<String>('$clave-mas'),
        tooltip: 'Más $descripcion',
        icon: const Icon(Icons.add_circle_outline),
        onPressed: valor < max ? () => onChanged(valor + 1) : null,
      ),
      if (sufijo case final texto?) Text(texto),
    ],
  );
}

/// Sección 1: una tarjeta por impresora física.
class SeccionImpresorasFormato extends StatelessWidget {
  const SeccionImpresorasFormato({
    super.key,
    required this.impresoras,
    required this.onCambiar,
  });

  final List<ImpresoraFormato> impresoras;

  /// Perfil editado de una tarjeta (la página lo escribe en todos sus
  /// roles).
  final void Function(ImpresoraFormato impresora, PerfilImpresora perfil)
  onCambiar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Titulo('Impresoras'),
      if (impresoras.isEmpty)
        const Card(
          key: Key('tc-sin-impresoras'),
          child: ListTile(
            leading: Icon(Icons.print_disabled_outlined),
            title: Text('Configura las impresoras en Ajustes > Impresoras'),
          ),
        ),
      for (final impresora in impresoras)
        _TarjetaImpresora(
          impresora: impresora,
          onCambiar: (perfil) => onCambiar(impresora, perfil),
        ),
    ],
  );
}

class _TarjetaImpresora extends StatelessWidget {
  const _TarjetaImpresora({required this.impresora, required this.onCambiar});

  final ImpresoraFormato impresora;
  final ValueChanged<PerfilImpresora> onCambiar;

  @override
  Widget build(BuildContext context) {
    final perfil = impresora.perfil;
    final rol = impresora.rol.name;
    final theme = Theme.of(context);
    final roles = [for (final r in impresora.roles) r.etiqueta].join(' · ');
    return Card(
      key: Key('tc-impresora-$rol'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.print, color: theme.colorScheme.primary),
              title: Text(
                '$roles — ${claveImpresora(impresora.endpoint)}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            if (impresora.perfilesDistintos)
              BandaAviso(
                '${enumerarRoles(impresora.rolesConPerfilesDistintos)} '
                'comparten esta impresora con perfiles distintos; se usa el '
                'guardado para esta dirección. Guarda para unificarlos',
                key: Key('tc-aviso-perfiles-$rol'),
              ),
            _Fila(
              'Papel',
              selectorPapel(
                clave: 'tc-papel-$rol',
                papel: perfil.papel,
                onChanged: (p) => onCambiar(perfil.copyWith(papel: p)),
              ),
            ),
            if (impresora.preparacion) ..._preparacion(perfil, rol),
          ],
        ),
      ),
    );
  }

  List<Widget> _preparacion(PerfilImpresora perfil, String rol) => [
    _Fila(
      'Avance inicial',
      Contador(
        clave: 'tc-avance-$rol',
        descripcion: 'avance inicial',
        valor: perfil.lineasIniciales,
        min: 0,
        max: PerfilImpresora.maxLineasIniciales,
        sufijo: 'líneas en blanco',
        onChanged: (n) => onCambiar(perfil.copyWith(lineasIniciales: n)),
      ),
    ),
    _Fila(
      'Copias de comandas',
      Contador(
        clave: 'tc-copias-$rol',
        descripcion: 'copias de comandas',
        valor: perfil.copias,
        min: PerfilImpresora.minCopias,
        max: PerfilImpresora.maxCopias,
        onChanged: (n) => onCambiar(perfil.copyWith(copias: n)),
      ),
    ),
    _Fila(
      'Aviso sonoro',
      selectorOpciones(
        clave: 'tc-zumbador-$rol',
        valor: perfil.zumbador,
        opciones: const [
          (ZumbadorModo.ninguno, 'Ninguno'),
          (ZumbadorModo.generico, 'Pitido'),
          (ZumbadorModo.puertoCajon, 'Zumbador'),
        ],
        desactivadas: {if (impresora.sirveATickets) ZumbadorModo.puertoCajon},
        onChanged: (modo) => onCambiar(_conZumbador(perfil, modo)),
      ),
    ),
    TextoAyuda(
      impresora.sirveATickets
          ? textoZumbadorBloqueado
          : 'Pitido: zumbador interno de la impresora. Zumbador: el '
                'conectado al conector del cajón.',
      key: impresora.sirveATickets ? Key('tc-zumbador-bloqueado-$rol') : null,
    ),
    if (perfil.zumbador != ZumbadorModo.ninguno)
      _Fila(
        'Pitidos',
        Contador(
          clave: 'tc-pitidos-$rol',
          descripcion: 'pitidos',
          valor: perfil.pitidos,
          min: PerfilImpresora.minPitidos,
          max: PerfilImpresora.maxPitidosDe(perfil.zumbador),
          onChanged: (n) => onCambiar(perfil.copyWith(pitidos: n)),
        ),
      ),
    if (perfil.zumbador == ZumbadorModo.puertoCajon)
      _Fila(
        'Pin del conector',
        selectorOpciones(
          clave: 'tc-pin-$rol',
          valor: perfil.pinZumbador,
          opciones: [
            for (final pin in PerfilImpresora.pinesZumbador)
              (
                pin,
                pin == PerfilImpresora.pinZumbadorPorDefecto
                    ? '$pin (recomendado)'
                    : '$pin',
              ),
          ],
          onChanged: (pin) => onCambiar(perfil.copyWith(pinZumbador: pin)),
        ),
      ),
  ];

  /// Cambia el modo de aviso acotando los pitidos al máximo del modo nuevo.
  static PerfilImpresora _conZumbador(PerfilImpresora p, ZumbadorModo modo) =>
      p.copyWith(
        zumbador: modo,
        pitidos: p.pitidos.clamp(
          PerfilImpresora.minPitidos,
          PerfilImpresora.maxPitidosDe(modo),
        ),
      );
}

/// Sección 2: ticket del cliente y tarjeta del emisor.
class SeccionTicketCliente extends StatelessWidget {
  const SeccionTicketCliente({
    super.key,
    required this.formato,
    required this.nombreComercial,
    required this.pie,
    required this.onCambiar,
    required this.pistaNombreComercial,
    required this.tarjetaEmisor,
  });

  final FormatoTicket formato;
  final TextEditingController nombreComercial;
  final TextEditingController pie;
  final ValueChanged<FormatoTicket> onCambiar;

  /// `nombrecorto` de la empresa de FacturaScripts, si se conoce.
  final String? pistaNombreComercial;

  /// Tarjeta del emisor en caché, con «Actualizar desde FacturaScripts».
  final Widget tarjetaEmisor;

  @override
  Widget build(BuildContext context) {
    final pista = pistaNombreComercial?.trim();
    final f = formato;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Titulo('Ticket del cliente'),
        TextField(
          key: const Key('tc-nombre-comercial'),
          controller: nombreComercial,
          maxLength: FormatoTicket.maxNombreComercial,
          decoration: InputDecoration(
            labelText: 'Nombre comercial',
            hintText: pista == null || pista.isEmpty ? null : pista,
            helperText: 'Vacío: el nombre corto de FacturaScripts',
          ),
          onChanged: (texto) => onCambiar(
            texto.trim().isEmpty
                ? f.copyWith(borrarNombreComercial: true)
                : f.copyWith(nombreComercial: texto.trim()),
          ),
        ),
        TextField(
          key: const Key('tc-pie'),
          controller: pie,
          minLines: 1,
          maxLines: FormatoTicket.maxLineasPie,
          maxLength: FormatoTicket.maxPie,
          keyboardType: TextInputType.multiline,
          inputFormatters: [_maxLineas(FormatoTicket.maxLineasPie)],
          decoration: const InputDecoration(
            labelText: 'Pie del ticket',
            helperText: 'Hasta 3 líneas',
          ),
          onChanged: (texto) => onCambiar(
            texto.trim().isEmpty
                ? f.copyWith(borrarPie: true)
                : f.copyWith(pie: texto.trimRight()),
          ),
        ),
        _interruptor(
          'tc-notas',
          'Mostrar las notas de cocina en tickets y precuentas',
          f.mostrarNotas,
          (v) => onCambiar(f.copyWith(mostrarNotas: v)),
        ),
        _interruptor(
          'tc-iva-incluido',
          'Imprimir «IVA incluido»',
          f.ivaIncluido,
          (v) => onCambiar(f.copyWith(ivaIncluido: v)),
        ),
        _interruptor(
          'tc-camarero',
          'Mostrar el camarero',
          f.mostrarCamarero,
          (v) => onCambiar(f.copyWith(mostrarCamarero: v)),
        ),
        _interruptor(
          'tc-comensales',
          'Mostrar los comensales',
          f.mostrarComensales,
          (v) => onCambiar(f.copyWith(mostrarComensales: v)),
          subtitulo: 'Apagado, tampoco sale «Por comensal»',
        ),
        tarjetaEmisor,
      ],
    );
  }

  /// Rechaza los cambios que dejarían más de [max] líneas.
  static TextInputFormatter _maxLineas(int max) =>
      TextInputFormatter.withFunction(
        (anterior, nuevo) =>
            '\n'.allMatches(nuevo.text).length >= max ? anterior : nuevo,
      );
}

/// Sección 3: emisión al cobrar.
class SeccionEmision extends StatelessWidget {
  const SeccionEmision({
    super.key,
    required this.emision,
    required this.imprimirTicketAlCobrar,
    required this.onCambiar,
  });

  final EmisionTicket emision;

  /// Interruptor general de Ajustes > Impresoras (solo se informa).
  final bool imprimirTicketAlCobrar;
  final ValueChanged<EmisionTicket> onCambiar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Titulo('Emisión al cobrar'),
      RadioGroup<ModoEmision>(
        key: const Key('tc-modo-emision'),
        groupValue: emision.modo,
        onChanged: (modo) {
          if (modo != null) onCambiar(emision.copyWith(modo: modo));
        },
        child: const Column(
          children: [
            RadioListTile<ModoEmision>(
              contentPadding: EdgeInsets.zero,
              value: ModoEmision.alInstante,
              title: Text('Imprimir al instante (documento provisional)'),
            ),
            RadioListTile<ModoEmision>(
              contentPadding: EdgeInsets.zero,
              value: ModoEmision.facturaAlCobrar,
              title: Text('Emitir factura al cobrar'),
              subtitle: Text(
                'Espera a la factura de FacturaScripts; si no llega a '
                'tiempo, imprime el documento provisional',
              ),
            ),
          ],
        ),
      ),
      if (emision.modo == ModoEmision.facturaAlCobrar)
        _Fila(
          'Esperar hasta',
          Contador(
            clave: 'tc-espera',
            descripcion: 'segundos de espera de la factura',
            valor: emision.esperaSegundos,
            min: EmisionTicket.minEsperaSegundos,
            max: EmisionTicket.maxEsperaSegundos,
            sufijo: 's',
            onChanged: (s) => onCambiar(emision.copyWith(esperaSegundos: s)),
          ),
        ),
      TextoAyuda(
        imprimirTicketAlCobrar
            ? '«Imprimir el ticket al cobrar» está activado (se cambia en '
                  'Ajustes > Impresoras).'
            : '«Imprimir el ticket al cobrar» está desactivado en Ajustes > '
                  'Impresoras: al cobrar no se imprime nada.',
      ),
    ],
  );
}

/// Sección 4: QR VeriFactu.
class SeccionQrVerifactu extends StatelessWidget {
  const SeccionQrVerifactu({
    super.key,
    required this.verifactu,
    required this.onCambiar,
  });

  final QrVerifactuConfig verifactu;
  final ValueChanged<QrVerifactuConfig> onCambiar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Titulo('QR VeriFactu'),
      Wrap(
        spacing: 16,
        runSpacing: 8,
        children: [
          selectorOpciones(
            clave: 'tc-qr-modo',
            valor: verifactu.modo,
            opciones: const [
              (ModoQrVerifactu.desactivado, 'Desactivado'),
              (ModoQrVerifactu.verifactu, 'VERI*FACTU'),
              (ModoQrVerifactu.noVerifactu, 'NO VERI*FACTU'),
            ],
            onChanged: (m) => onCambiar(verifactu.copyWith(modo: m)),
          ),
          selectorOpciones(
            clave: 'tc-qr-entorno',
            valor: verifactu.entorno,
            opciones: const [
              (EntornoVerifactu.produccion, 'Producción'),
              (EntornoVerifactu.pruebas, 'Pruebas'),
            ],
            onChanged: (e) => onCambiar(verifactu.copyWith(entorno: e)),
          ),
        ],
      ),
      const TextoAyuda(textoQrAlcance),
      const BandaAviso(textoQrNota, key: Key('tc-qr-nota')),
    ],
  );
}

/// Sección 5: pases. Los nombres se pueden editar aunque los pases estén
/// apagados: se guardan igual y tienen que ser válidos (un nombre vacío
/// haría que los ajustes cargasen los pases por defecto, activos).
class SeccionPases extends StatelessWidget {
  const SeccionPases({
    super.key,
    required this.pases,
    required this.nombres,
    required this.onCambiar,
    required this.onNombre,
    required this.onAnadir,
    required this.onQuitar,
    this.error,
  });

  final PasesConfig pases;

  /// Un controlador por pase, en orden.
  final List<TextEditingController> nombres;

  /// Cambios de los interruptores.
  final ValueChanged<PasesConfig> onCambiar;
  final void Function(int indice, String texto) onNombre;
  final VoidCallback onAnadir;
  final ValueChanged<int> onQuitar;

  /// Por qué no se pueden guardar los nombres (vacío o demasiado largo).
  final String? error;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _Titulo('Pases'),
      _interruptor(
        'tc-pases-activos',
        'Usar pases',
        pases.activos,
        (v) => onCambiar(pases.copyWith(activos: v)),
      ),
      _interruptor(
        'tc-marchar-primero',
        'Marchar el primer pase al enviar',
        pases.marcharAlEnviar,
        pases.activos
            ? (v) => onCambiar(pases.copyWith(marcharAlEnviar: v))
            : null,
      ),
      for (final (i, controlador) in nombres.indexed)
        Row(
          children: [
            SizedBox(width: 28, child: Text('${i + 1}')),
            Expanded(
              child: TextField(
                key: Key('tc-pase-nombre-${i + 1}'),
                controller: controlador,
                maxLength: PasesConfig.maxLongitudNombre,
                decoration: const InputDecoration(
                  isDense: true,
                  counterText: '',
                ),
                onChanged: (texto) => onNombre(i, texto),
              ),
            ),
            IconButton(
              key: Key('tc-pase-quitar-${i + 1}'),
              tooltip: 'Quitar el pase',
              icon: const Icon(Icons.delete_outline),
              onPressed: nombres.length > 1 ? () => onQuitar(i) : null,
            ),
          ],
        ),
      if (error case final texto?)
        BandaAviso(texto, key: const Key('tc-pases-error')),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('tc-pase-anadir'),
          onPressed: nombres.length < PasesConfig.maxPases ? onAnadir : null,
          icon: const Icon(Icons.add),
          label: const Text('Añadir (máximo ${PasesConfig.maxPases})'),
        ),
      ),
      const TextoAyuda(
        'Los comanderos conectados reciben el cambio al guardar.',
      ),
    ],
  );
}
