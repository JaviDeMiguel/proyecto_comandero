import 'dart:async';
import 'dart:isolate';

/// Punto de entrada de un trabajo de isolate.
///
/// Debe ser una función **top-level o estática** (nunca un método de instancia
/// ni un closure): recibe un mensaje enviable (DTO plano, primitivos, listas,
/// mapas, `Uint8List`) y devuelve un resultado enviable.
typedef IsolateEntryPoint<M, R> = FutureOr<R> Function(M message);

/// Ejecuta trabajo pesado fuera del isolate de UI.
///
/// Los motores de `core/isolates` (ESC/POS, escandallos, reaprovisionamiento,
/// Cierre Z) se invocan siempre a través de esta interfaz, lo que permite
/// sustituirla por [InlineIsolateRunner] en tests deterministas.
abstract interface class IsolateRunner {
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  });
}

/// Implementación de producción: un isolate efímero por trabajo (`Isolate.run`).
///
/// El resultado vuelve con `Isolate.exit`, sin copia, por lo que devolver un
/// `Uint8List` grande (bytes ESC/POS) no bloquea el isolate de UI.
final class SpawningIsolateRunner implements IsolateRunner {
  const SpawningIsolateRunner();

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) => _spawn(entryPoint, message, debugName);
}

/// Ejecuta el trabajo en el isolate actual. Solo para tests y depuración.
final class InlineIsolateRunner implements IsolateRunner {
  const InlineIsolateRunner();

  @override
  Future<R> run<M, R>(
    IsolateEntryPoint<M, R> entryPoint,
    M message, {
    String? debugName,
  }) => Future<R>.sync(() => entryPoint(message));
}

// Top-level a propósito: el closure que viaja al isolate solo puede capturar
// `entryPoint` y `message`, nunca el contexto de quien llama (sockets, `this`,
// BuildContext...), que haría fallar el envío con "object is unsendable".
Future<R> _spawn<M, R>(
  IsolateEntryPoint<M, R> entryPoint,
  M message,
  String? debugName,
) => Isolate.run(() => entryPoint(message), debugName: debugName);
