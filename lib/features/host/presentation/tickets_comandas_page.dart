import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/isolates/escpos/ticket_documents.dart' show EmpresaTicket;
import '../../impresion/domain/formato_impresion.dart';
import '../../sala/domain/linea_comanda.dart' show DestinoPreparacion;
import '../../sala/domain/pases.dart';
import '../../settings/domain/app_settings.dart';
import '../../settings/presentation/settings_impresoras.dart'
    show EtiquetaRolImpresora;
import '../../settings/presentation/settings_providers.dart';
import '../application/host_runtime.dart';
import '../application/impresion/mapeo_documentos.dart' show componerCabecera;
import '../application/impresion/muestras.dart';
import '../domain/empresa_emisora.dart';
import '../domain/host_settings.dart';
import 'host_settings_mapper.dart';
import 'providers.dart';
import 'widgets/host_feedback.dart';
import 'widgets/host_formatos.dart';
import 'widgets/tickets_comandas_secciones.dart';
import 'widgets/vista_previa_escpos.dart';

/// Ancho a partir del cual ajustes y vista previa van en dos columnas.
const double _anchoDosColumnas = 1000;

/// Ancho de la columna de la vista previa en dos columnas.
const double _anchoVistaPrevia = 440;

/// Espera desde el último cambio del borrador hasta regenerar la muestra.
const Duration _esperaVistaPrevia = Duration(milliseconds: 300);

/// Lo que determina los bytes de la vista previa: si no cambia, no se
/// regenera.
typedef _PeticionVista = ({
  DocumentoMuestra tipo,
  ImpresionSettings ajustes,
  EmpresaTicket cabecera,
  PaperWidth papel,
  int avance,
});

/// Direcciones configuradas de las tres impresoras.
Map<RolImpresora, PrinterEndpoint?> _direcciones(PrintingSettings p) => {
  RolImpresora.tickets: p.tickets,
  RolImpresora.cocina: p.cocina,
  RolImpresora.barra: p.barra,
};

/// Una tarjeta por impresora física distinta, en el orden tickets, cocina y
/// barra, con el perfil que le resuelve [formato].
List<ImpresoraFormato> impresorasDeFormato(
  PrintingSettings impresion,
  FormatoImpresion formato,
) {
  final direcciones = _direcciones(impresion);
  final paraTickets = impresion.tickets ?? impresion.cocina ?? impresion.barra;
  final vistas = <PrinterEndpoint>{};
  return [
    for (final endpoint in direcciones.values)
      if (endpoint != null && vistas.add(endpoint))
        ImpresoraFormato(
          endpoint: endpoint,
          roles: rolesDe(endpoint, direcciones),
          perfil: resolverPerfil(
            endpoint,
            direcciones: direcciones,
            formato: formato,
            papelHeredado: impresion.paper,
          ),
          sirveATickets: endpoint == paraTickets,
          rolesConPerfilesDistintos: _rolesEnConflicto(
            rolesDe(endpoint, direcciones),
            formato,
          ),
        ),
  ];
}

/// Roles de [roles] con perfil guardado, si esos perfiles no coinciden
/// (sin contar la dirección para la que se guardaron); si no, vacío.
List<RolImpresora> _rolesEnConflicto(
  List<RolImpresora> roles,
  FormatoImpresion formato,
) {
  final conPerfil = [
    for (final rol in roles)
      if (formato.perfiles.containsKey(rol)) rol,
  ];
  final distintos = {
    for (final rol in conPerfil)
      formato.perfiles[rol]!.copyWith(borrarDireccion: true),
  };
  return distintos.length > 1 ? conPerfil : const [];
}

/// Escribe [perfil] en todos los roles de [impresora], con la dirección de
/// la tarjeta.
FormatoImpresion _conPerfil(
  FormatoImpresion formato,
  ImpresoraFormato impresora,
  PerfilImpresora perfil,
) {
  final escrito = perfil.copyWith(
    direccion: claveImpresora(impresora.endpoint),
  );
  return formato.copyWith(
    perfiles: {
      ...formato.perfiles,
      for (final rol in impresora.roles) rol: escrito,
    },
  );
}

/// Unifica los perfiles de las impresoras compartidas con perfiles
/// distintos: escribe el resuelto en todos sus roles.
FormatoImpresion _unificado(
  FormatoImpresion formato,
  List<ImpresoraFormato> impresoras,
) {
  var resultado = formato;
  for (final impresora in impresoras) {
    if (impresora.perfilesDistintos) {
      resultado = _conPerfil(resultado, impresora, impresora.perfil);
    }
  }
  return resultado;
}

/// Impresora que imprime los documentos de [rol] (con el respaldo de las
/// comandas), como `PrintingService.imprimirMuestra`.
PrinterEndpoint? _impresoraDeRol(ImpresionSettings ajustes, RolImpresora rol) =>
    switch (rol) {
      RolImpresora.tickets => ajustes.paraTickets,
      RolImpresora.cocina =>
        ajustes.impresoraDe(DestinoPreparacion.cocina)?.endpoint,
      RolImpresora.barra =>
        ajustes.impresoraDe(DestinoPreparacion.barra)?.endpoint,
    };

/// Por qué no se pueden guardar los nombres de los pases, o `null`.
String? _problemaPases(PasesConfig pases) {
  for (final (i, nombre) in pases.nombres.indexed) {
    if (nombre.trim().isEmpty) return 'El pase ${i + 1} no tiene nombre';
    if (nombre.length > PasesConfig.maxLongitudNombre) {
      return 'El nombre del pase ${i + 1} pasa de '
          '${PasesConfig.maxLongitudNombre} caracteres';
    }
  }
  return null;
}

/// «Tickets y comandas»: papel, avance, copias y aviso por impresora,
/// formato del ticket del cliente, emisión al cobrar, QR VeriFactu, pases y
/// una vista previa de cada documento.
///
/// Es la única pantalla que escribe `impresion.formato`. Trabaja sobre un
/// borrador y guarda solo ese campo; avisa al salir con cambios sin guardar.
/// Funciona sin el runtime del host (se puede abrir desde el estado de
/// error del arranque): la vista previa usa `generarMuestra`, que es pura,
/// y solo «Imprimir muestra» y «Actualizar desde FacturaScripts» necesitan
/// el runtime.
class TicketsComandasPage extends ConsumerStatefulWidget {
  const TicketsComandasPage({super.key});

  @override
  ConsumerState<TicketsComandasPage> createState() =>
      _TicketsComandasPageState();
}

class _TicketsComandasPageState extends ConsumerState<TicketsComandasPage> {
  /// Copia de trabajo; `null` hasta que cargan los ajustes.
  FormatoImpresion? _borrador;
  bool _guardando = false;
  bool _imprimiendo = false;
  bool _actualizando = false;

  final TextEditingController _nombreComercial = TextEditingController();
  final TextEditingController _pie = TextEditingController();
  final List<TextEditingController> _nombresPases = [];

  DocumentoMuestra _documento = DocumentoMuestra.provisional;

  /// Papel elegido solo para la vista previa (`null`: el del perfil).
  PaperWidth? _papelVista;
  _PeticionVista? _peticion;
  Timer? _espera;
  Uint8List? _bytes;
  String? _errorVista;

  @override
  void dispose() {
    _espera?.cancel();
    _nombreComercial.dispose();
    _pie.dispose();
    for (final c in _nombresPases) {
      c.dispose();
    }
    super.dispose();
  }

  FormatoImpresion _cargar(FormatoImpresion guardado) {
    _nombreComercial.text = guardado.ticket.nombreComercial ?? '';
    _pie.text = guardado.ticket.pie ?? '';
    _nombresPases.addAll([
      for (final nombre in guardado.pases.nombres)
        TextEditingController(text: nombre),
    ]);
    return guardado;
  }

  void _cambiar(FormatoImpresion nuevo) => setState(() => _borrador = nuevo);

  @override
  Widget build(BuildContext context) {
    final ajustes = ref.watch(appSettingsProvider).value;
    if (ajustes == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tickets y comandas')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final borrador = _borrador ??= _cargar(ajustes.impresion.formato);
    final impresoras = impresorasDeFormato(ajustes.impresion, borrador);
    final modificado = borrador != ajustes.impresion.formato;
    final conflicto = impresoras.any((i) => i.perfilesDistintos);
    final problema = _problemaPases(borrador.pases);
    final puedeGuardar =
        (modificado || conflicto) && problema == null && !_guardando;

    final host = hostSettingsFromApp(
      ajustes.copyWith(
        impresion: ajustes.impresion.copyWith(formato: borrador),
      ),
    );
    final runtime = ref.watch(hostRuntimeProvider).value;
    final empresa = ref.watch(
      hostSnapshotProvider.select((s) => s.value?.empresa),
    );
    final cabecera = componerCabecera(
      empresaAjustes: host.empresa,
      empresaErp: empresa,
      formato: borrador.ticket,
      nombreTpv: host.nombreTpv,
    );

    final ajustesPanel = SingleChildScrollView(
      key: const Key('tc-ajustes'),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SeccionImpresorasFormato(
            impresoras: impresoras,
            onCambiar: (impresora, perfil) => setState(() {
              // Cambiar el papel de una tarjeta vuelve a usarlo en la vista
              // previa aunque allí se hubiera elegido otro.
              if (perfil.papel != impresora.perfil.papel) _papelVista = null;
              _borrador = _conPerfil(borrador, impresora, perfil);
            }),
          ),
          SeccionTicketCliente(
            formato: borrador.ticket,
            nombreComercial: _nombreComercial,
            pie: _pie,
            onCambiar: (t) => _cambiar(borrador.copyWith(ticket: t)),
            pistaNombreComercial: empresa?.nombrecorto,
            tarjetaEmisor: _TarjetaEmisor(
              empresa: empresa,
              hayNif: cabecera.cifnif?.trim().isNotEmpty ?? false,
              onActualizar: runtime == null
                  ? null
                  : () => unawaited(_actualizarEmpresa(runtime)),
              actualizando: _actualizando,
            ),
          ),
          SeccionEmision(
            emision: borrador.emision,
            imprimirTicketAlCobrar: ajustes.impresion.imprimirTicketAlCobrar,
            onCambiar: (e) => _cambiar(borrador.copyWith(emision: e)),
          ),
          SeccionQrVerifactu(
            verifactu: borrador.verifactu,
            onCambiar: (v) => _cambiar(borrador.copyWith(verifactu: v)),
          ),
          SeccionPases(
            pases: borrador.pases,
            nombres: _nombresPases,
            error: problema,
            onCambiar: (p) => _cambiar(borrador.copyWith(pases: p)),
            onNombre: (i, texto) => _renombrarPase(borrador, i, texto),
            onAnadir: () => _anadirPase(borrador),
            onQuitar: (i) => _quitarPase(borrador, i),
          ),
        ],
      ),
    );
    final vista = Padding(
      padding: const EdgeInsets.all(16),
      child: _vistaPrevia(host.impresion, cabecera, runtime),
    );

    return PopScope(
      canPop: !modificado,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_salirSinGuardar());
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Tickets y comandas'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.icon(
                key: const Key('tc-guardar'),
                onPressed: puedeGuardar
                    ? () => unawaited(_guardar(ajustes.impresion))
                    : null,
                icon: iconoOProgreso(
                  cargando: _guardando,
                  icono: Icons.save_outlined,
                ),
                label: const Text('Guardar'),
              ),
            ),
          ],
        ),
        body: LayoutBuilder(
          builder: (context, constraints) =>
              constraints.maxWidth >= _anchoDosColumnas
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ajustesPanel),
                    const VerticalDivider(width: 1),
                    SizedBox(width: _anchoVistaPrevia, child: vista),
                  ],
                )
              : DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      const TabBar(
                        tabs: [
                          Tab(text: 'Ajustes'),
                          Tab(text: 'Vista previa'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(children: [ajustesPanel, vista]),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  /// Vista previa del documento elegido con el borrador ([impresion]). El
  /// papel es el del perfil de la impresora que imprime ese documento,
  /// salvo que se cambie aquí.
  Widget _vistaPrevia(
    ImpresionSettings impresion,
    EmpresaTicket cabecera,
    HostRuntime? runtime,
  ) {
    final documento = _documento;
    final endpoint = _impresoraDeRol(impresion, documento.rol);
    final perfil = endpoint == null
        ? PerfilImpresora(papel: impresion.paper)
        : impresion.perfilPara(endpoint);
    final papel = _papelVista ?? perfil.papel;
    _programarVista((
      tipo: documento,
      ajustes: impresion,
      cabecera: cabecera,
      papel: papel,
      avance: documento.preparacion ? perfil.lineasIniciales : 0,
    ));
    final String origen;
    if (_papelVista != null) {
      origen = 'cambiado solo para la vista previa';
    } else if (endpoint == null) {
      origen = 'sin impresora de ${documento.rol.etiqueta}';
    } else {
      origen = 'perfil de ${documento.rol.etiqueta}';
    }
    final String? motivo;
    if (runtime == null) {
      motivo = textoSinRuntime;
    } else if (endpoint == null) {
      motivo = 'No hay impresora de ${documento.rol.etiqueta}';
    } else {
      motivo = null;
    }
    return _PanelVistaPrevia(
      documento: documento,
      onDocumento: (tipo) => setState(() {
        _documento = tipo;
        _papelVista = null;
      }),
      papel: papel,
      origenPapel: origen,
      onPapel: (p) => setState(() => _papelVista = p),
      bytes: _bytes,
      error: _errorVista,
      imprimiendo: _imprimiendo,
      motivoSinImprimir: motivo,
      onImprimir: runtime == null || endpoint == null
          ? null
          : () => unawaited(_imprimirMuestra(runtime, impresion, documento)),
    );
  }

  /// Programa la regeneración de la muestra si cambió lo que la determina:
  /// la primera al instante y las siguientes tras [_esperaVistaPrevia] sin
  /// cambios.
  void _programarVista(_PeticionVista peticion) {
    if (peticion == _peticion) return;
    final primera = _peticion == null;
    _peticion = peticion;
    _espera?.cancel();
    _espera = Timer(
      primera ? Duration.zero : _esperaVistaPrevia,
      () => unawaited(_generar(peticion)),
    );
  }

  Future<void> _generar(_PeticionVista peticion) async {
    final runner = ref.read(isolateRunnerProvider);
    final ahora = ref.read(relojProvider)();
    try {
      final bytes = await generarMuestra(
        peticion.tipo,
        ajustes: peticion.ajustes,
        cabecera: peticion.cabecera,
        papel: peticion.papel,
        ahora: ahora,
        runner: runner,
        avanceInicial: peticion.avance,
      );
      if (!mounted || peticion != _peticion) return;
      setState(() {
        _bytes = bytes;
        _errorVista = null;
      });
    } on Object catch (error) {
      if (!mounted || peticion != _peticion) return;
      // Sin los bytes anteriores: no se muestra un documento que ya no
      // corresponde a lo elegido bajo la banda de error.
      setState(() {
        _bytes = null;
        _errorVista = mensajeDeError(error);
      });
    }
  }

  void _renombrarPase(FormatoImpresion borrador, int indice, String texto) {
    final nombres = [...borrador.pases.nombres];
    nombres[indice] = texto.trim();
    _cambiar(
      borrador.copyWith(pases: borrador.pases.copyWith(nombres: nombres)),
    );
  }

  void _anadirPase(FormatoImpresion borrador) {
    final nombres = borrador.pases.nombres;
    if (nombres.length >= PasesConfig.maxPases) return;
    final nombre = 'Pase ${nombres.length + 1}';
    _nombresPases.add(TextEditingController(text: nombre));
    _cambiar(
      borrador.copyWith(
        pases: borrador.pases.copyWith(nombres: [...nombres, nombre]),
      ),
    );
  }

  void _quitarPase(FormatoImpresion borrador, int indice) {
    final nombres = [...borrador.pases.nombres];
    if (nombres.length <= 1) return;
    nombres.removeAt(indice);
    final quitado = _nombresPases.removeAt(indice);
    // Su campo lo suelta en la próxima reconstrucción.
    WidgetsBinding.instance.addPostFrameCallback((_) => quitado.dispose());
    _cambiar(
      borrador.copyWith(pases: borrador.pases.copyWith(nombres: nombres)),
    );
  }

  Future<void> _guardar(PrintingSettings impresion) async {
    final borrador = _borrador;
    if (borrador == null) return;
    final formato = _unificado(
      borrador,
      impresorasDeFormato(impresion, borrador),
    );
    setState(() => _guardando = true);
    // Solo `impresion.formato`: ninguna otra pantalla escribe este campo y
    // esta no escribe ningún otro. Si falla, el borrador se conserva.
    final ok = await ejecutarAccion(
      context,
      () => ref
          .read(appSettingsProvider.notifier)
          .actualizar(
            (s) =>
                s.copyWith(impresion: s.impresion.copyWith(formato: formato)),
          ),
      exito: 'Tickets y comandas guardado',
    );
    if (!mounted) return;
    setState(() {
      _guardando = false;
      if (ok && identical(_borrador, borrador)) _borrador = formato;
    });
  }

  Future<void> _imprimirMuestra(
    HostRuntime runtime,
    ImpresionSettings ajustes,
    DocumentoMuestra documento,
  ) async {
    setState(() => _imprimiendo = true);
    await ejecutarAccion(
      context,
      () => runtime.printing.imprimirMuestra(
        documento,
        ajustes: ajustes,
        rol: documento.rol,
      ),
      exito: 'Muestra enviada a la impresora',
    );
    if (mounted) setState(() => _imprimiendo = false);
  }

  Future<void> _actualizarEmpresa(HostRuntime runtime) async {
    setState(() => _actualizando = true);
    await ejecutarAccion(
      context,
      () => runtime.refrescarEmpresa(),
      exito: 'Datos de la empresa actualizados',
    );
    if (mounted) setState(() => _actualizando = false);
  }

  Future<void> _salirSinGuardar() async {
    final salir = await confirmar(
      context,
      titulo: 'Cambios sin guardar',
      mensaje:
          'Si sales ahora se perderán los cambios de «Tickets y comandas».',
      textoAceptar: 'Salir sin guardar',
      peligroso: true,
    );
    if (!salir || !mounted) return;
    // `pop` directo no consulta el `PopScope`.
    Navigator.of(context).pop();
  }
}

/// Tarjeta de solo lectura con la empresa emisora en caché y el botón
/// «Actualizar desde FacturaScripts» (desactivado sin runtime).
class _TarjetaEmisor extends StatelessWidget {
  const _TarjetaEmisor({
    required this.empresa,
    required this.hayNif,
    required this.onActualizar,
    required this.actualizando,
  });

  final EmpresaEmisora? empresa;
  final bool hayNif;
  final VoidCallback? onActualizar;
  final bool actualizando;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = empresa;
    final localidad = [
      ?e?.codpostal,
      ?e?.ciudad,
      if (e?.provincia case final p?) '($p)',
    ].join(' ');
    return Card(
      key: const Key('tc-emisor'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Emisor (FacturaScripts)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            if (e == null)
              const Text(
                'Aún no se han leído los datos de la empresa de '
                'FacturaScripts.',
              )
            else ...[
              Text(e.nombre, style: theme.textTheme.bodyLarge),
              Text('NIF: ${e.cifnif ?? '—'}'),
              if (e.direccion case final direccion?) Text(direccion),
              if (localidad.isNotEmpty) Text(localidad),
              Text(
                'Actualizado el ${formatFechaHora(e.obtenidaEn)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (!hayNif)
              const BandaAviso(textoSinNif, key: Key('tc-aviso-sin-nif')),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const Key('tc-actualizar-empresa'),
                  onPressed: actualizando ? null : onActualizar,
                  icon: iconoOProgreso(
                    cargando: actualizando,
                    icono: Icons.sync,
                  ),
                  label: const Text('Actualizar desde FacturaScripts'),
                ),
                if (onActualizar == null) const Text(textoSinRuntime),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Columna de la vista previa del documento de muestra elegido, con el
/// papel y el botón «Imprimir muestra».
class _PanelVistaPrevia extends StatelessWidget {
  const _PanelVistaPrevia({
    required this.documento,
    required this.onDocumento,
    required this.papel,
    required this.origenPapel,
    required this.onPapel,
    required this.bytes,
    required this.error,
    required this.onImprimir,
    this.motivoSinImprimir,
    this.imprimiendo = false,
  });

  final DocumentoMuestra documento;
  final ValueChanged<DocumentoMuestra> onDocumento;
  final PaperWidth papel;

  /// De dónde sale el papel («perfil de Tickets», «cambiado solo para la
  /// vista previa»…).
  final String origenPapel;
  final ValueChanged<PaperWidth> onPapel;

  /// Bytes de la muestra; `null` mientras se genera la primera.
  final Uint8List? bytes;
  final String? error;

  /// `null`: el botón «Imprimir muestra» sale desactivado.
  final VoidCallback? onImprimir;
  final String? motivoSinImprimir;
  final bool imprimiendo;

  @override
  Widget build(BuildContext context) {
    final contenido = bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tipo in DocumentoMuestra.values)
              ChoiceChip(
                key: Key('tc-documento-${tipo.name}'),
                label: Text(tipo.etiqueta),
                selected: tipo == documento,
                onSelected: (_) => onDocumento(tipo),
              ),
          ],
        ),
        const SizedBox(height: 8),
        selectorPapel(
          clave: 'tc-papel-vista',
          papel: papel,
          onChanged: onPapel,
        ),
        TextoAyuda('Papel: ${papel.etiqueta} ($origenPapel)'),
        if (error case final texto?)
          BandaAviso(texto, key: const Key('tc-vista-error')),
        Expanded(
          child: contenido == null
              ? (error == null
                    ? const Center(child: CircularProgressIndicator())
                    : const SizedBox.shrink())
              : SingleChildScrollView(
                  key: const Key('tc-vista-previa'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Center(
                    child: VistaPreviaEscPos(bytes: contenido, papel: papel),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('tc-imprimir-muestra'),
          onPressed: imprimiendo ? null : onImprimir,
          icon: iconoOProgreso(
            cargando: imprimiendo,
            icono: Icons.print_outlined,
          ),
          label: const Text('Imprimir muestra'),
        ),
        if (motivoSinImprimir case final motivo?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              motivo,
              key: const Key('tc-imprimir-motivo'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
