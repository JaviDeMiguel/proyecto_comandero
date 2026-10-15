/// Sección «Impresoras» de los ajustes del host, extraída de `SettingsPage`.
library;

import 'package:flutter/material.dart';

import '../../impresion/domain/formato_impresion.dart';
import 'settings_form.dart';
import 'settings_widgets.dart';

/// Nombre de cada impresora en la interfaz («Impresora de Cocina») y en la
/// página de prueba (`PaginaPruebaData.destino`).
extension EtiquetaRolImpresora on RolImpresora {
  String get etiqueta => switch (this) {
    RolImpresora.tickets => 'Tickets',
    RolImpresora.cocina => 'Cocina',
    RolImpresora.barra => 'Barra',
  };
}

/// Sección «Impresoras»: la dirección de cada impresora con su botón de
/// prueba, los interruptores de impresión y del cajón, y los accesos al
/// enrutamiento por familias y a «Tickets y comandas».
///
/// No tiene estado: `SettingsPage` le pasa los controladores, los valores y
/// los callbacks, y guarda la sección con el resto del formulario. El papel
/// no se elige aquí: es del perfil de cada impresora, que solo escribe
/// «Tickets y comandas» (un escritor por campo).
class SeccionImpresoras extends StatelessWidget {
  const SeccionImpresoras({
    super.key,
    required this.campos,
    required this.onProbar,
    required this.imprimirTicket,
    required this.onImprimirTicket,
    required this.imprimirComanda,
    required this.onImprimirComanda,
    required this.abrirCajon,
    required this.onAbrirCajon,
    this.probando = const {},
    this.reglasEnrutamiento = 0,
    this.onAbrirEnrutamiento,
    this.onAbrirTicketsYComandas,
  });

  /// Campo de la dirección (`ip:puerto`) de cada impresora, en el orden en
  /// que se muestran. Las claves de los widgets usan `RolImpresora.name`
  /// (`ajustes-impresora-cocina`, `ajustes-prueba-cocina`).
  final Map<RolImpresora, TextEditingController> campos;

  /// Envía la página de prueba a la dirección escrita para un rol.
  final ValueChanged<RolImpresora> onProbar;

  /// Impresoras con una página de prueba en curso: muestran un indicador en
  /// lugar del botón.
  final Set<RolImpresora> probando;

  final bool imprimirTicket;
  final ValueChanged<bool> onImprimirTicket;
  final bool imprimirComanda;
  final ValueChanged<bool> onImprimirComanda;
  final bool abrirCajon;
  final ValueChanged<bool> onAbrirCajon;

  /// Familias con destino propio en el enrutamiento guardado.
  final int reglasEnrutamiento;

  /// Abre el enrutamiento por familias. Si es nulo no se muestra el acceso.
  final VoidCallback? onAbrirEnrutamiento;

  /// Abre «Tickets y comandas». Si es nulo no se muestra el acceso.
  final VoidCallback? onAbrirTicketsYComandas;

  String get _resumenEnrutamiento => switch (reglasEnrutamiento) {
    0 => 'Todas las familias van al destino por defecto',
    1 => '1 familia con destino propio',
    final n => '$n familias con destino propio',
  };

  @override
  Widget build(BuildContext context) {
    return SeccionAjustes(
      titulo: 'Impresoras',
      icono: Icons.print_outlined,
      descripcion:
          'Impresoras térmicas ESC/POS en red (puerto 9100 por defecto). '
          'Vacío = sin impresora para ese destino.',
      children: [
        for (final MapEntry(key: rol, value: campo) in campos.entries)
          _FilaImpresora(
            rol: rol,
            campo: campo,
            probando: probando.contains(rol),
            onProbar: () => onProbar(rol),
          ),
        _Interruptor(
          clave: 'imprimir-ticket',
          titulo: 'Imprimir el ticket al cobrar',
          valor: imprimirTicket,
          onChanged: onImprimirTicket,
        ),
        _Interruptor(
          clave: 'imprimir-comanda',
          titulo: 'Imprimir las comandas en cocina/barra',
          valor: imprimirComanda,
          onChanged: onImprimirComanda,
        ),
        _Interruptor(
          clave: 'abrir-cajon',
          titulo: 'Abrir el cajón al cobrar en efectivo',
          valor: abrirCajon,
          onChanged: onAbrirCajon,
        ),
        if (onAbrirEnrutamiento case final abrir?)
          _Acceso(
            clave: 'ajustes-enrutamiento',
            icono: Icons.alt_route,
            titulo: 'Enrutamiento por familias',
            subtitulo:
                '$_resumenEnrutamiento. Elige qué familias salen por cocina '
                'y cuáles por barra.',
            onTap: abrir,
          ),
        if (onAbrirTicketsYComandas case final abrir?)
          _Acceso(
            clave: 'ajustes-tickets-comandas',
            icono: Icons.receipt_long,
            titulo: 'Tickets y comandas',
            subtitulo:
                'Papel, copias y avisos por impresora, formato del ticket, '
                'emisión, QR VeriFactu y pases',
            onTap: abrir,
          ),
      ],
    );
  }
}

/// Dirección de una impresora con su botón de página de prueba.
class _FilaImpresora extends StatelessWidget {
  const _FilaImpresora({
    required this.rol,
    required this.campo,
    required this.probando,
    required this.onProbar,
  });

  final RolImpresora rol;
  final TextEditingController campo;
  final bool probando;
  final VoidCallback onProbar;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextFormField(
            key: Key('ajustes-impresora-${rol.name}'),
            controller: campo,
            decoration: InputDecoration(
              labelText: 'Impresora de ${rol.etiqueta} (ip:puerto)',
            ),
            validator: validarImpresora,
            keyboardType: TextInputType.url,
            autovalidateMode: AutovalidateMode.onUserInteraction,
          ),
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: probando
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton.outlined(
                  key: Key('ajustes-prueba-${rol.name}'),
                  tooltip: 'Ticket de prueba',
                  icon: const Icon(Icons.receipt),
                  onPressed: onProbar,
                ),
        ),
      ],
    );
  }
}

/// Interruptor de la sección, con la clave `ajustes-<clave>`.
class _Interruptor extends StatelessWidget {
  const _Interruptor({
    required this.clave,
    required this.titulo,
    required this.valor,
    required this.onChanged,
  });

  final String clave;
  final String titulo;
  final bool valor;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    key: Key('ajustes-$clave'),
    contentPadding: EdgeInsets.zero,
    title: Text(titulo),
    value: valor,
    onChanged: onChanged,
  );
}

/// Acceso a otra pantalla de ajustes de impresión, con la clave [clave].
class _Acceso extends StatelessWidget {
  const _Acceso({
    required this.clave,
    required this.icono,
    required this.titulo,
    required this.subtitulo,
    required this.onTap,
  });

  final String clave;
  final IconData icono;
  final String titulo;
  final String subtitulo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    key: Key(clave),
    contentPadding: EdgeInsets.zero,
    leading: Icon(icono),
    title: Text(titulo),
    subtitle: Text(subtitulo),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}
