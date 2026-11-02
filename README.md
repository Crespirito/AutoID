# Laboratorio Entra ID (Free) — Gestor de entornos

Conjunto de scripts PowerShell para crear, inspeccionar y limpiar entornos
de laboratorio en **Microsoft Entra ID (tenant Free)**: usuarios, grupos,
aplicaciones, service principals y sus relaciones.

Todo se orquesta desde `menu.ps1`, que gestiona la sesión de Microsoft
Graph y delega en scripts hijos. Los objetos creados se registran en un
**manifiesto JSON** para poder eliminarlos después de forma controlada.

---

## Requisitos

- PowerShell 5.1 o superior.
- Módulo `Microsoft.Graph` (el menú instala los submódulos necesarios bajo demanda).
- Tenant de Entra ID en plan **Free**.
- Para autenticación App-Only: un registro de aplicación en Entra ID con su certificado y permisos de aplicación concedidos.

---

## Estructura de ficheros

| Fichero | Rol |
|---|---|
| `menu.ps1` | Punto de entrada. Conecta a Graph, muestra estado, gestiona módulos y lanza acciones. |
| `creauto.ps1` | Crea un escenario predefinido (2 usuarios, 1 app + SP, 1 grupo, membresía) con simulación previa. |
| `creamanual.ps1` | Construcción interactiva de un escenario a medida con simulaciones por objeto. |
| `clean_up.ps1` | Elimina los objetos del manifiesto en orden seguro (con reintentos). |
| `lib_ui.ps1` | Helpers de consola (colores, banners, pausas, confirmaciones). |
| `lib_graph.ps1` | Sesión de Graph: carga selectiva de módulos, App-Only con certificado, fallback interactivo y caché. |
| `lib_config.ps1` | Configuración persistente (`menu_config.json`), incluyendo datos App-Only. |
| `lib_manifiesto.ps1` | Lectura/escritura del manifiesto (`manifiesto_lab.json`). |
| `lib_log.ps1` | Log en memoria y volcado a CSV. |

Ficheros generados en tiempo de ejecución:

- `menu_config.json` — preferencias y datos de conexión App-Only.
- `manifiesto_lab.json` — objetos creados pendientes de limpiar.
- `manifiesto_lab_procesado_<timestamp>.json` — manifiesto ya procesado.
- `log_creauto_*.csv`, `log_creamanual_*.csv`, `log_cleanup_*.csv` — logs de cada ejecución.

---

## Configuración inicial (solo una vez)

Para que el menú se conecte sin interacción (App-Only), necesitas una App en Entra ID:

1. Registra una aplicación en Entra ID y anota su **Client ID** y **Tenant ID**.
2. Genera un certificado autofirmado y súbelo a la App (sección "Certificados y secretos").
3. Concede los permisos de **Aplicación** necesarios (`User.ReadWrite.All`, `Group.ReadWrite.All`, `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`) y otorga el consentimiento de administrador.
4. Arranca `menu.ps1`, ve a `[C] Gestionar sesión de Graph` y selecciona `[2] Introducir datos App-Only`. Rellena Client ID, Tenant ID y Thumbprint.

Los datos se guardan en `menu_config.json` y se usarán automáticamente en el próximo arranque.

---

## Uso

.\menu.ps1


Al arrancar se conecta a Graph (App-Only si está configurado; si no, flujo interactivo) y muestra el estado actual (sesión, configuración, manifiesto pendiente). Desde el menú:

## Creación

[1] Creación automática — escenario de ejemplo con simulación global y confirmación previa.

[2] Creación manual — añadir usuarios, grupos, apps y relaciones con simulación por objeto.

## Limpieza y manifiesto
[3] Limpiar entorno — borra los objetos del manifiesto en orden seguro.

[4] Ver manifiesto — inspecciona qué hay pendiente de limpiar.

## Sesión y configuración
[C] Gestionar sesión — reconectar o introducir/editar datos App-Only.

[M] Gestionar módulos — instalar y cargar submódulos de Graph bajo demanda.

[V] Alternar Verbose — más detalle en la salida.

[R] Resetear configuración — vuelve a los valores por defecto.

[I] Info tenant Free — qué se puede y qué no se puede hacer.

[0] Salir — guarda configuración y cierra sesión.

## Flujo típico
Ejecutar menu.ps1 (con App-Only ya configurado si es posible).

Opción [1] o [2] para crear el escenario. Revisa la simulación y confirma con SI.

Probar el escenario (iniciar sesión con las credenciales mostradas).

Opción [3] para limpiar todo lo creado.

Opción [0] para salir.

## Orden de borrado
clean_up.ps1 elimina en este orden para romper dependencias:

Aplicaciones y sus service principals (incluye owners y asignaciones).

Service principals huérfanos.

Grupos (vaciando miembros y owners antes de borrar).

Usuarios.

Cada borrado se reintenta hasta 3 veces (2 s entre intentos) para absorber errores transitorios de Graph.

## Limitaciones (tenant Free)
### Disponible:

Usuarios, grupos de seguridad, aplicaciones y service principals.

Membresías de grupo.

Owners de service principals.

Credenciales en aplicaciones.

Permisos de API en aplicaciones.

### No disponible (requiere P1/P2):

Asignación de roles de directorio.

Grupos con asignación de roles.

Grupos dinámicos.

Acceso condicional avanzado.

Gestión de PIM.

# Notas de seguridad
Las contraseñas del escenario automático están hardcodeadas en creauto.ps1 (bloque "SOLO LAB"). Cámbialas si lo usas fuera de un entorno aislado.

El manifiesto no guarda contraseñas. Solo los identificadores necesarios para borrar los objetos.

Los logs CSV pueden contener UPNs y nombres de objetos. Trátalos como información sensible.

El certificado App-Only debe guardarse en el almacén de la máquina que ejecuta el script. Si se mueve a otra máquina, hay que importarlo allí.

# Solución de problemas
"No hay sesión de Graph activa"
Los scripts hijos no conectan por su cuenta. Ejecútalos siempre desde menu.ps1 o usa [C] para conectar.

### "Manifiesto presente pero ilegible"
El fichero manifiesto_lab.json está corrupto (normalmente por interrumpir un script con Ctrl+C). Bórralo y vuelve a empezar:

### powershell
Remove-Item .\manifiesto_lab.json -Force
"User canceled authentication" sin haber cancelado nada
Es el fallo de WAM en la versión 2.41 del módulo. Configura App-Only con el certificado ([C]) o baja a la versión 2.33 del módulo Microsoft.Graph.Authentication.

### Fallo App-Only: "Certificate not found"
El thumbprint no coincide con ningún certificado del almacén Cert:\CurrentUser\My. Verifica que el certificado está instalado y que el thumbprint es correcto.

### powershell
Get-ChildItem Cert:\CurrentUser\My | Select-Object Thumbprint, Subject
Errores 403 / "Insufficient privileges"
La App-Only no tiene los permisos de aplicación necesarios o falta el consentimiento de administrador. Revisa los permisos en el portal de Entra ID.

### "Fallo tras 3 intentos" al limpiar
Graph devolvió 404 transitorio o el objeto tiene dependencias que no se pudieron romper. Vuelve a ejecutar [3]; el manifiesto se conserva si hubo errores.

### Los logs se acumulan
Cada ejecución genera un log_*.csv. Bórralos periódicamente:

### powershell
Remove-Item log_*.csv
Encoding roto en mensajes ("l�nea", acentos raros)
Algún .ps1 se guardó sin BOM. Vuelve a guardarlo como UTF-8 con BOM.
