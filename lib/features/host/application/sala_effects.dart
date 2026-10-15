import '../../sala/domain/comanda.dart';
import '../../sala/domain/linea_comanda.dart';
import '../../sala/domain/marcha_pase.dart';
import '../../sala/domain/mesa.dart';
import '../../sala/domain/ticket.dart';
import '../domain/host_snapshot.dart';

/// Efectos secundarios de las mutaciones de la sala (impresión de comandas,
/// descuento de stock, facturación...).
///
/// Hay dos momentos:
///
/// * **Durable** (`al...`): se invoca de forma síncrona DENTRO de la
///   escritura atómica del diario que hace la mutación. Sirve para añadir al
///   snapshot el trabajo de la cola que la mutación exige (factura del
///   ticket, descuento de stock de la línea), de modo que ambos se guarden
///   juntos y un corte no deje el ticket sin su factura. Debe ser pura:
///   devuelve el snapshot (con lo añadido, p. ej. vía
///   `SyncOutbox.encolarEn`) y no hace E/S. Si lanza, la mutación sigue y se
///   avisa.
/// * **Posterior** (`on...`): `SalaService` lo lanza tras persistir la
///   mutación y nunca deja que un fallo suyo afecte a la respuesta al
///   comandero: cada error se convierte en un aviso operativo.
///
/// Las implementaciones sobreescriben solo lo que les interesa.
base class SalaEffects {
  const SalaEffects();

  /// Durable: se van a incorporar [nuevas] líneas a la comanda de [mesa].
  HostSnapshot alAceptarLineas(
    HostSnapshot snapshot,
    Mesa mesa,
    List<LineaComanda> nuevas,
  ) => snapshot;

  /// Durable: [linea] (ya en estado anulada) se va a anular en [mesa].
  HostSnapshot alAnularLinea(
    HostSnapshot snapshot,
    Mesa mesa,
    LineaComanda linea,
  ) => snapshot;

  /// Durable: [ticket] se va a archivar en el turno al cobrar la mesa.
  HostSnapshot alCobrar(HostSnapshot snapshot, Ticket ticket) => snapshot;

  /// Se incorporaron [nuevas] líneas a [comanda] (las duplicadas de una
  /// retransmisión no se incluyen).
  Future<void> onLineasAceptadas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> nuevas,
  ) async {}

  /// [linea] (ya en estado anulada) acaba de anularse en [comanda].
  Future<void> onLineaAnulada(
    Mesa mesa,
    Comanda comanda,
    LineaComanda linea,
  ) async {}

  /// Se anularon a la vez las [anuladas] de [comanda] (una sola al anular
  /// una línea; todas las activas al vaciar la mesa). Es lo que invoca
  /// `SalaService`; por defecto delega en [onLineaAnulada] línea a línea.
  /// Lo sobreescribe quien prefiera tratarlas juntas (p. ej. la impresión,
  /// para sacar un único aviso de anulación por puesto). Un fallo en una
  /// línea no impide tratar las demás: se relanza el primero al terminar.
  Future<void> onLineasAnuladas(
    Mesa mesa,
    Comanda comanda,
    List<LineaComanda> anuladas,
  ) async {
    (Object, StackTrace)? primerFallo;
    for (final linea in anuladas) {
      try {
        await onLineaAnulada(mesa, comanda, linea);
      } on Object catch (error, stackTrace) {
        primerFallo ??= (error, stackTrace);
      }
    }
    if (primerFallo case (final error, final stackTrace)) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Se registró [marcha] (nueva, nunca una retransmisión) en [comanda]:
  /// [lineas] son las activas del pase marchado, para imprimir el MARCHAR en
  /// cada puesto. Las marchas automáticas al aceptar líneas no pasan por
  /// aquí: sus líneas ya salen normales en la comanda de ese envío.
  Future<void> onPaseMarchado(
    Mesa mesa,
    Comanda comanda,
    MarchaPase marcha,
    List<LineaComanda> lineas,
  ) async {}

  /// La mesa se cobró y [ticket] quedó en el diario del turno.
  Future<void> onMesaCobrada(Ticket ticket) async {}
}
