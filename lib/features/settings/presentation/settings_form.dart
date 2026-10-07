/// Validación y conversión de los campos del formulario de ajustes.
///
/// Funciones puras (sin Flutter) para poder probarlas sin montar la
/// pantalla: los validadores devuelven el texto del error o `null` si el
/// valor es correcto, con la firma de `FormField.validator`.
library;

import 'package:equatable/equatable.dart';

import '../../../core/errors/app_exception.dart';
import '../domain/app_settings.dart';

// ---------------------------------------------------------------------------
// Validadores genéricos
// ---------------------------------------------------------------------------

/// Texto obligatorio (no vacío tras recortar) de como mucho [maximo]
/// caracteres.
String? validarRequerido(String? texto, {int maximo = 100}) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return 'Obligatorio';
  if (limpio.length > maximo) return 'Máximo $maximo caracteres';
  return null;
}

/// Código de FacturaScripts (serie, cliente, almacén, forma de pago): sin
/// espacios y de longitud acotada.
String? validarCodigo(String? texto, {int maximo = 10, bool opcional = false}) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return opcional ? null : 'Obligatorio';
  if (limpio.length > maximo) return 'Máximo $maximo caracteres';
  if (limpio.contains(RegExp(r'\s'))) return 'Sin espacios';
  return null;
}

/// Puerto TCP/UDP entre 1 y 65535.
String? validarPuerto(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return 'Obligatorio';
  final puerto = int.tryParse(limpio);
  if (puerto == null || puerto < 1 || puerto > 65535) {
    return 'Puerto entre 1 y 65535';
  }
  return null;
}

/// Código de emparejamiento opcional: de 4 a 32 caracteres sin espacios.
String? validarPairingCode(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return null;
  if (limpio.length < 4 || limpio.length > 32) return 'Entre 4 y 32 caracteres';
  if (limpio.contains(RegExp(r'\s'))) return 'Sin espacios';
  return null;
}

/// Entero positivo opcional (p. ej. `idempresa`).
String? validarEnteroPositivoOpcional(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return null;
  final valor = int.tryParse(limpio);
  if (valor == null || valor < 1) return 'Número entero mayor que 0';
  return null;
}

/// Subcuenta contable opcional: solo dígitos, de 4 a 15.
String? validarSubcuenta(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return null;
  if (!RegExp(r'^\d{4,15}$').hasMatch(limpio)) return 'Solo dígitos (4 a 15)';
  return null;
}

/// URL base de FacturaScripts (`http(s)://host[:puerto][/ruta]`).
String? validarUrlErp(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return 'Obligatorio';
  try {
    FsApiConfig.normalizeBaseUrl(limpio);
    return null;
  } on ConfigException {
    return 'URL no válida (http://host[:puerto][/ruta])';
  }
}

// ---------------------------------------------------------------------------
// Números e importes
// ---------------------------------------------------------------------------

/// Número decimal escrito por el usuario (acepta coma o punto).
double? parseDecimal(String texto) {
  final limpio = texto.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(limpio)) return null;
  return double.tryParse(limpio);
}

/// Formatea un decimal para un campo editable (sin ceros sobrantes).
String formatDecimalEditable(double valor) {
  final texto = valor.toStringAsFixed(3);
  return texto
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '')
      .replaceAll('.', ',');
}

/// Importe en euros (`100`, `100,5`, `100.50`) a céntimos. `null` si no es
/// un importe válido (negativo, más de dos decimales o mayor de 9.999.999).
int? parseImporteCents(String texto) {
  final limpio = texto.trim().replaceAll(',', '.');
  final match = RegExp(r'^(\d{1,7})(?:\.(\d{1,2}))?$').firstMatch(limpio);
  if (match == null) return null;
  final euros = int.parse(match.group(1)!);
  final decimales = (match.group(2) ?? '').padRight(2, '0');
  return euros * 100 + int.parse(decimales);
}

/// Céntimos a texto editable (`10050` → `100,50`).
String formatImporteEditable(int cents) {
  final euros = cents ~/ 100;
  final resto = (cents % 100).toString().padLeft(2, '0');
  return '$euros,$resto';
}

String? validarImporte(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return 'Obligatorio';
  return parseImporteCents(limpio) == null
      ? 'Importe no válido (p. ej. 150,00)'
      : null;
}

/// Factor de reposición sin máximo: decimal entre 1 y 100.
String? validarFactor(String? texto) {
  final valor = parseDecimal(texto ?? '');
  if (valor == null) return 'Número no válido';
  if (valor < 1 || valor > 100) return 'Entre 1 y 100';
  return null;
}

/// Múltiplo de pedido: decimal entre 0,001 y 10000.
String? validarMultiplo(String? texto) {
  final valor = parseDecimal(texto ?? '');
  if (valor == null) return 'Número no válido';
  if (valor < 0.001 || valor > 10000) return 'Entre 0,001 y 10000';
  return null;
}

// ---------------------------------------------------------------------------
// Direcciones (host manual e impresoras)
// ---------------------------------------------------------------------------

/// Descompone `host`, `host:puerto`, `[ipv6]` o `[ipv6]:puerto`. Una IPv6 sin
/// corchetes se toma entera como host. Lanza [ValidationException].
({String host, int port}) parseDireccion(
  String texto, {
  required int puertoPorDefecto,
}) {
  final limpio = texto.trim();
  if (limpio.isEmpty) {
    throw const ValidationException('La dirección está vacía');
  }
  if (limpio.contains(RegExp(r'\s'))) {
    throw const ValidationException('La dirección no puede tener espacios');
  }
  String host;
  String? puertoTexto;
  if (limpio.startsWith('[')) {
    final cierre = limpio.indexOf(']');
    if (cierre < 0) {
      throw const ValidationException('Falta el corchete de cierre');
    }
    host = limpio.substring(1, cierre);
    final resto = limpio.substring(cierre + 1);
    if (resto.isNotEmpty) {
      if (!resto.startsWith(':')) {
        throw const ValidationException('Formato: [ipv6]:puerto');
      }
      puertoTexto = resto.substring(1);
    }
  } else if (':'.allMatches(limpio).length == 1) {
    final sep = limpio.indexOf(':');
    host = limpio.substring(0, sep);
    puertoTexto = limpio.substring(sep + 1);
  } else {
    host = limpio;
  }
  if (host.isEmpty) throw const ValidationException('Falta el host');
  var puerto = puertoPorDefecto;
  if (puertoTexto != null) {
    final valor = int.tryParse(puertoTexto);
    if (valor == null || valor < 1 || valor > 65535) {
      throw const ValidationException('Puerto entre 1 y 65535');
    }
    puerto = valor;
  }
  return (host: host, port: puerto);
}

/// Formatea host y puerto (`[ipv6]:puerto` si hace falta).
String formatDireccion(String host, int port) =>
    host.contains(':') ? '[$host]:$port' : '$host:$port';

/// Normaliza el host manual del comandero a `host:puerto` (sin puerto se
/// asume [NetworkSettings.defaultTcpPort]).
String normalizarDireccionHost(String texto) {
  final d = parseDireccion(
    texto,
    puertoPorDefecto: NetworkSettings.defaultTcpPort,
  );
  return formatDireccion(d.host, d.port);
}

String? validarHostManual(String? texto) {
  final limpio = texto?.trim() ?? '';
  if (limpio.isEmpty) return null;
  try {
    normalizarDireccionHost(limpio);
    return null;
  } on ValidationException catch (error) {
    return error.message;
  }
}

/// Impresora `ip[:puerto]` (puerto 9100 por defecto). Vacío = sin impresora.
PrinterEndpoint? parseImpresora(String texto) {
  if (texto.trim().isEmpty) return null;
  final d = parseDireccion(texto, puertoPorDefecto: kRawPrintPort);
  return PrinterEndpoint(d.host, port: d.port);
}

String formatImpresora(PrinterEndpoint? endpoint) =>
    endpoint == null ? '' : formatDireccion(endpoint.host, endpoint.port);

String? validarImpresora(String? texto) {
  try {
    parseImpresora(texto ?? '');
    return null;
  } on ValidationException catch (error) {
    return error.message;
  }
}

// ---------------------------------------------------------------------------
// Mesas
// ---------------------------------------------------------------------------

/// Una zona del salón y cuántas mesas tiene.
final class ZonaMesas extends Equatable {
  const ZonaMesas({required this.zona, required this.cantidad});

  final String zona;
  final int cantidad;

  ZonaMesas copyWith({String? zona, int? cantidad}) =>
      ZonaMesas(zona: zona ?? this.zona, cantidad: cantidad ?? this.cantidad);

  @override
  List<Object?> get props => [zona, cantidad];
}

/// Máximo de mesas por zona.
const int kMaxMesasPorZona = 99;

/// Zonas en el orden en que aparecen por primera vez en [mesas].
List<ZonaMesas> zonasDe(List<Mesa> mesas) {
  final cuenta = <String, int>{};
  for (final mesa in mesas) {
    cuenta[mesa.zona] = (cuenta[mesa.zona] ?? 0) + 1;
  }
  return [
    for (final MapEntry(:key, :value) in cuenta.entries)
      ZonaMesas(zona: key, cantidad: value),
  ];
}

/// Comprueba las zonas: nombres no vacíos ni repetidos, cantidades entre 0
/// y [kMaxMesasPorZona] y al menos una mesa en total. Devuelve el error o
/// `null`.
String? validarZonas(List<ZonaMesas> zonas) {
  final vistos = <String>{};
  var total = 0;
  for (final zona in zonas) {
    final nombre = zona.zona.trim();
    if (nombre.isEmpty) return 'Hay una zona sin nombre';
    if (!vistos.add(nombre.toLowerCase())) {
      return "La zona '$nombre' está repetida";
    }
    if (zona.cantidad < 0 || zona.cantidad > kMaxMesasPorZona) {
      return "La zona '$nombre' debe tener entre 0 y $kMaxMesasPorZona mesas";
    }
    total += zona.cantidad;
  }
  if (total == 0) return 'Configura al menos una mesa';
  return null;
}

/// Genera la lista de mesas a partir de las [zonas], conservando las mesas
/// [actuales] que siguen existiendo (mismo id, nombre y orden: las comandas
/// abiertas no pierden su mesa). Las mesas nuevas se nombran como las demás
/// de su zona ("Mesa 13") o, en una zona nueva, con el nombre de la zona
/// ("Terraza 1"). Si una zona tiene menos mesas que antes se quitan las
/// últimas.
List<Mesa> mesasDesdeZonas(List<ZonaMesas> zonas, List<Mesa> actuales) {
  final idsUsados = {for (final mesa in actuales) mesa.id};
  final resultado = <Mesa>[];
  for (final zona in zonas) {
    final nombreZona = zona.zona.trim();
    final existentes = [
      for (final mesa in actuales)
        if (mesa.zona == nombreZona) mesa,
    ];
    final conservadas = existentes.take(zona.cantidad).toList();
    resultado.addAll(conservadas);
    if (conservadas.length >= zona.cantidad) continue;

    final prefijo = existentes.isEmpty
        ? nombreZona
        : existentes.first.nombre.replaceFirst(RegExp(r'\s*\d+$'), '').trim();
    final nombresUsados = {for (final mesa in conservadas) mesa.nombre};
    var orden = conservadas.fold<int>(
      0,
      (maximo, mesa) => mesa.orden > maximo ? mesa.orden : maximo,
    );
    var numero = conservadas.length;
    while (resultado.where((m) => m.zona == nombreZona).length <
        zona.cantidad) {
      numero++;
      final nombre = '${prefijo.isEmpty ? 'Mesa' : prefijo} $numero';
      if (!nombresUsados.add(nombre)) continue;
      orden++;
      final id = _idUnico(_slug(nombreZona), numero, idsUsados);
      resultado.add(
        Mesa(id: id, nombre: nombre, zona: nombreZona, orden: orden),
      );
    }
  }
  return resultado;
}

String _idUnico(String base, int numero, Set<String> usados) {
  var candidato = '$base-$numero';
  var sufijo = 1;
  while (!usados.add(candidato)) {
    sufijo++;
    candidato = '$base-$numero-$sufijo';
  }
  return candidato;
}

String _slug(String texto) {
  const acentos = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'ñ': 'n',
  };
  final buffer = StringBuffer();
  for (final caracter in texto.toLowerCase().split('')) {
    buffer.write(acentos[caracter] ?? caracter);
  }
  final slug = buffer
      .toString()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'mesa' : slug;
}

/// Mesas de [antes] que no siguen en [despues].
List<Mesa> mesasQuitadas(List<Mesa> antes, List<Mesa> despues) {
  final ids = {for (final mesa in despues) mesa.id};
  return [
    for (final mesa in antes)
      if (!ids.contains(mesa.id)) mesa,
  ];
}

// ---------------------------------------------------------------------------
// Consecuencias de guardar
// ---------------------------------------------------------------------------

/// Qué implica aplicar unos ajustes nuevos, para informar al usuario.
final class ResumenCambios extends Equatable {
  const ResumenCambios({this.avisos = const [], this.requiereReinicio = false});

  /// Efectos visibles del cambio (reconexiones, nuevos códigos...).
  final List<String> avisos;

  /// Algún cambio no puede aplicarse en caliente: hay que cerrar y volver a
  /// abrir la aplicación.
  final bool requiereReinicio;

  @override
  List<Object?> get props => [avisos, requiereReinicio];
}

/// Describe las consecuencias de pasar de [antes] a [despues].
///
/// En modo host todos los ajustes se aplican en caliente
/// (`HostRuntime.applySettings` reconstruye los adaptadores del ERP, MySQL e
/// impresoras y reinicia la red si cambian los puertos); en modo comandero
/// un cambio de identidad recrea la conexión. Solo el identificador del
/// dispositivo exigiría reiniciar, y la pantalla no permite cambiarlo.
ResumenCambios resumirCambios(AppSettings antes, AppSettings despues) {
  final avisos = <String>[];
  var reinicio = false;
  if (antes.deviceId != despues.deviceId) reinicio = true;
  if (antes.rol != despues.rol) {
    avisos.add(switch (despues.rol) {
      DeviceRole.host => 'El dispositivo pasa a funcionar como Servidor TPV.',
      DeviceRole.comandero => 'El dispositivo pasa a funcionar como Comandero.',
      null => 'El dispositivo vuelve al selector de modo.',
    });
  }
  if (despues.esHost) {
    if (antes.red.tcpPort != despues.red.tcpPort ||
        antes.red.discoveryPort != despues.red.discoveryPort) {
      avisos.add(
        'La red del servidor se reinicia con los nuevos puertos: los '
        'comanderos se reconectarán (actualiza el host manual de los que lo '
        'usen).',
      );
    }
    if (_vacioANulo(antes.red.pairingCode) !=
        _vacioANulo(despues.red.pairingCode)) {
      avisos.add(
        'Los comanderos deberán usar el nuevo código de emparejamiento.',
      );
    }
    if (antes.fsApi != despues.fsApi) {
      avisos.add(
        'Conexión con FacturaScripts actualizada: se recargará el catálogo '
        'y se reanudará la cola de sincronización.',
      );
    }
    if (antes.mysql != despues.mysql) {
      avisos.add('Conexión MySQL actualizada (stock y escandallos).');
    }
    if (antes.fiscal.modoAsientoZ != despues.fiscal.modoAsientoZ &&
        despues.fiscal.modoAsientoZ == ModoAsientoZ.resumenCompleto) {
      avisos.add(
        'Asiento Z en modo resumen completo: si las facturas ya generan '
        'asiento, el cierre se bloqueará para no duplicar la contabilidad.',
      );
    }
  } else if (despues.esComandero) {
    if (antes.deviceName != despues.deviceName ||
        antes.red.discoveryPort != despues.red.discoveryPort) {
      avisos.add('Se reinicia la conexión con el servidor.');
    }
  }
  return ResumenCambios(avisos: avisos, requiereReinicio: reinicio);
}

String? _vacioANulo(String? texto) {
  final limpio = texto?.trim();
  return (limpio == null || limpio.isEmpty) ? null : limpio;
}
