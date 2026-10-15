/// Ajustes de formato de la impresión: perfil por impresora física (papel,
/// avance inicial, copias y aviso sonoro), formato del ticket del cliente,
/// emisión al cobrar, QR VeriFactu y pases.
///
/// Es un módulo de dominio compartido (Dart puro) que importan
/// `settings/domain` (persistencia y edición) y `host/domain` (configuración
/// efectiva del host), como `EnrutamientoComandas` en `sala/domain`: así
/// `settings` no depende de `host` ni al revés.
///
/// Lectura tolerante: un ajuste cosmético nunca debe impedir arrancar, de
/// modo que ningún `fromJson` de este fichero lanza. Lo ausente o de otro
/// tipo toma su valor por defecto, un enum desconocido también, y los
/// números fuera de rango se acotan.
library;

import 'package:equatable/equatable.dart';

import '../../../core/fiscal/verifactu_qr.dart'
    show EntornoVerifactu, ModoQrVerifactu;
import '../../../core/isolates/escpos/escpos_builder.dart'
    show PaperWidth, ZumbadorModo, truncateRunes;
import '../../../core/network/printing/raw_printer_transport.dart'
    show PrinterEndpoint;
import '../../../core/utils/json_tolerante.dart';
import '../../sala/domain/pases.dart';

/// Papel de una impresora en los ajustes: a qué documentos sirve. Cada rol
/// tiene su dirección (`tickets`, `cocina` y `barra` de los ajustes de
/// impresión) y, opcionalmente, su [PerfilImpresora] en
/// [FormatoImpresion.perfiles].
enum RolImpresora {
  /// Documentos de cliente: provisional, factura, duplicado y precuenta.
  tickets,

  /// Documentos de preparación de cocina.
  cocina,

  /// Documentos de preparación de barra.
  barra,
}

/// Perfil de una impresora física: papel, avance inicial, copias y aviso
/// sonoro. Se guarda por rol junto con la dirección para la que se guardó
/// ([direccion]); [resolverPerfil] decide cuál se aplica a cada impresora.
///
/// `ZumbadorModo.puertoCajon` (zumbador externo en el conector del cajón,
/// `ESC p m`) nunca suena en la impresora que sirve a los tickets: un pulso
/// en ese conector abriría el cajón. [resolverPerfil] lo anula (decisión C).
/// Los avisos solo suenan en los documentos de preparación.
final class PerfilImpresora extends Equatable {
  const PerfilImpresora({
    this.papel = PaperWidth.mm80,
    this.lineasIniciales = 0,
    this.copias = 1,
    this.zumbador = ZumbadorModo.ninguno,
    this.pitidos = 2,
    this.pinZumbador = pinZumbadorPorDefecto,
    this.direccion,
  });

  /// Lectura tolerante: enum desconocido → defecto; número fuera de rango →
  /// se acota; pin distinto de 2 y 5 → 5; dirección vacía → nula.
  factory PerfilImpresora.fromJson(Map<String, Object?> json) {
    const defecto = PerfilImpresora();
    final pin = enteroTolerante(json['pinZumbador']);
    return PerfilImpresora(
      papel: _enumTolerante(PaperWidth.values, json['papel'], defecto.papel),
      lineasIniciales: _acotado(
        json['lineasIniciales'],
        porDefecto: defecto.lineasIniciales,
        min: 0,
        max: maxLineasIniciales,
      ),
      copias: _acotado(
        json['copias'],
        porDefecto: defecto.copias,
        min: minCopias,
        max: maxCopias,
      ),
      zumbador: _enumTolerante(
        ZumbadorModo.values,
        json['zumbador'],
        defecto.zumbador,
      ),
      pitidos: _acotado(
        json['pitidos'],
        porDefecto: defecto.pitidos,
        min: minPitidos,
        max: maxPitidos,
      ),
      pinZumbador: pin != null && pinesZumbador.contains(pin)
          ? pin
          : pinZumbadorPorDefecto,
      direccion: textoTolerante(json['direccion']),
    );
  }

  /// Avance inicial máximo (líneas en blanco para las guías de tickets).
  static const int maxLineasIniciales = 10;
  static const int minCopias = 1;
  static const int maxCopias = 3;
  static const int minPitidos = 1;

  /// Pitidos máximos con `ZumbadorModo.generico` (`ESC B`).
  static const int maxPitidos = 8;

  /// Pitidos máximos con `ZumbadorModo.puertoCajon` (`ESC p`).
  static const int maxPitidosPuertoCajon = 3;

  /// Pin 5 del conector del cajón (`ESC p 1 …`), el habitual.
  static const int pinZumbadorPorDefecto = 5;

  /// Pines admitidos del conector del cajón, en el orden de la interfaz.
  static const List<int> pinesZumbador = [5, 2];

  final PaperWidth papel;

  /// Líneas en blanco al principio de los documentos de preparación
  /// (comanda, MARCHAR y anulación), 0..10, para las guías de tickets.
  final int lineasIniciales;

  /// Copias de cada documento de preparación, 1..3.
  final int copias;

  final ZumbadorModo zumbador;

  /// Pitidos del aviso: 1..8 con `generico`, 1..3 con `puertoCajon` (ver
  /// [maxPitidosDe]).
  final int pitidos;

  /// Pin del conector del cajón del zumbador externo: 5 (por defecto) o 2.
  final int pinZumbador;

  /// `host:puerto` ([claveImpresora]) de la impresora para la que se guardó
  /// este perfil; lo escribe la página «Tickets y comandas».
  final String? direccion;

  /// Pitidos máximos de un modo de aviso.
  static int maxPitidosDe(ZumbadorModo modo) =>
      modo == ZumbadorModo.puertoCajon ? maxPitidosPuertoCajon : maxPitidos;

  /// Escribe siempre `papel`, que es lo que justifica tener un perfil, y
  /// `direccion` si no es nula; el resto solo si no tiene su valor por
  /// defecto.
  Map<String, Object?> toJson() {
    const defecto = PerfilImpresora();
    return {
      'papel': papel.name,
      if (lineasIniciales != defecto.lineasIniciales)
        'lineasIniciales': lineasIniciales,
      if (copias != defecto.copias) 'copias': copias,
      if (zumbador != defecto.zumbador) 'zumbador': zumbador.name,
      if (pitidos != defecto.pitidos) 'pitidos': pitidos,
      if (pinZumbador != defecto.pinZumbador) 'pinZumbador': pinZumbador,
      'direccion': ?direccion,
    };
  }

  /// [direccion] se quita con [borrarDireccion] (pasar `null` la conserva).
  PerfilImpresora copyWith({
    PaperWidth? papel,
    int? lineasIniciales,
    int? copias,
    ZumbadorModo? zumbador,
    int? pitidos,
    int? pinZumbador,
    String? direccion,
    bool borrarDireccion = false,
  }) => PerfilImpresora(
    papel: papel ?? this.papel,
    lineasIniciales: lineasIniciales ?? this.lineasIniciales,
    copias: copias ?? this.copias,
    zumbador: zumbador ?? this.zumbador,
    pitidos: pitidos ?? this.pitidos,
    pinZumbador: pinZumbador ?? this.pinZumbador,
    direccion: borrarDireccion ? null : (direccion ?? this.direccion),
  );

  @override
  List<Object?> get props => [
    papel,
    lineasIniciales,
    copias,
    zumbador,
    pitidos,
    pinZumbador,
    direccion,
  ];
}

/// `host:puerto` de una impresora (la forma de `PrinterEndpoint.toString`,
/// con el host entre corchetes si es IPv6): la clave de
/// [PerfilImpresora.direccion].
String claveImpresora(PrinterEndpoint endpoint) => endpoint.toString();

/// Roles cuya dirección configurada en [direcciones] es [endpoint], en el
/// orden tickets, cocina y barra. La página «Tickets y comandas» guarda el
/// mismo perfil en todos ellos y avisa si tienen perfiles distintos.
List<RolImpresora> rolesDe(
  PrinterEndpoint endpoint,
  Map<RolImpresora, PrinterEndpoint?> direcciones,
) => [
  for (final rol in RolImpresora.values)
    if (direcciones[rol] == endpoint) rol,
];

/// Perfil de la impresora física [endpoint], la que realmente imprime (la
/// propia del rol o la de respaldo).
///
/// Entre los roles cuya dirección configurada en [direcciones] es [endpoint],
/// en orden tickets, cocina y barra ([rolesDe]), y que tienen perfil en
/// [formato]: gana el que se guardó para esa misma dirección
/// (`perfil.direccion`); si ninguno, el primero; si ningún rol tiene perfil,
/// `PerfilImpresora(papel: papelHeredado)`.
///
/// Guarda del cajón (decisión C): si el perfil resuelto tiene
/// `zumbador == puertoCajon` y [endpoint] es la impresora que sirve a los
/// tickets (`tickets ?? cocina ?? barra` de [direcciones]), devuelve el
/// perfil con `zumbador: ninguno`. Un pulso en el conector de esa impresora
/// abriría el cajón conectado a ella, tenga o no activado «Abrir el cajón».
///
/// Es la única regla de resolución: la usan `ImpresionSettings.perfilPara`,
/// la página «Tickets y comandas» y la prueba de impresión de los ajustes.
PerfilImpresora resolverPerfil(
  PrinterEndpoint endpoint, {
  required Map<RolImpresora, PrinterEndpoint?> direcciones,
  required FormatoImpresion formato,
  required PaperWidth papelHeredado,
}) {
  final candidatos = [
    for (final rol in rolesDe(endpoint, direcciones)) ?formato.perfiles[rol],
  ];
  if (candidatos.isEmpty) return PerfilImpresora(papel: papelHeredado);
  final clave = claveImpresora(endpoint);
  final perfil = candidatos.firstWhere(
    (candidato) => _mismaDireccion(candidato.direccion, clave),
    orElse: () => candidatos.first,
  );
  final sirveATickets = endpoint == _impresoraDeTickets(direcciones);
  if (perfil.zumbador == ZumbadorModo.puertoCajon && sirveATickets) {
    return perfil.copyWith(zumbador: ZumbadorModo.ninguno);
  }
  return perfil;
}

/// La impresora que sirve a los tickets, como `ImpresionSettings.paraTickets`.
PrinterEndpoint? _impresoraDeTickets(
  Map<RolImpresora, PrinterEndpoint?> direcciones,
) =>
    direcciones[RolImpresora.tickets] ??
    direcciones[RolImpresora.cocina] ??
    direcciones[RolImpresora.barra];

/// El host se compara sin distinguir mayúsculas, como `PrinterEndpoint.==`.
bool _mismaDireccion(String? direccion, String clave) =>
    direccion != null && direccion.toLowerCase() == clave.toLowerCase();

/// Formato del ticket del cliente (provisional, factura, duplicado y
/// precuenta).
final class FormatoTicket extends Equatable {
  const FormatoTicket({
    this.nombreComercial,
    this.pie,
    this.mostrarNotas = false,
    this.ivaIncluido = true,
    this.mostrarCamarero = true,
    this.mostrarComensales = true,
  });

  /// Lectura tolerante: textos vacíos → nulos y los largos se recortan a
  /// [maxNombreComercial] y [maxPie]; un valor de otro tipo → defecto.
  factory FormatoTicket.fromJson(Map<String, Object?> json) {
    const defecto = FormatoTicket();
    return FormatoTicket(
      nombreComercial: _textoAcotado(
        json['nombreComercial'],
        maxNombreComercial,
      ),
      pie: _textoAcotado(json['pie'], maxPie),
      mostrarNotas: booleanoTolerante(
        json['mostrarNotas'],
        porDefecto: defecto.mostrarNotas,
      ),
      ivaIncluido: booleanoTolerante(
        json['ivaIncluido'],
        porDefecto: defecto.ivaIncluido,
      ),
      mostrarCamarero: booleanoTolerante(
        json['mostrarCamarero'],
        porDefecto: defecto.mostrarCamarero,
      ),
      mostrarComensales: booleanoTolerante(
        json['mostrarComensales'],
        porDefecto: defecto.mostrarComensales,
      ),
    );
  }

  static const int maxNombreComercial = 32;
  static const int maxPie = 200;

  /// Líneas máximas del pie (lo aplica la página; el texto cabe en [maxPie]).
  static const int maxLineasPie = 3;

  /// Cabecera del ticket; nulo → el `nombrecorto` de FacturaScripts.
  final String? nombreComercial;

  /// Texto al pie del ticket (puede tener varias líneas).
  final String? pie;

  /// Imprimir las notas de cocina en tickets y precuentas.
  final bool mostrarNotas;

  /// Imprimir «IVA incluido».
  final bool ivaIncluido;

  /// «Camarero: X» en provisional, factura, duplicado y precuenta.
  final bool mostrarCamarero;

  /// «N comensales» y «Por comensal (n)» en la precuenta.
  final bool mostrarComensales;

  /// Solo lo que no tiene su valor por defecto; en particular,
  /// `mostrarCamarero` y `mostrarComensales` solo cuando son `false`.
  Map<String, Object?> toJson() {
    const defecto = FormatoTicket();
    return {
      'nombreComercial': ?nombreComercial,
      'pie': ?pie,
      if (mostrarNotas != defecto.mostrarNotas) 'mostrarNotas': mostrarNotas,
      if (ivaIncluido != defecto.ivaIncluido) 'ivaIncluido': ivaIncluido,
      if (mostrarCamarero != defecto.mostrarCamarero)
        'mostrarCamarero': mostrarCamarero,
      if (mostrarComensales != defecto.mostrarComensales)
        'mostrarComensales': mostrarComensales,
    };
  }

  /// Los textos se quitan con [borrarNombreComercial] y [borrarPie] (pasar
  /// `null` los conserva).
  FormatoTicket copyWith({
    String? nombreComercial,
    bool borrarNombreComercial = false,
    String? pie,
    bool borrarPie = false,
    bool? mostrarNotas,
    bool? ivaIncluido,
    bool? mostrarCamarero,
    bool? mostrarComensales,
  }) => FormatoTicket(
    nombreComercial: borrarNombreComercial
        ? null
        : (nombreComercial ?? this.nombreComercial),
    pie: borrarPie ? null : (pie ?? this.pie),
    mostrarNotas: mostrarNotas ?? this.mostrarNotas,
    ivaIncluido: ivaIncluido ?? this.ivaIncluido,
    mostrarCamarero: mostrarCamarero ?? this.mostrarCamarero,
    mostrarComensales: mostrarComensales ?? this.mostrarComensales,
  );

  static String? _textoAcotado(Object? raw, int max) {
    final texto = textoTolerante(raw);
    return texto == null ? null : truncateRunes(texto, max);
  }

  @override
  List<Object?> get props => [
    nombreComercial,
    pie,
    mostrarNotas,
    ivaIncluido,
    mostrarCamarero,
    mostrarComensales,
  ];
}

/// Qué documento de cliente se imprime al cobrar (decisión D1).
enum ModoEmision {
  /// Documento provisional en el acto, sin esperar a FacturaScripts.
  alInstante,

  /// Esperar hasta [EmisionTicket.espera] a que el ticket tenga código de
  /// FacturaScripts e imprimir la factura simplificada; si vence el plazo o
  /// la factura falla, el documento provisional.
  facturaAlCobrar,
}

/// Emisión del documento de cliente al cobrar.
final class EmisionTicket extends Equatable {
  const EmisionTicket({
    this.modo = ModoEmision.alInstante,
    this.esperaSegundos = 10,
  });

  /// Lectura tolerante: modo desconocido → al instante; espera acotada a
  /// [minEsperaSegundos]..[maxEsperaSegundos].
  factory EmisionTicket.fromJson(Map<String, Object?> json) {
    const defecto = EmisionTicket();
    return EmisionTicket(
      modo: _enumTolerante(ModoEmision.values, json['modo'], defecto.modo),
      esperaSegundos: _acotado(
        json['esperaSegundos'],
        porDefecto: defecto.esperaSegundos,
        min: minEsperaSegundos,
        max: maxEsperaSegundos,
      ),
    );
  }

  static const int minEsperaSegundos = 3;
  static const int maxEsperaSegundos = 30;

  final ModoEmision modo;

  /// Espera máxima de la factura con [ModoEmision.facturaAlCobrar], 3..30.
  final int esperaSegundos;

  Duration get espera => Duration(seconds: esperaSegundos);

  /// Siempre completo (se escribe solo si no es por defecto).
  Map<String, Object?> toJson() => {
    'modo': modo.name,
    'esperaSegundos': esperaSegundos,
  };

  EmisionTicket copyWith({ModoEmision? modo, int? esperaSegundos}) =>
      EmisionTicket(
        modo: modo ?? this.modo,
        esperaSegundos: esperaSegundos ?? this.esperaSegundos,
      );

  @override
  List<Object?> get props => [modo, esperaSegundos];
}

/// QR tributario de la factura simplificada (decisión D3): desactivado por
/// defecto; hay que validarlo en la impresora real antes de activarlo.
final class QrVerifactuConfig extends Equatable {
  const QrVerifactuConfig({
    this.modo = ModoQrVerifactu.desactivado,
    this.entorno = EntornoVerifactu.produccion,
  });

  /// Lectura tolerante: enum desconocido → defecto.
  factory QrVerifactuConfig.fromJson(Map<String, Object?> json) {
    const defecto = QrVerifactuConfig();
    return QrVerifactuConfig(
      modo: _enumTolerante(ModoQrVerifactu.values, json['modo'], defecto.modo),
      entorno: _enumTolerante(
        EntornoVerifactu.values,
        json['entorno'],
        defecto.entorno,
      ),
    );
  }

  final ModoQrVerifactu modo;
  final EntornoVerifactu entorno;

  /// Se imprime el QR (en cualquiera de los dos sistemas).
  bool get activo => modo != ModoQrVerifactu.desactivado;

  /// Siempre completo (se escribe solo si no es por defecto).
  Map<String, Object?> toJson() => {'modo': modo.name, 'entorno': entorno.name};

  QrVerifactuConfig copyWith({
    ModoQrVerifactu? modo,
    EntornoVerifactu? entorno,
  }) => QrVerifactuConfig(
    modo: modo ?? this.modo,
    entorno: entorno ?? this.entorno,
  );

  @override
  List<Object?> get props => [modo, entorno];
}

/// Ajustes de formato completos (`impresion.formato` de los ajustes). Los
/// escribe solo la página «Tickets y comandas».
///
/// El constructor `const` no copia [perfiles]: quien lo construya no debe
/// modificar el mapa después. [fromJson] y [copyWith] devuelven siempre
/// mapas inmodificables.
final class FormatoImpresion extends Equatable {
  const FormatoImpresion({
    this.perfiles = const {},
    this.ticket = const FormatoTicket(),
    this.emision = const EmisionTicket(),
    this.verifactu = const QrVerifactuConfig(),
    this.pases = const PasesConfig(),
  });

  /// Lectura tolerante: ausente → defecto; enum desconocido → defecto;
  /// número fuera de rango → se acota (copias 1..3, pitidos 1..8,
  /// lineasIniciales 0..10, espera 3..30); pin distinto de 2 y 5 → 5;
  /// nombres de pases inválidos → pases por defecto. Nunca lanza: un ajuste
  /// cosmético no debe impedir arrancar.
  factory FormatoImpresion.fromJson(Map<String, Object?> json) =>
      FormatoImpresion(
        perfiles: _perfilesFromJson(json['perfiles']),
        ticket: _mapaTolerante(
          json['ticket'],
          FormatoTicket.fromJson,
          const FormatoTicket(),
        ),
        emision: _mapaTolerante(
          json['emision'],
          EmisionTicket.fromJson,
          const EmisionTicket(),
        ),
        verifactu: _mapaTolerante(
          json['verifactu'],
          QrVerifactuConfig.fromJson,
          const QrVerifactuConfig(),
        ),
        pases: PasesConfig.tolerante(json['pases']) ?? const PasesConfig(),
      );

  /// Perfil guardado por rol. Un rol sin entrada no tiene perfil propio:
  /// [resolverPerfil] decide (el de otro rol de la misma impresora o el
  /// papel heredado).
  final Map<RolImpresora, PerfilImpresora> perfiles;

  final FormatoTicket ticket;
  final EmisionTicket emision;
  final QrVerifactuConfig verifactu;
  final PasesConfig pases;

  /// Igual a `const FormatoImpresion()`: la clave `formato` se omite del
  /// JSON y el de hoy no cambia.
  bool get esPorDefecto => this == const FormatoImpresion();

  /// Cada subobjeto solo si no es por defecto; los perfiles, en el orden
  /// tickets, cocina y barra.
  Map<String, Object?> toJson() => {
    if (perfiles.isNotEmpty)
      'perfiles': {
        for (final rol in RolImpresora.values)
          if (perfiles[rol] case final perfil?) rol.name: perfil.toJson(),
      },
    if (ticket != const FormatoTicket()) 'ticket': ticket.toJson(),
    if (emision != const EmisionTicket()) 'emision': emision.toJson(),
    if (verifactu != const QrVerifactuConfig()) 'verifactu': verifactu.toJson(),
    if (pases != const PasesConfig()) 'pases': pases.toJson(),
  };

  FormatoImpresion copyWith({
    Map<RolImpresora, PerfilImpresora>? perfiles,
    FormatoTicket? ticket,
    EmisionTicket? emision,
    QrVerifactuConfig? verifactu,
    PasesConfig? pases,
  }) => FormatoImpresion(
    perfiles: perfiles == null ? this.perfiles : Map.unmodifiable(perfiles),
    ticket: ticket ?? this.ticket,
    emision: emision ?? this.emision,
    verifactu: verifactu ?? this.verifactu,
    pases: pases ?? this.pases,
  );

  /// Las claves que no son un rol y los valores que no son un objeto se
  /// ignoran (como si ese rol no tuviera perfil).
  static Map<RolImpresora, PerfilImpresora> _perfilesFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return const {};
    final roles = RolImpresora.values.asNameMap();
    return Map.unmodifiable({
      for (final MapEntry(:key, :value) in raw.entries)
        if (roles[key] case final rol?)
          if (value case final Map<String, Object?> perfil)
            rol: PerfilImpresora.fromJson(perfil),
    });
  }

  @override
  List<Object?> get props => [perfiles, ticket, emision, verifactu, pases];
}

/// Valor de enumeración por su `name`; ausente, de otro tipo o desconocido →
/// [porDefecto].
T _enumTolerante<T extends Enum>(List<T> values, Object? raw, T porDefecto) =>
    raw is String ? (values.asNameMap()[raw] ?? porDefecto) : porDefecto;

/// Entero acotado a [min]..[max]; ausente o de otro tipo → [porDefecto].
int _acotado(
  Object? raw, {
  required int porDefecto,
  required int min,
  required int max,
}) => (enteroTolerante(raw) ?? porDefecto).clamp(min, max);

/// Subobjeto leído con [leer] si [raw] es un objeto JSON; si no,
/// [porDefecto].
T _mapaTolerante<T>(
  Object? raw,
  T Function(Map<String, Object?> json) leer,
  T porDefecto,
) => raw is Map<String, Object?> ? leer(raw) : porDefecto;
