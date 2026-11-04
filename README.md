# Laboratorio Entra ID (Free) — Gestor de entornos

Conjunto de scripts PowerShell para crear, inspeccionar y limpiar entornos
de laboratorio en **Microsoft Entra ID (tenant Free)**: usuarios, grupos,
aplicaciones, service principals y sus relaciones.

Todo se orquesta desde `menu.ps1`, que gestiona la sesión de Microsoft
Graph (autenticación delegada) y delega en scripts hijos. Los objetos
creados se registran en un **manifiesto JSON** para poder eliminarlos
después de forma controlada.

Las contraseñas de los usuarios **no se guardan en ningún JSON**: se
derivan de una **semilla local por escenario** (fuera de Git) y se
muestran al operador una sola vez.

---

## Requisitos

- PowerShell 5.1 o superior.
- Módulo `Microsoft.Graph` (el menú lo instala si no está presente).
- Tenant de Entra ID en plan **Free**.
- Permisos delegados para los scopes declarados en `lib_graph.ps1`:
  - Free: `User.ReadWrite.All`, `Group.ReadWrite.All`,
    `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`,
    `Directory.Read.All`.
  - Extendidos (pueden requerir P1/P2): `AdministrativeUnit.ReadWrite.All`,
    `RoleManagement.ReadWrite.Directory`.
- Si el tenant no soporta los scopes extendidos, el menú permite conectar
  con `-SoloFree` (solo scopes Free).

---

## Estructura de ficheros

| Fichero | Rol |
|---|---|
| `menu.ps1` | Punto de entrada. Conecta a Graph, muestra estado, lanza acciones. |
| `creauto.ps1` | Crea un escenario predefinido desde `escenarios/escenario/`. Soporta `-DryRun`. Deriva contraseñas desde la semilla local. |
| `creamanual.ps1` | Construcción interactiva de un escenario a medida. Permite introducir contraseñas manualmente o generarlas desde la semilla de la sesión. |
| `clean_up.ps1` | Elimina los objetos del manifiesto en orden seguro. |
| `generar_biblioteca.ps1` | Genera los escenarios y vulnerabilidades de ejemplo en `escenarios/`, y crea las semillas locales si no existen. |
| `lib_ui.ps1` | Helpers de consola (colores, banners, pausas, confirmaciones). |
| `lib_graph.ps1` | Sesión de Graph: instalación del módulo, conexión delegada, estado, desconexión, reintento. |
| `lib_config.ps1` | Configuración persistente (`menu_config.json`). |
| `lib_manifiesto.ps1` | Lectura/escritura del manifiesto (`manifiesto_lab.json`). |
| `lib_escenarios.ps1` | Carga y validación de escenarios y vulnerabilidades, y aplicadores por tipo. |

Ficheros generados en tiempo de ejecución:

- `menu_config.json` — preferencias del menú (`Verbose`).
- `manifiesto_lab.json` — objetos creados pendientes de limpiar.
- `manifiesto_lab_procesado_<timestamp>.json` — manifiesto ya procesado.
- `log_creauto_*.csv`, `log_personalizada_*.csv`, `log_cleanup_*.csv` — logs de cada ejecución.
- `escenarios/.secrets/<escenario>.seed` — semilla local por escenario (fuera de Git).
- `escenarios/escenario/*.json` y `escenarios/vulnerab/*.json` — escenarios y vulnerabilidades (generados por `generar_biblioteca.ps1` o escritos a mano).

---

## Gestión de contraseñas (modelo de semilla)

Los JSON de escenario **no contienen contraseñas**. Cada escenario tiene
una semilla local en `escenarios/.secrets/<escenario>.seed` (32 bytes
aleatorios, Base64). De ella se deriva la contraseña de cada usuario:

password = HMAC-SHA256(semilla, upn) → Base64 → 16 chars + "!Aa1"



Propiedades del modelo:

- **Determinista:** misma semilla + mismo UPN → misma contraseña.
- **Única por usuario:** cada UPN produce una contraseña distinta.
- **Reproducible:** conservando la semilla, se pueden regenerar las
  contraseñas sin haberlas guardado.
- **Fuera de Git:** `escenarios/.secrets/` está en `.gitignore`.

En `creauto.ps1` las contraseñas se generan siempre desde la semilla y se
muestran **una sola vez** al final. En `creamanual.ps1` el operador puede:

- Introducir la contraseña manualmente (`Read-Host -AsSecureString`, no se
  muestra en pantalla), o
- Generarla automáticamente desde la semilla de la sesión manual
  (`manual_<timestamp>.seed`), en cuyo caso se muestra una sola vez.

En ningún caso la contraseña se guarda en el manifiesto ni se imprime en el
resumen final.

---

## Configuración inicial

No requiere App-Only ni certificados. El menú usa **autenticación
delegada** con `Connect-MgGraph`. La primera vez que se ejecuta, abrirá el
flujo interactivo de Microsoft Graph para que el operador inicie sesión y
consienta los scopes.

Si el tenant no soporta los scopes extendidos, el menú avisará y se puede
usar la conexión `-SoloFree` desde `[C] Gestionar sesión de Graph`.

---

## Uso

.\menu.ps1

Al arrancar se conecta a Graph (flujo interactivo) y muestra el estado
actual (sesión, configuración, manifiesto pendiente). Desde el menú:

Creación
[1] Creación automática (creauto.ps1) — escoge un escenario de
escenarios/escenario/, muestra un resumen, pide confirmación y crea los
objetos. Soporta -DryRun para simular sin tocar el tenant.

[2] Creación manual (creamanual.ps1) — añade usuarios, grupos,
apps y relaciones de forma interactiva.

Limpieza y manifiesto
[3] Limpiar entorno (clean_up.ps1) — borra los objetos del
manifiesto en orden seguro.

[4] Ver manifiesto — inspecciona qué hay pendiente de limpiar.

Sesión y configuración
[C] Gestionar sesión de Graph — ver estado, reconectar.

[V] Alternar Verbose — más detalle en la salida.

[R] Resetear configuración — vuelve a los valores por defecto.

[I] Info tenant Free — qué se puede y qué no se puede hacer.

[0] Salir — guarda configuración y cierra sesión.

Flujo típico
Ejecutar .\menu.ps1. Aceptar el flujo interactivo de Graph.

(Opcional) Ejecutar .\generar_biblioteca.ps1 para crear los escenarios
de ejemplo y sus semillas locales.

Opción [1] o [2] para crear el escenario. Revisar el resumen y
confirmar con SI.

Anotar las contraseñas mostradas (solo se muestran una vez).

Probar el escenario (iniciar sesión con las credenciales anotadas).

Opción [3] para limpiar todo lo creado.

Opción [0] para salir.

Orden de borrado
clean_up.ps1 elimina en este orden para romper dependencias:

Vulnerabilidades aplicadas (owners de SP, owners de grupo,
credenciales de app, roles PIM elegibles).

Aplicaciones y sus service principals (incluye asignaciones de
roles de aplicación).

Service principals huérfanos registrados directamente en el
manifiesto.

Grupos (vaciando miembros y owners antes de borrar).

Usuarios.

Al terminar, el manifiesto se renombra con sufijo
_procesado_<timestamp> para evitar reprocesarlo.

Limitaciones (tenant Free)
Disponible
Usuarios, grupos de seguridad, aplicaciones y service principals.

Membresías de grupo.

Owners de service principals.

Owners de grupo.

Credenciales en aplicaciones (client secrets).

No disponible (requiere P1/P2)
Asignación de roles de directorio.

Grupos con asignación de roles.

Grupos dinámicos.

Acceso condicional avanzado.

Gestión de PIM (roles elegibles).

Los aplicadores de vulnerabilidad de PIM (PimEligibleRole) están
implementados, pero fallarán en un tenant Free. Están pensados para
tenants con P2.


Notas de seguridad
No hay contraseñas en los JSON. Se derivan de la semilla local de
cada escenario. Conserva escenarios/.secrets/ fuera de Git.

.gitignore excluye escenarios/.secrets/, *.seed,
manifiesto_lab*.json, menu_config.json, biblioteca.json y
log_*.csv.

El manifiesto no guarda contraseñas. Solo los identificadores
necesarios para borrar los objetos.

Los logs CSV pueden contener UPNs y nombres de objetos. Trátalos
como información sensible y bórralos periódicamente.

La semilla es el secreto maestro del escenario. Si se pierde, no se
pueden reproducir las contraseñas ya mostradas. Si se filtra, se pueden
regenerar todas las contraseñas de ese escenario.

No uses este laboratorio en un tenant de producción. Está diseñado
para entornos aislados de prácticas.

Solución de problemas
"No hay sesión de Graph activa"
Los scripts hijos no conectan por su cuenta. Ejecútalos siempre desde
menu.ps1 o usa [C] para conectar.

"Manifiesto presente pero ilegible"
El fichero manifiesto_lab.json está corrupto (normalmente por interrumpir
un script con Ctrl+C). Bórralo y vuelve a empezar:

Remove-Item .\manifiesto_lab.json -Force

"No existe la semilla del escenario"
No es un error: creauto.ps1 genera la semilla automáticamente la primera
vez que se ejecuta un escenario. Si quieres crearla antes, ejecuta
.\generar_biblioteca.ps1.

"No se pudieron restringir los permisos de la semilla"
En sistemas no Windows, o si las ACL fallan, la semilla se crea igualmente.
Asegúrate de que escenarios/.secrets/ no está en Git.

Errores 403 / "Insufficient privileges"
El operador no ha consentido todos los scopes, o el tenant no soporta los
scopes extendidos. Prueba a conectar con -SoloFree desde
[C] Gestionar sesión de Graph.

"Fallo al aplicar la vulnerabilidad"
En un tenant Free, las vulnerabilidades de PIM (PimEligibleRole) fallarán
porque requieren P2. Usa escenarios sin vulnerabilidad PIM o un tenant con
P2.

"Verificación final con fallos"
Algún objeto no se creó correctamente. Revisa el log CSV de la ejecución.
El manifiesto se guarda igualmente con lo que sí se creó, para que el
cleanup pueda revertirlo.

Los logs se acumulan
Cada ejecución genera un log_*.csv. Bórralos periódicamente:

Remove-Item log_*.csv

Encoding roto en mensajes ("l�nea", acentos raros)
Algún .ps1 se guardó sin BOM. Vuelve a guardarlo como UTF-8 con BOM.

Licencia
Uso educativo y de laboratorio. Sin garantías. El operador es responsable
del uso que haga de los scripts en su tenant.

