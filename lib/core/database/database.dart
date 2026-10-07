/// Acceso MySQL directo a la base de datos de FacturaScripts: conexión,
/// transacciones con reintento, esquema `tpv_*` y repositorios de
/// escandallos y stock.
library;

export 'mysql_client_connection.dart'
    show
        MysqlClientConnection,
        decodeMysqlTextValue,
        encodeMysqlParam,
        formatMysqlDateTime,
        translateMysqlError;
export 'mysql_config.dart';
export 'mysql_database.dart';
export 'repositories/escandallo_repository.dart';
export 'repositories/stock_repository.dart';
export 'schema/tpv_schema.dart';
export 'sql_executor.dart';
