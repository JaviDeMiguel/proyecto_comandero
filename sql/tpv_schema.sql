-- Tablas propias del TPV en la base de datos de FacturaScripts.
-- DDL canonico para utf8mb4 / utf8mb4_unicode_520_ci (la collation de
-- variantes.referencia en una instalacion nueva de FacturaScripts 2026).
-- Lo genera TpvSchema (lib/core/database/schema/tpv_schema.dart); en otras
-- instalaciones TpvSchemaMigrator.ensure() ajusta charset/collation a los de
-- variantes.referencia. Un test comprueba que este fichero y el codigo coinciden.
--
-- Nota: no hay CHECK (ref_plato <> ref_ingrediente) porque MySQL 8 prohibe
-- (errno 3823) un CHECK sobre columnas con accion referencial ON UPDATE CASCADE;
-- esa regla la aplica EscandalloRepository.

CREATE TABLE IF NOT EXISTS tpv_escandallos (
  id INT NOT NULL AUTO_INCREMENT,
  ref_plato VARCHAR(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci NOT NULL,
  ref_ingrediente VARCHAR(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci NOT NULL,
  cantidad DOUBLE NOT NULL,
  merma DOUBLE NOT NULL DEFAULT 0,
  observaciones VARCHAR(255) NULL,
  creado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  actualizado DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY tpv_uniq_escandallos_plato_ingrediente (ref_plato, ref_ingrediente),
  KEY tpv_idx_escandallos_ingrediente (ref_ingrediente),
  CONSTRAINT tpv_chk_escandallos_cantidad CHECK (cantidad > 0),
  CONSTRAINT tpv_chk_escandallos_merma CHECK (merma >= 0 AND merma < 100),
  CONSTRAINT tpv_fk_escandallos_plato FOREIGN KEY (ref_plato)
    REFERENCES variantes (referencia) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT tpv_fk_escandallos_ingrediente FOREIGN KEY (ref_ingrediente)
    REFERENCES variantes (referencia) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_520_ci;

CREATE TABLE IF NOT EXISTS tpv_movimientos_stock (
  id BIGINT NOT NULL AUTO_INCREMENT,
  operacion VARCHAR(64) NOT NULL,
  referencia VARCHAR(30) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci NOT NULL,
  codalmacen VARCHAR(4) NOT NULL,
  cantidad DOUBLE NOT NULL,
  motivo VARCHAR(20) NOT NULL,
  origen VARCHAR(100) NULL,
  creado DATETIME NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY tpv_uniq_movimientos_operacion (operacion, referencia, codalmacen),
  KEY tpv_idx_movimientos_referencia (referencia, codalmacen, creado)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_520_ci;
