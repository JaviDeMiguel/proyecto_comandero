import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_exception.dart';
import '../../../core/network/discovery/udp_discovery_scanner.dart';
import '../../../core/network/protocol/transport_messages.dart';
import '../../settings/presentation/settings_providers.dart';
import '../domain/comandero_state.dart';
import 'comandero_carga.dart';
import 'comandero_config_mapper.dart';
import 'comandero_gateway.dart';
import 'comandero_widgets.dart';
import 'providers.dart';

/// Conexión con el host: estado de la sesión, hosts descubiertos por UDP,
/// conexión manual y código de emparejamiento.
class ConexionPage extends ConsumerStatefulWidget {
  const ConexionPage({super.key, this.onAbrirAjustes});

  /// Abre los ajustes de la aplicación. Si es `null` se ofrecen los ajustes
  /// propios del comandero (datos de conexión guardados).
  final VoidCallback? onAbrirAjustes;

  @override
  ConsumerState<ConexionPage> createState() => _ConexionPageState();
}

class _ConexionPageState extends ConsumerState<ConexionPage> {
  final TextEditingController _direccion = TextEditingController();
  final TextEditingController _codigo = TextEditingController();
  final TextEditingController _codigoRechazo = TextEditingController();

  /// Hosts de la última búsqueda (el estado deja de traerlos al conectar).
  List<DiscoveredHost> _hosts = const [];
  bool _buscando = false;

  /// Host manual con el que se rellenó por última vez [_direccion].
  String? _hostManualMostrado;
  bool _rellenado = false;

  @override
  void dispose() {
    _direccion.dispose();
    _codigo.dispose();
    _codigoRechazo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gatewayAsync = ref.watch(comanderoControllerProvider);
    final gateway = gatewayAsync.value;
    if (gateway == null) return CargandoComandero(error: gatewayAsync.error);
    final state = ref.watch(comanderoStateProvider).value ?? gateway.state;
    _rellenarUnaVez(gateway);
    // El host manual puede cambiar desde los ajustes con esta página abierta.
    ref.listen<String?>(
      appSettingsProvider.select((ajustes) => ajustes.value?.red.hostManual),
      (anterior, siguiente) => _rellenarDireccion(siguiente),
    );
    final hosts = switch (state) {
      Buscando(:final hosts) => hosts,
      SinHost(:final hostsEncontrados) when hostsEncontrados.isNotEmpty =>
        hostsEncontrados,
      _ => _hosts,
    };
    final buscando = _buscando || state is Buscando;
    final pendientes = pendientesDe(state, fallback: gateway.pendientes);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Conexión con el host'),
        actions: [
          IconButton(
            tooltip: 'Ajustes',
            icon: const Icon(Icons.settings),
            onPressed: widget.onAbrirAjustes ?? () => _abrirAjustes(gateway),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _TarjetaEstado(
              state: state,
              pendientes: pendientes,
              onVerMesas: Navigator.of(context).canPop()
                  ? () => Navigator.of(context).pop()
                  : null,
              onDesconectar: () => _desconectar(gateway),
            ),
            if (state case Rechazado(:final host?, :final codigo)) ...[
              const SizedBox(height: 12),
              _ReintentoRechazo(
                controller: _codigoRechazo,
                pideCodigo: codigo == RejectCodes.unauthorized,
                onReintentar: () => _reintentar(gateway, host),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Hosts en la red',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                FilledButton.tonalIcon(
                  key: const Key('conexion.buscar'),
                  onPressed: buscando ? null : () => _buscar(gateway),
                  icon: buscando
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: const Text('Buscar de nuevo'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (hosts.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  buscando
                      ? 'Buscando hosts en la red local…'
                      : 'No se ha encontrado ningún host. Comprueba que la '
                            'tablet de caja está encendida y en la misma red '
                            'Wi-Fi, o conecta a mano.',
                ),
              )
            else
              for (final host in hosts)
                _HostTile(
                  host: host,
                  actual: state.host?.hostId == host.hostId,
                  onTap: () => _conectarDescubierto(gateway, host),
                ),
            const SizedBox(height: 24),
            Text(
              'Conexión manual',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('conexion.direccion'),
              controller: _direccion,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Dirección del host',
                hintText: '192.168.1.10:4040',
                prefixIcon: Icon(Icons.lan),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('conexion.codigo'),
              controller: _codigo,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _conectarManual(gateway),
              decoration: const InputDecoration(
                labelText: 'Código de emparejamiento (si lo pide el host)',
                prefixIcon: Icon(Icons.key),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('conexion.conectarManual'),
              onPressed: () => _conectarManual(gateway),
              icon: const Icon(Icons.link),
              label: const Text('Conectar'),
            ),
          ],
        ),
      ),
    );
  }

  void _rellenarUnaVez(ComanderoGateway gateway) {
    if (_rellenado) return;
    _rellenado = true;
    _hostManualMostrado = gateway.config.hostManual;
    _direccion.text = _hostManualMostrado ?? '';
  }

  /// Muestra el host manual guardado si ha cambiado desde el último que se
  /// mostró (lo que el usuario esté escribiendo se respeta si no cambia).
  void _rellenarDireccion(String? hostManual) {
    final limpio = (hostManual ?? '').trim();
    final valor = limpio.isEmpty ? null : limpio;
    if (valor == _hostManualMostrado) return;
    _hostManualMostrado = valor;
    _direccion.text = valor ?? '';
  }

  Future<void> _buscar(ComanderoGateway gateway) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _buscando = true);
    try {
      final hosts = await gateway.buscarHosts();
      if (!mounted) return;
      setState(() => _hosts = hosts);
      if (hosts.isEmpty) {
        mostrarMensaje(messenger, 'No ha respondido ningún host');
      }
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  Future<void> _conectarDescubierto(
    ComanderoGateway gateway,
    DiscoveredHost host,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    String? codigo;
    if (host.requiresPairing && (gateway.config.pairingCode ?? '').isEmpty) {
      codigo = await _pedirCodigo(host.hostName);
      if (codigo == null || !mounted) return;
    }
    // Se conecta antes de guardar: así, al aplicar los ajustes guardados, el
    // controlador ya tiene este host y este código y no reconecta.
    try {
      gateway.conectarDescubierto(host, pairingCode: codigo);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    // Elegir un host descubierto anula el host manual guardado.
    final aviso = await guardarDatosConexion(
      ref,
      pairingCode: codigo,
      borrarHostManual: true,
    );
    if (!mounted) return;
    if (aviso != null) {
      mostrarMensaje(messenger, 'No se guardó la conexión: $aviso');
    }
  }

  Future<void> _conectarManual(ComanderoGateway gateway) async {
    final messenger = ScaffoldMessenger.of(context);
    final String direccion;
    try {
      direccion = normalizarHostManual(_direccion.text);
    } on ValidationException catch (error) {
      mostrarMensaje(messenger, error.message, error: true);
      return;
    }
    final codigo = _codigo.text.trim();
    try {
      gateway.conectarManual(
        direccion,
        pairingCode: codigo.isEmpty ? null : codigo,
      );
    } on AppException catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    _hostManualMostrado = direccion;
    _direccion.text = direccion;
    _codigo.clear();
    final aviso = await guardarDatosConexion(
      ref,
      hostManual: direccion,
      pairingCode: codigo.isEmpty ? null : codigo,
    );
    if (!mounted) return;
    if (aviso != null) {
      mostrarMensaje(messenger, 'No se guardó la conexión: $aviso');
    }
  }

  Future<void> _reintentar(ComanderoGateway gateway, HostObjetivo host) async {
    final messenger = ScaffoldMessenger.of(context);
    final codigo = _codigoRechazo.text.trim();
    try {
      gateway.conectar(host, pairingCode: codigo.isEmpty ? null : codigo);
    } on StateError catch (error) {
      mostrarMensaje(messenger, describirError(error), error: true);
      return;
    }
    _codigoRechazo.clear();
    String? aviso;
    if (codigo.isNotEmpty) {
      aviso = await guardarDatosConexion(ref, pairingCode: codigo);
      if (!mounted) return;
    }
    if (aviso != null) {
      mostrarMensaje(messenger, 'No se guardó el código: $aviso');
    }
  }

  Future<void> _desconectar(ComanderoGateway gateway) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Desconectar del host?'),
        content: const Text(
          'Los envíos pendientes se cancelarán y sus líneas volverán al '
          'carrito de cada mesa.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Desconectar'),
          ),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    // Sin host manual, para que el próximo arranque vuelva a buscar.
    await guardarDatosConexion(ref, borrarHostManual: true);
    try {
      await gateway.desconectar();
    } on StateError {
      // Ya liberado: nada que cerrar.
    }
  }

  Future<String?> _pedirCodigo(String hostName) => showDialog<String>(
    context: context,
    builder: (_) => _DialogoCodigo(hostName: hostName),
  );

  Future<void> _abrirAjustes(ComanderoGateway gateway) async {
    final config = gateway.config;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.smartphone),
              title: Text(config.deviceName),
              subtitle: Text('Identificador: ${config.deviceId}'),
            ),
            ListTile(
              leading: const Icon(Icons.lan),
              title: const Text('Olvidar el host manual'),
              subtitle: Text(config.hostManual ?? 'No hay host manual'),
              enabled: config.hostManual != null,
              onTap: () async {
                Navigator.of(context).pop();
                await guardarDatosConexion(ref, borrarHostManual: true);
                if (mounted) _direccion.clear();
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_off),
              title: const Text('Borrar el código de emparejamiento'),
              enabled: (config.pairingCode ?? '').isNotEmpty,
              onTap: () async {
                Navigator.of(context).pop();
                await guardarDatosConexion(ref, borrarPairingCode: true);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _TarjetaEstado extends StatelessWidget {
  const _TarjetaEstado({
    required this.state,
    required this.pendientes,
    required this.onVerMesas,
    required this.onDesconectar,
  });

  final ComanderoState state;
  final int pendientes;
  final VoidCallback? onVerMesas;
  final VoidCallback onDesconectar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final explicacion = switch (state) {
      SinHost(:final error?) =>
        'No se pudo buscar el host: ${describirError(error)}',
      SinHost() =>
        'Elige el host de la lista o escribe su dirección para empezar.',
      Buscando() => 'Preguntando por la red local quién es la caja…',
      Conectando() => 'Abriendo la sesión y cargando mesas y carta.',
      Conectado(:final sala, :final catalogo) =>
        '${sala.mesas.length} mesas · '
            '${catalogo == null ? 'carta pendiente' : '${catalogo.vendibles.length} artículos en carta'}',
      Reconectando(:final reintentoEn, :final error) =>
        'Se perdió la conexión'
            '${error == null ? '' : ' (${describirError(error)})'}. '
            'Nuevo intento en ${_segundos(reintentoEn)}.',
      Rechazado(:final codigo, :final mensaje) => explicarRechazo(
        codigo,
        mensaje,
      ),
    };
    final ocupado = state is Conectando || state is Buscando;
    final reconectando = state is Reconectando;
    return Card(
      key: const Key('conexion.estado'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IndicadorConexion(state: state),
                const Spacer(),
              ],
            ),
            const SizedBox(height: 8),
            Text(etiquetaEstado(state), style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(explicacion),
            if (pendientes > 0) ...[
              const SizedBox(height: 8),
              Text(
                pendientes == 1
                    ? '1 envío pendiente de confirmar por el host.'
                    : '$pendientes envíos pendientes de confirmar por el '
                          'host.',
                style: TextStyle(color: Colors.orange.shade800),
              ),
            ],
            if (ocupado || reconectando) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (state is Conectado && onVerMesas != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onVerMesas,
                icon: const Icon(Icons.table_restaurant),
                label: const Text('Ver mesas'),
              ),
            ],
            if (state.host != null) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('conexion.desconectar'),
                onPressed: onDesconectar,
                icon: const Icon(Icons.link_off),
                label: Text(
                  reconectando ? 'Dejar de intentarlo' : 'Desconectar',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _segundos(Duration duracion) {
    final segundos = (duracion.inMilliseconds / 1000).ceil();
    return segundos <= 1 ? '1 segundo' : '$segundos segundos';
  }
}

/// Pide el código de emparejamiento de un host. El controlador del texto vive
/// con el diálogo (no se libera mientras se anima su cierre).
class _DialogoCodigo extends StatefulWidget {
  const _DialogoCodigo({required this.hostName});

  final String hostName;

  @override
  State<_DialogoCodigo> createState() => _DialogoCodigoState();
}

class _DialogoCodigoState extends State<_DialogoCodigo> {
  final TextEditingController _codigo = TextEditingController();

  @override
  void dispose() {
    _codigo.dispose();
    super.dispose();
  }

  void _aceptar() {
    final codigo = _codigo.text.trim();
    if (codigo.isNotEmpty) Navigator.of(context).pop(codigo);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Código de ${widget.hostName}'),
      content: TextField(
        key: const Key('conexion.dialogoCodigo'),
        controller: _codigo,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Código de emparejamiento',
          helperText: 'Lo encontrarás en los ajustes de la caja',
        ),
        onSubmitted: (_) => _aceptar(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _aceptar, child: const Text('Conectar')),
      ],
    );
  }
}

class _ReintentoRechazo extends StatelessWidget {
  const _ReintentoRechazo({
    required this.controller,
    required this.pideCodigo,
    required this.onReintentar,
  });

  final TextEditingController controller;
  final bool pideCodigo;
  final VoidCallback onReintentar;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pideCodigo) ...[
          TextField(
            key: const Key('conexion.codigoRechazo'),
            controller: controller,
            obscureText: true,
            onSubmitted: (_) => onReintentar(),
            decoration: const InputDecoration(
              labelText: 'Código de emparejamiento',
              prefixIcon: Icon(Icons.key),
            ),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton.icon(
          key: const Key('conexion.reintentar'),
          onPressed: onReintentar,
          icon: const Icon(Icons.refresh),
          label: const Text('Reintentar'),
        ),
      ],
    );
  }
}

class _HostTile extends StatelessWidget {
  const _HostTile({
    required this.host,
    required this.actual,
    required this.onTap,
  });

  final DiscoveredHost host;
  final bool actual;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: Key('conexion.host.${host.hostId}'),
        minVerticalPadding: 12,
        leading: Icon(actual ? Icons.check_circle : Icons.point_of_sale),
        title: Text(host.hostName),
        subtitle: Text('${host.address.address}:${host.tcpPort}'),
        trailing: host.requiresPairing
            ? const Chip(
                avatar: Icon(Icons.lock, size: 16),
                label: Text('Requiere código'),
              )
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
