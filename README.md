===============================================================================
#                LABORATORIO ENTRA ID - GESTOR DE ENTORNOS
===============================================================================

Conjunto de scripts PowerShell para crear, inspeccionar y limpiar entornos de
laboratorio en Microsoft Entra ID: usuarios, grupos, aplicaciones, service
principals, unidades administrativas, roles PIM y vulnerabilidades aplicadas
sobre objetos existentes.

Todo se orquesta desde menu.ps1, que gestiona la sesión de Graph (App-Only
con certificado por defecto, o delegada vía az login como opción) y delega en
scripts hijos. Los objetos creados y las vulnerabilidades aplicadas se
registran en un manifiesto JSON para poder revertirlos después de forma
controlada.

Arquitectura modular por capacidades: añadir o quitar una funcionalidad es
añadir o borrar un archivo. No hay que tocar el núcleo.

Requisitos: PowerShell 5.1+ | Microsoft.Graph | Entra ID (Free, P1 o P2)


-------------------------------------------------------------------------------
# 1. QUÉ ES Y QUÉ NO ES
-------------------------------------------------------------------------------

## ES:
 - Un gestor de entornos de laboratorio en Entra ID.
 - Modular: cada funcionalidad es una capacidad autocontenida.
 - Multi-nivel: Free, P1 y P2, con detección automática de licencia (nivel efectivo).
 - Reproducible: contraseñas derivadas de una semilla local por escenario.
 - Seguro por defecto: no adopta objetos preexistentes, no guarda secretos,
 - verifica objectId antes de borrar.
 - Capaz de aplicar vulnerabilidades sobre objetos existentes (no solo
 -  crear escenarios desde cero).

## NO ES:

 - Una herramienta de producción.
 - Un reemplazo de Terraform, Bicep o la CLI de Azure.
 - Un backup de Entra ID. El manifiesto registra lo creado/modificado, no el estado previo del tenant.
 - Un sistema de gestión de identidades. Es un laboratorio para practicar.


-------------------------------------------------------------------------------
# 2. CARACTERÍSTICAS PRINCIPALES
-------------------------------------------------------------------------------

 - Arquitectura modular por capacidades. Añadir o quitar una capacidad = añadir o borrar un cap_*.ps1 en la carpeta del nivel. Nada más.
 - Niveles Free / P1 / P2 con nivel efectivo. El nivel efectivo es el mínimo entre el configurado y el real del tenant. Se usa para filtrar qué vulnerabilidades puedes crear: no te ofrece lo que el tenant no soporta, ni más de lo que tú has pedido.
 - Creación automática de escenarios con flujo nivel -> tipo -> crear. Elegir nivel, elegir plantilla o escenario, revisar resumen, crear. Opción de parar y guardar plantilla en cualquier momento.
 - Creación manual de escenarios con menú generado desde capacidades. Las opciones del menú salen de las capacidades registradas. Añadir una capacidad nueva la hace aparecer automáticamente.
 - Creación de vulnerabilidades sobre objetos existentes. Flujo propio ([5]) con:
   * Listado de tipos agrupados por nivel.
   * Tipos no disponibles deshabilitados con motivo.
   * Catálogo de vulnerabilidades por nombre (A + B: aplicar tal cual o sobrescribir parámetros).
   * Filtrado por nivel efectivo.
 - Contraseñas derivadas de semilla local. Los JSON no contienen contraseñas. Se derivan con HMAC-SHA256(semilla, UPN) y se muestran una sola vez.
 - Snapshot pre-lab. Antes de crear o de aplicar una vulnerabilidad, se construye un snapshot de lo que ya existe en el tenant. Los objetos preexistentes no se adoptan ni se modifican.
 - Cleanup con despacho por capacidad. El manifiesto guarda la capacidad que creó/aplicó cada elemento. El cleanup despacha a su Revertir sin un switch gigante.Orden: primero vulnerabilidades, luego objetos (LIFO).
 - Verificación de objectId antes de borrar. Si el objeto del manifiesto no coincide con el actual (borrado y recreado externamente), no se borra. Aplica a objetos y a vulnerabilidades (a través del objeto afectado).
 - App-Only con certificado. Sin secretos en el repo. El certificado vive en Cert:\CurrentUser\My. Se puede importar un .pfx desde el propio menú.
 - az login como alternativa. Conexión delegada opcional desde [C] -> [3], forzando el flujo de navegador (desactiva WAM) para elegir el usuario.

-------------------------------------------------------------------------------
# 3. REQUISITOS
-------------------------------------------------------------------------------

 - PowerShell 5.1 o superior.
 - Módulo Microsoft.Graph (el menú lo instala si no está presente).
 - Tenant de Entra ID en plan Free, P1 o P2.
 - Registro de App en Entra ID con:
     * Client ID y Tenant ID anotados.
     * Certificado (.cer) subido en Certificates & secrets.
     * Permisos de aplicación concedidos con consentimiento de administrador:
              User.ReadWrite.All
              Group.ReadWrite.All
              Application.ReadWrite.All
              AppRoleAssignment.ReadWrite.All
              Directory.Read.All
     * Según las capacidades que se usen, también:
              AdministrativeUnit.ReadWrite.All
              RoleManagement.ReadWrite.Directory
              Policy.ReadWrite.ConditionalAccess
              LicenseAssignment.ReadWrite.All
              UserAuthenticationMethod.ReadWrite.All
 - Certificado con clave privada en Cert:\CurrentUser\My, o un .pfx para. importar desde el menú ([C]).


-------------------------------------------------------------------------------
# 4. INSTALACIÓN RÁPIDA
-------------------------------------------------------------------------------

   1. Clonar el repositorio.

   2. Ejecutar el menú:

    .\menu.ps1

   3. Configurar App-Only desde [C] Gestionar sesión de Graph:
        - Opción [2] Configurar certificado App-Only.
        - Seleccionar un certificado del store o importar un .pfx.
        - Introducir ClientId y TenantId.
        - Los tres datos se guardan en menu_config.json.

   4. (Opcional) Generar escenarios de ejemplo:

        .\generar_biblioteca.ps1

       Crea escenarios, catálogo de vulnerabilidades, plantillas y semillas
       locales en escenarios/. Detecta el nivel del tenant si hay sesión.


-------------------------------------------------------------------------------
# 5. CONEXIÓN A GRAPH
-------------------------------------------------------------------------------

### El programa tiene DOS modos de conexión:

    MODO                        CUÁNDO SE USA               PERMISOS
    --------------------------  --------------------------  --------------------
    App-Only con certificado    Al arrancar, automático     Los de la App
    (por defecto)                                           registrada

    Delegado vía az login       Manualmente, desde          Los del usuario
    (opcional)                  [C] -> [3]                  que inicia sesión

  * La conexión inicial siempre es App-Only. Si falla (certificado no encontrado, datos incompletos, permisos), el menú arranca sin sesión y avisa. En ese caso, puedes:
    - Reconfigurar el certificado desde [C] -> [2].
    - Conectar vía az login desde [C] -> [3].

**SOBRE az login Y WAM:**
En Windows, Azure CLI usa el Web Account Manager (WAM) por defecto desde la versión 2.61.0, que tiende a reutilizar la cuenta del sistema operativo. La opción [3] del menú DESACTIVA WAM
(az config set core.enable_broker_on_windows=false) y limpia la sesión (az account clear) antes de lanzar az login, para que te pida elegir el usuario.

**Si az login FALLA DESPUÉS DE AUTENTICARTE:**
  - Comprueba que el módulo Microsoft.Graph.Authentication no está en una versión con regresión conocida (2.35.1). Si lo está, actualiza o baja a 2.35.0.
  - Comprueba que el token se pasa como string plano, no como SecureString (el código ya lo hace así).


-------------------------------------------------------------------------------
# 6. ESTRUCTURA DEL REPOSITORIO
-------------------------------------------------------------------------------

    <raíz>/
    +-- menu.ps1                  Punto de entrada.
    +-- creauto.ps1               Creación automática de escenarios.
    +-- creamanual.ps1            Creación manual de escenarios.
    +-- clean_up.ps1              Limpieza por despacho de capacidad.
    +-- generar_biblioteca.ps1    Generador de escenarios, catálogo y plantillas.
    |
    +-- lib_ui.ps1                Helpers de consola.
    +-- lib_graph.ps1             Sesión App-Only y az login.
    +-- lib_config.ps1            Configuración persistente.
    +-- lib_manifiesto.ps1        Manifiesto v2.1 y migraciones desde v1/v2.
    +-- lib_escenarios.ps1        Normalización de escenarios y catálogo.
    +-- lib_niveles.ps1           Niveles Free / P1 / P2 y nivel efectivo.
    +-- lib_caps.ps1              Loader y registro de capacidades.
    +-- lib_creadores.ps1         Orquestación de creación y reversión.
    |
    +-- lib_caps/
    |   +-- free/                 Capacidades disponibles en Free.
    |   +-- p1/                   Capacidades que requieren P1.
    |   +-- p2/                   Capacidades que requieren P2.
    |
    +-- escenarios/
    |   +-- escenario/            Escenarios propios y de ejemplo.
    |   +-- vulnerab/             Catálogo de vulnerabilidades por nombre.
    |   +-- plantillas/           Esqueletos para el flujo nivel -> tipo.
    |   +-- .secrets/             Semillas locales (NO se sube a Git).
    |
    +-- docs/
    |   +-- capacidades.md        Contrato de capacidad y guía de extensión.
    |   +-- escenarios.md         Formato del JSON de escenario.
    |   +-- manifiesto.md         Estructura del manifiesto y cleanup.
    |   +-- vulnerabilidades.md   Subsistema de vulnerabilidades.
    |
    +-- .gitignore
    +-- README.md

Para el detalle de cada parte, ver docs/.


-------------------------------------------------------------------------------
# 7. USO
-------------------------------------------------------------------------------

## Al arrancar menu.ps1:

 - Si menu_config.json tiene datos App-Only completos, conecta automáticamente.
 - Si no, avisa y arranca sin sesión. Se configura desde [C].

## OPCIONES DEL MENÚ:

### CREACIÓN (ESCENARIOS)
    [1]  Creación automática (nivel -> tipo -> crear)
    [2]  Creación manual (menú generado desde capacidades)

### VULNERABILIDADES
    [5]  Crear vulnerabilidad (aplicar sobre objetos existentes)
    [6]  Ver vulnerabilidades del manifiesto

### LIMPIEZA
    [3]  Limpiar entorno (vulnerabilidades primero, luego objetos)

### MANIFIESTO
    [4]  Ver manifiesto

### SESIÓN Y CONFIGURACIÓN
    [C]  Gestionar sesión de Graph (App-Only / az login)
    [N]  Cambiar nivel de licencia
    [K]  Ver capacidades disponibles
    [V]  Alternar Verbose
    [R]  Resetear configuración
    [0]  Salir

### FICHEROS GENERADOS EN RUNTIME:

1. menu_config.json                           Configuración local.
2. manifiesto_lab.json                        Manifiesto v2.1 pendiente.
3. manifiesto_lab_procesado_<timestamp>.json  Manifiesto ya procesado.
4. log_creauto_*.csv                          Log de creación automática.
5. log_personalizada_*.csv                    Log de creación manual.
6. log_cleanup_*.csv                          Log de limpieza.


-------------------------------------------------------------------------------
# 8. FLUJO TÍPICO
-------------------------------------------------------------------------------

 1. Crear el certificado y registrar la App en Entra ID (una sola vez).
 2. Ejecutar .\menu.ps1.
 3. Entrar en [C] -> [2] y configurar el certificado App-Only.
 4. (Opcional) Ejecutar .\generar_biblioteca.ps1 para crear escenarios de ejemplo, catálogo de vulnerabilidades y plantillas.
 5. Opción [1] o [2] para crear el escenario. Revisar el resumen y confirmar con SI.
 6. Anotar las contraseñas mostradas (solo se muestran una vez).
 7. Opción [5] para aplicar vulnerabilidades sobre los objetos creados. Elegir tipo manualmente o cargar del catálogo.
 8. Probar el escenario y las vulnerabilidades (iniciar sesión, comprobar owners, secretos, roles PIM...).
 9.  Opción [3] para limpiar todo lo creado y aplicado.
 10. Opción [0] para salir.


-------------------------------------------------------------------------------
# 9. MODELO DE SEMILLA Y CONTRASEÑAS
-------------------------------------------------------------------------------

Los escenarios **NO** contienen contraseñas. Cada escenario tiene una semilla local
en escenarios/.secrets/<escenario>.seed (32 bytes aleatorios en Base64, fuera
de Git). De ella se deriva la contraseña de cada usuario:

    password = HMAC-SHA256(semilla, upn) -> Base64 -> 16 chars + "!Aa1"

### Propiedades:

 - Determinista: misma semilla + mismo UPN -> misma contraseña.
 - Única por usuario: cada UPN produce una contraseña distinta.
 - Reproducible: conservando la semilla, se regeneran las contraseñas.
 - 20 caracteres: cumple la política de Entra ID (mayúsculas, minúsculas, números, símbolos).
 - Fuera de Git: escenarios/.secrets/ está en .gitignore.

En creauto.ps1 las contraseñas se generan desde la semilla y se muestran **UNA
SOLA VEZ al final**. En creamanual.ps1 el operador puede introducirlas
manualmente o generarlas desde la semilla de la sesión.

En ningún caso la contraseña se guarda en el manifiesto ni en el JSON.

Si se pierde la semilla, no se pueden reproducir las contraseñas ya mostradas.
Si se filtra, se pueden regenerar todas las contraseñas de ese escenario.


-------------------------------------------------------------------------------
# 10. SEGURIDAD Y .GITIGNORE
-------------------------------------------------------------------------------

## NO SE SUBE A GIT:

    escenarios/.secrets/          Semillas locales.
    *.seed                        Semillas locales (cualquier ubicación).
    manifiesto_lab*.json          Manifiesto (UPNs y nombres del tenant).
    *_procesado_*.json            Manifiesto ya procesado.
    menu_config.json              ClientId, TenantId, Thumbprint.
    log_*.csv                     Logs con UPNs y nombres.
    biblioteca.json               Artefacto de generación.

## SÍ SE SUBE A GIT:

    Scripts (.ps1).
    lib_caps/free|p1|p2/          Capacidades.
    docs/                         Documentación.
    escenarios/escenario/         Escenarios de ejemplo (sin secretos).
    escenarios/vulnerab/          Catálogo de vulnerabilidades (sin secretos).
    escenarios/plantillas/        Plantillas.
    .gitignore
    README.md

## **ADVERTENCIA:**

    El manifiesto y los logs contienen UPNs y nombres de objetos del tenant
    real. Trátalos como información sensible. Bórralos periódicamente.


-------------------------------------------------------------------------------
# 11. CÓMO AÑADIR UNA CAPACIDAD
-------------------------------------------------------------------------------

 1. Crear lib_caps/<nivel>/cap_<nombre>.ps1.
 2. Declarar $Capacidad con los campos del contrato.
 3. Implementar los scriptblocks (TestDisponible, ValidarDef, Describir, Crear, Revertir, PreguntarUI).
 4. Registrar con Register-LabCapacidad -Capacidad $Capacidad.
 5. Añadir Descripcion en español para el menú.
 6. Probar con menu.ps1 -> [K] Ver capacidades.

No hay que tocar el núcleo. La capacidad aparece automáticamente en el flujo
automático (si el escenario declara su sección) y en el menú manual.

Detalle completo del contrato: docs/capacidades.md.

**EXCEPCIÓN:** si la capacidad no consume sección del escenario
(SeccionJson = $null), hay que añadir un flujo dedicado en menu.ps1. Es el
caso de Vulnerabilidades. Ver docs/vulnerabilidades.md.


-------------------------------------------------------------------------------
# 12. CÓMO AÑADIR UN TIPO DE VULNERABILIDAD
-------------------------------------------------------------------------------

1. Añadir una entrada en $script:VulnTipos de cap_vulnerabilidades.ps1:
    - Nivel.
    - DependeDe.
    - Validar.
    - Aplicar.
    - Revertir.
    - Describir.
    - ParametrosUI.
    - PreRevertir (opcional).
2. Implementar Invoke-Vuln<NuevoTipo> e Invoke-RevertirVuln<NuevoTipo>.
3. (Opcional) Añadirlo a ObtenerClaves si toca objetos con claves específicas.

No hay que tocar menu.ps1, lib_caps.ps1, lib_creadores.ps1 ni
lib_manifiesto.ps1.

**Detalle completo: docs/vulnerabilidades.md.**


-------------------------------------------------------------------------------
# 13. CÓMO QUITAR UNA CAPACIDAD O UN NIVEL
-------------------------------------------------------------------------------
**Opciones**
1. Borrar el cap_*.ps1.
     La capacidad desaparece. Los escenarios que usen su sección fallan con un mensaje claro.

2. Renombrar la carpeta del nivel.
   p2/ -> p2.disabled/
    Todas las capacidades de ese nivel quedan desactivadas. Es la forma de hacer una distribución "solo hasta P1" o "solo Free".
    Efecto colateral: PimEligibleRole (vulnerabilidad) deja de ofrecerse porque delega en cap_pim.ps1.

3. Renombrar el archivo.
   cap_pim.ps1 -> cap_pim.ps1.disabled
    Solo esa capacidad desaparece.

En los tres casos, el programa sigue funcionando. No hay que tocar el núcleo.

-------------------------------------------------------------------------------
# 14. DOCUMENTACIÓN
-------------------------------------------------------------------------------

   **docs/capacidades.md**
        Contrato de capacidad, cómo añadir o quitar capacidades, capacidades
        disponibles por nivel, licencias y TestDisponible.

  **docs/escenarios.md**
        Formato del JSON de escenario, secciones por capacidad, alias,
        plantillas, normalización y modelo de semilla.

  **docs/manifiesto.md**
        Estructura v2.1 del manifiesto, estados, migración desde v1/v2, y
        cómo funciona el cleanup con verificación de objectId.

  **docs/vulnerabilidades.md**
        Subsistema de vulnerabilidades: tipos, niveles, catálogo, flujo
        [5]/[6], A + B, ObtenerClaves, PreRevertir, delegación PIM, estados.


-------------------------------------------------------------------------------
# 15. SOLUCIÓN DE PROBLEMAS
-------------------------------------------------------------------------------

  **"No hay sesión de Graph activa"**
        Configurar App-Only desde [C] Gestionar sesión de Graph, o conectar
        vía az login desde [C] -> [3].

  **"No se encuentra el certificado con Thumbprint ..."**
        El Thumbprint guardado no coincide con ningún certificado en
        Cert:\CurrentUser\My. Verificar:
            Get-ChildItem Cert:\CurrentUser\My | Select Thumbprint, Subject
        O volver a configurarlo desde [C] -> [2].

  **"El certificado no tiene clave privada"**
        Se importó solo el .cer público. Importar el .pfx con clave privada
        desde [C] -> [2] -> [C].

  **"No se pudo conectar vía az login"**
   Comprobar:
  - Que Azure CLI está instalado (az --version).
  - Que az login se ejecutó correctamente.
  - Que el módulo Microsoft.Graph.Authentication no está en la versión 2.35.1 (regresión conocida con -AccessToken).
  - Que el token se pasa como string plano (el código ya lo hace).

  **"az login usa automáticamente mi cuenta de Windows"**
        La opción [C] -> [3] ya desactiva WAM
        (az config set core.enable_broker_on_windows=false) y limpia la
        sesión (az account clear). Si aún así reutiliza la cuenta, ejecuta
        manualmente en otra consola:
            az config set core.enable_broker_on_windows=false
            az account clear
            az login --use-device-code

  **"Requiere licencia Entra ID P1 (AAD_PREMIUM)"**
        El tenant no tiene P1. Cambiar de nivel con [N] o usar un escenario
        sin secciones P1.

  **"Requiere licencia Entra ID P2 (AAD_PREMIUM_P2)"**
        El tenant no tiene P2. Cambiar de nivel con [N] o usar un escenario
        sin secciones P2.

  **"PimEligibleRole no aparece en [5]"**
        El nivel efectivo no es P2 (tenant sin P2 o configurado en Free/P1),
        o la carpeta p2/ está desactivada. El tipo aparece deshabilitado con
        el motivo.

  **"No hay vulnerabilidades del catálogo disponibles"**
        Todas las vulnerabilidades del catálogo tienen tipos que tu nivel
        efectivo no permite. Cambia de nivel con [N] o añade vulnerabilidades
        del tipo correcto en escenarios/vulnerab/.

  **"Manifiesto presente pero ilegible"**
        El fichero manifiesto_lab.json está corrupto. Borrarlo y empezar:
            Remove-Item .\manifiesto_lab.json -Force

  **"Capacidad no registrada (carpeta desactivada)"**
        La sección del escenario usa una capacidad cuya carpeta está
        renombrada a .disabled o cuyo archivo se borró. Reactivar la carpeta
        o quitar la sección del escenario.

  **"ObjectId distinto"**
        El objeto del manifiesto ya no coincide con el actual (borrado y
        recreado externamente). El cleanup no lo borra. Revisar manualmente.

  **"No se pudo aplicar la vulnerabilidad PimEligibleRole"**
        Requiere P2 y que cap_pim.ps1 esté registrada. Usar un tenant con P2
        o desactivar el tipo.

  **Encoding roto ("l?nea", acentos raros)**
        Algún .ps1 se guardó sin BOM. Guardarlo como UTF-8 con BOM.


-------------------------------------------------------------------------------
# 16. LIMITACIONES CONOCIDAS
-------------------------------------------------------------------------------

  - Free vs P1/P2: la detección es por SKU del tenant, no por usuario. Un tenant P1 puede tener usuarios sin P1 asignada; la capacidad se ofrece igualmente y fallará en creación si el usuario no cumple el requisito.

  - PIM requiere P2. Sin P2, PimEligibleRole no se ofrece (ni como capacidad de escenario ni como vulnerabilidad).

  - TAP requiere P1. Sin P1, la capacidad MetodosAuth no se ofrece.

  - Cleanup con soft-delete: Remove-MgUser, Remove-MgGroup, Remove-MgApplication y Remove-MgServicePrincipal hacen soft-delete. Los objetos se pueden restaurar durante 30 días desde el portal. Restaurar una aplicación NO restaura automáticamente su service principal; hay que   restaurarlos por separado.

  - No es un backup: el manifiesto registra lo creado y aplicado, no el estado previo del tenant. Si un objeto preexistente se modifica a mano durante el laboratorio, el cleanup no lo revierte.

  - Los objetos preexistentes no se tocan, pero tampoco se protegen. Si el operador los borra a mano, el laboratorio no puede recuperarlos.

  - Las políticas de Acceso Condicional se generan en estado disabled por seguridad. Habilitarlas es responsabilidad del operador.

  - Los roles de aplicación definidos no se revierten individualmente. El cleanup solo revierte las asignaciones. Para eliminar los roles, hay que borrar la aplicación completa.

  - La sintaxis de condiciones de Acceso Condicional no se valida en profundidad. El operador debe usar la estructura correcta de Graph.

  - Verificación de objectId en objetos: cubre Usuario, Grupo, Aplicacion, ServicePrincipal y AdministrativeUnit. El resto de tipos confía en el manifiesto (deuda conocida). En vulnerabilidades cubre los 4 tipos.

  - PimEligibleRole como vulnerabilidad: el rol elegible se cancela, pero si el rol se activó manualmente durante el laboratorio, la activación se cancela vía PreRevertir. Si se activó y ya expiró, no hay nada que cancelar.


-------------------------------------------------------------------------------
# 17. LICENCIA Y AVISO LEGAL
-------------------------------------------------------------------------------

Uso educativo y de laboratorio. Sin garantías.

El operador es responsable del uso que haga de los scripts en su tenant. No usar en entornos de producción sin revisar y adaptar el código.

Los scripts crean, modifican y borran objetos en Entra ID. Aunque el cleanup verifica objectId y respeta preexistentes, no hay garantía absoluta contra errores humanos o configuraciones inesperadas. Probar siempre en un tenant de prácticas.

===============================================================================