===============================================================================
                LABORATORIO ENTRA ID - GESTOR DE ENTORNOS
===============================================================================

Conjunto de scripts PowerShell para crear, inspeccionar y limpiar entornos de
laboratorio en Microsoft Entra ID: usuarios, grupos, aplicaciones, service
principals, unidades administrativas, roles PIM y sus relaciones.

Todo se orquesta desde menu.ps1, que gestiona la sesion de Graph (App-Only
con certificado por defecto, o delegada via az login como opcion) y delega en
scripts hijos. Los objetos creados se registran en un manifiesto JSON para
poder revertirlos despues de forma controlada.

Arquitectura modular por capacidades: anadir o quitar una funcionalidad es
anadir o borrar un archivo. No hay que tocar el nucleo.

Requisitos: PowerShell 5.1+ | Microsoft.Graph | Entra ID (Free, P1 o P2)


-------------------------------------------------------------------------------
1. QUE ES Y QUE NO ES
-------------------------------------------------------------------------------

ES:

    - Un gestor de entornos de laboratorio en Entra ID.
    - Modular: cada funcionalidad es una capacidad autocontenida.
    - Multi-nivel: Free, P1 y P2, con deteccion automatica de licencia.
    - Reproducible: contrasenas derivadas de una semilla local por escenario.
    - Seguro por defecto: no adopta objetos preexistentes, no guarda secretos,
      verifica objectId antes de borrar.

NO ES:

    - Una herramienta de produccion.
    - Un reemplazo de Terraform, Bicep o la CLI de Azure.
    - Un backup de Entra ID. El manifiesto registra lo creado, no el estado
      previo del tenant.
    - Un sistema de gestion de identidades. Es un laboratorio para practicar.


-------------------------------------------------------------------------------
2. CARACTERISTICAS PRINCIPALES
-------------------------------------------------------------------------------

    - Arquitectura modular por capacidades.
      Anadir o quitar una capacidad = anadir o borrar un cap_*.ps1 en la
      carpeta del nivel. Nada mas.

    - Niveles Free / P1 / P2.
      Cada capacidad comprueba en runtime si el tenant soporta su licencia
      (Get-MgSubscribedSku). El menu manual filtra las no disponibles.

    - Creacion automatica con flujo nivel -> tipo -> crear.
      Elegir nivel, elegir plantilla o escenario, revisar resumen, crear.
      Opcion de parar y guardar plantilla en cualquier momento.

    - Creacion manual con menu generado desde capacidades.
      Las opciones del menu salen de las capacidades registradas. Anadir una
      capacidad nueva la hace aparecer automaticamente.

    - Contrasenas derivadas de semilla local.
      Los JSON no contienen contrasenas. Se derivan con
      HMAC-SHA256(semilla, UPN) y se muestran una sola vez.

    - Snapshot pre-lab.
      Antes de crear, se construye un snapshot de lo que ya existe en el
      tenant. Los objetos preexistentes no se adoptan ni se modifican.

    - Cleanup con despacho por capacidad.
      El manifiesto guarda la capacidad que creo cada objeto. El cleanup
      despacha a su Revertir sin un switch gigante.

    - Verificacion de objectId antes de borrar.
      Si el objeto del manifiesto no coincide con el actual (borrado y
      recreado externamente), no se borra.

    - App-Only con certificado.
      Sin secretos en el repo. El certificado vive en Cert:\CurrentUser\My.
      Se puede importar un .pfx desde el propio menu.

    - az login como alternativa.
      Conexion delegada opcional desde [C] -> [3], forzando el flujo de
      navegador (desactiva WAM) para elegir el usuario.


-------------------------------------------------------------------------------
3. REQUISITOS
-------------------------------------------------------------------------------

    - PowerShell 5.1 o superior.
    - Modulo Microsoft.Graph (el menu lo instala si no esta presente).
    - Tenant de Entra ID en plan Free, P1 o P2.
    - Registro de App en Entra ID con:
        * Client ID y Tenant ID anotados.
        * Certificado (.cer) subido en Certificates & secrets.
        * Permisos de aplicacion concedidos con consentimiento de
          administrador:
              User.ReadWrite.All
              Group.ReadWrite.All
              Application.ReadWrite.All
              AppRoleAssignment.ReadWrite.All
              Directory.Read.All
        * Segun las capacidades que se usen, tambien:
              AdministrativeUnit.ReadWrite.All
              RoleManagement.ReadWrite.Directory
              Policy.ReadWrite.ConditionalAccess
              LicenseAssignment.ReadWrite.All
              UserAuthenticationMethod.ReadWrite.All
    - Certificado con clave privada en Cert:\CurrentUser\My, o un .pfx para
      importar desde el menu ([C]).


-------------------------------------------------------------------------------
4. INSTALACION RAPIDA
-------------------------------------------------------------------------------

    1. Clonar el repositorio.

    2. Ejecutar el menu:

           .\menu.ps1

    3. Configurar App-Only desde [C] Gestionar sesion de Graph:
           - Opcion [2] Configurar certificado App-Only.
           - Seleccionar un certificado del store o importar un .pfx.
           - Introducir ClientId y TenantId.
           - Los tres datos se guardan en menu_config.json.

    4. (Opcional) Generar escenarios de ejemplo:

           .\generar_biblioteca.ps1

       Crea escenarios, vulnerabilidades, plantillas y semillas locales en
       escenarios/. Detecta el nivel del tenant si hay sesion.


-------------------------------------------------------------------------------
5. CONEXION A GRAPH
-------------------------------------------------------------------------------

El programa tiene DOS modos de conexion:

    MODO                        CUANDO SE USA               PERMISOS
    --------------------------  --------------------------  --------------------
    App-Only con certificado    Al arrancar, automatico     Los de la App
    (por defecto)                                           registrada

    Delegado via az login       Manualmente, desde          Los del usuario
    (opcional)                  [C] -> [3]                  que inicia sesion

La conexion inicial siempre es App-Only. Si falla (certificado no encontrado,
datos incompletos, permisos), el menu arranca sin sesion y avisa. En ese caso,
puedes:

    - Reconfigurar el certificado desde [C] -> [2].
    - Conectar via az login desde [C] -> [3].

SOBRE az login Y WAM:
En Windows, Azure CLI usa el Web Account Manager (WAM) por defecto desde la
version 2.61.0, que tiende a reutilizar la cuenta del sistema operativo. La
opcion [3] del menu DESACTIVA WAM
(az config set core.enable_broker_on_windows=false) y limpia la sesion
(az account clear) antes de lanzar az login, para que te pida elegir el
usuario.

SI az login FALLA DESPUES DE AUTENTICARTE:
    - Comprueba que el modulo Microsoft.Graph.Authentication no esta en una
      version con regresion conocida (2.35.1). Si lo esta, actualiza o baja
      a 2.35.0.
    - Comprueba que el token se pasa como string plano, no como SecureString
      (el codigo ya lo hace asi).


-------------------------------------------------------------------------------
6. ESTRUCTURA DEL REPOSITORIO
-------------------------------------------------------------------------------

    <raiz>/
    +-- menu.ps1                  Punto de entrada.
    +-- creauto.ps1               Creacion automatica (nivel -> tipo -> crear).
    +-- creamanual.ps1            Creacion manual (menu generado).
    +-- clean_up.ps1              Limpieza por despacho de capacidad.
    +-- generar_biblioteca.ps1    Generador de escenarios y plantillas.
    |
    +-- lib_ui.ps1                Helpers de consola.
    +-- lib_graph.ps1             Sesion App-Only y az login.
    +-- lib_config.ps1            Configuracion persistente.
    +-- lib_manifiesto.ps1        Manifiesto v2 y migracion desde v1.
    +-- lib_escenarios.ps1        Normalizacion de escenarios.
    +-- lib_niveles.ps1           Niveles Free / P1 / P2.
    +-- lib_caps.ps1              Loader y registro de capacidades.
    +-- lib_creadores.ps1         Orquestacion de creacion y reversion.
    |
    +-- lib_caps/
    |   +-- free/                 Capacidades disponibles en Free.
    |   +-- p1/                   Capacidades que requieren P1.
    |   +-- p2/                   Capacidades que requieren P2.
    |
    +-- escenarios/
    |   +-- escenario/            Escenarios propios y de ejemplo.
    |   +-- vulnerab/             Vulnerabilidades referenciables.
    |   +-- plantillas/           Esqueletos para el flujo nivel -> tipo.
    |   +-- .secrets/             Semillas locales (NO se sube a Git).
    |
    +-- docs/
    |   +-- capacidades.txt       Contrato de capacidad y guia de extension.
    |   +-- escenarios.txt        Formato del JSON de escenario.
    |   +-- manifiesto.txt        Estructura del manifiesto y cleanup.
    |
    +-- .gitignore
    +-- README.txt

Para el detalle de cada parte, ver docs/.


-------------------------------------------------------------------------------
7. USO
-------------------------------------------------------------------------------

Al arrancar menu.ps1:

    - Si menu_config.json tiene datos App-Only completos, conecta
      automaticamente.
    - Si no, avisa y arranca sin sesion. Se configura desde [C].

OPCIONES DEL MENU:

    CREACION
    [1]  Creacion automatica (nivel -> tipo -> crear)
    [2]  Creacion manual (menu generado desde capacidades)

    LIMPIEZA
    [3]  Limpiar entorno (despacho por capacidad)

    MANIFIESTO
    [4]  Ver manifiesto

    SESION Y CONFIGURACION
    [C]  Gestionar sesion de Graph (App-Only / az login)
    [N]  Cambiar nivel de licencia
    [K]  Ver capacidades disponibles
    [V]  Alternar Verbose
    [R]  Resetear configuracion
    [0]  Salir

FICHEROS GENERADOS EN RUNTIME:

    menu_config.json                          Configuracion local.
    manifiesto_lab.json                       Manifiesto v2 pendiente.
    manifiesto_lab_procesado_<timestamp>.json Manifiesto ya procesado.
    log_creauto_*.csv                         Log de creacion automatica.
    log_personalizada_*.csv                   Log de creacion manual.
    log_cleanup_*.csv                         Log de limpieza.


-------------------------------------------------------------------------------
8. FLUJO TIPICO
-------------------------------------------------------------------------------

    1. Crear el certificado y registrar la App en Entra ID (una sola vez).
    2. Ejecutar .\menu.ps1.
    3. Entrar en [C] -> [2] y configurar el certificado App-Only.
    4. (Opcional) Ejecutar .\generar_biblioteca.ps1 para crear escenarios de
       ejemplo y plantillas.
    5. Opcion [1] o [2] para crear el escenario. Revisar el resumen y
       confirmar con SI.
    6. Anotar las contrasenas mostradas (solo se muestran una vez).
    7. Probar el escenario (iniciar sesion con las credenciales anotadas).
    8. Opcion [3] para limpiar todo lo creado.
    9. Opcion [0] para salir.


-------------------------------------------------------------------------------
9. MODELO DE SEMILLA Y CONTRASENAS
-------------------------------------------------------------------------------

Los escenarios NO contienen contrasenas. Cada escenario tiene una semilla local
en escenarios/.secrets/<escenario>.seed (32 bytes aleatorios en Base64, fuera
de Git). De ella se deriva la contrasena de cada usuario:

    password = HMAC-SHA256(semilla, upn) -> Base64 -> 16 chars + "!Aa1"

Propiedades:

    - Determinista: misma semilla + mismo UPN -> misma contrasena.
    - Unica por usuario: cada UPN produce una contrasena distinta.
    - Reproducible: conservando la semilla, se regeneran las contrasenas.
    - 20 caracteres: cumple la politica de Entra ID (mayusculas, minusculas,
      numeros, simbolos).
    - Fuera de Git: escenarios/.secrets/ esta en .gitignore.

En creauto.ps1 las contrasenas se generan desde la semilla y se muestran UNA
SOLA VEZ al final. En creamanual.ps1 el operador puede introducirlas
manualmente o generarlas desde la semilla de la sesion.

En ningun caso la contrasena se guarda en el manifiesto ni en el JSON.

Si se pierde la semilla, no se pueden reproducir las contrasenas ya mostradas.
Si se filtra, se pueden regenerar todas las contrasenas de ese escenario.


-------------------------------------------------------------------------------
10. SEGURIDAD Y .GITIGNORE
-------------------------------------------------------------------------------

NO SE SUBE A GIT:

    escenarios/.secrets/          Semillas locales.
    *.seed                        Semillas locales (cualquier ubicacion).
    manifiesto_lab*.json          Manifiesto (UPNs y nombres del tenant).
    *_procesado_*.json            Manifiesto ya procesado.
    menu_config.json              ClientId, TenantId, Thumbprint.
    log_*.csv                     Logs con UPNs y nombres.
    biblioteca.json               Artefacto de generacion.

SI SE SUBE A GIT:

    Scripts (.ps1).
    lib_caps/free|p1|p2/          Capacidades.
    docs/                         Documentacion.
    escenarios/escenario/         Escenarios de ejemplo (sin secretos).
    escenarios/vulnerab/          Vulnerabilidades de ejemplo.
    escenarios/plantillas/        Plantillas.
    .gitignore
    README.txt

ADVERTENCIA:

    El manifiesto y los logs contienen UPNs y nombres de objetos del tenant
    real. Tratalos como informacion sensible. Borralos periodicamente.


-------------------------------------------------------------------------------
11. COMO ANADIR UNA CAPACIDAD
-------------------------------------------------------------------------------

    1. Crear lib_caps/<nivel>/cap_<nombre>.ps1.
    2. Declarar $Capacidad con los campos del contrato.
    3. Implementar los scriptblocks (TestDisponible, ValidarDef, Describir,
       Crear, Revertir, PreguntarUI).
    4. Registrar con Register-LabCapacidad -Capacidad $Capacidad.
    5. Anadir Descripcion en espanol para el menu.
    6. Probar con menu.ps1 -> [K] Ver capacidades.

No hay que tocar el nucleo. La capacidad aparece automaticamente en el flujo
automatico (si el escenario declara su seccion) y en el menu manual.

Detalle completo del contrato: docs/capacidades.txt.


-------------------------------------------------------------------------------
12. COMO QUITAR UNA CAPACIDAD O UN NIVEL
-------------------------------------------------------------------------------

    OPCION 1: Borrar el cap_*.ps1.
        La capacidad desaparece. Los escenarios que usen su seccion fallan con
        un mensaje claro.

    OPCION 2: Renombrar la carpeta del nivel.
        p2/ -> p2.disabled/
        Todas las capacidades de ese nivel quedan desactivadas. Es la forma de
        hacer una distribucion "solo hasta P1" o "solo Free".

    OPCION 3: Renombrar el archivo.
        cap_pim.ps1 -> cap_pim.ps1.disabled
        Solo esa capacidad desaparece.

En los tres casos, el programa sigue funcionando. No hay que tocar el nucleo.


-------------------------------------------------------------------------------
13. DOCUMENTACION
-------------------------------------------------------------------------------

    docs/capacidades.txt
        Contrato de capacidad, como anadir o quitar capacidades, capacidades
        disponibles por nivel, licencias y TestDisponible.

    docs/escenarios.txt
        Formato del JSON de escenario, secciones por capacidad, alias,
        plantillas, normalizacion y modelo de semilla.

    docs/manifiesto.txt
        Estructura v2 del manifiesto, estados, migracion desde v1, y como
        funciona el cleanup con verificacion de objectId.


-------------------------------------------------------------------------------
14. SOLUCION DE PROBLEMAS
-------------------------------------------------------------------------------

    "No hay sesion de Graph activa"
        Configurar App-Only desde [C] Gestionar sesion de Graph, o conectar
        via az login desde [C] -> [3].

    "No se encuentra el certificado con Thumbprint ..."
        El Thumbprint guardado no coincide con ningun certificado en
        Cert:\CurrentUser\My. Verificar:
            Get-ChildItem Cert:\CurrentUser\My | Select Thumbprint, Subject
        O volver a configurarlo desde [C] -> [2].

    "El certificado no tiene clave privada"
        Se importo solo el .cer publico. Importar el .pfx con clave privada
        desde [C] -> [2] -> [C].

    "No se pudo conectar via az login"
        Comprobar:
            - Que Azure CLI esta instalado (az --version).
            - Que az login se ejecuto correctamente.
            - Que el modulo Microsoft.Graph.Authentication no esta en la
              version 2.35.1 (regresion conocida con -AccessToken).
            - Que el token se pasa como string plano (el codigo ya lo hace).

    "az login usa automaticamente mi cuenta de Windows"
        La opcion [C] -> [3] ya desactiva WAM
        (az config set core.enable_broker_on_windows=false) y limpia la
        sesion (az account clear). Si aun asi reutiliza la cuenta, ejecuta
        manualmente en otra consola:
            az config set core.enable_broker_on_windows=false
            az account clear
            az login --use-device-code

    "Requiere licencia Entra ID P1 (AAD_PREMIUM)"
        El tenant no tiene P1. Cambiar de nivel con [N] o usar un escenario
        sin secciones P1.

    "Requiere licencia Entra ID P2 (AAD_PREMIUM_P2)"
        El tenant no tiene P2. Cambiar de nivel con [N] o usar un escenario
        sin secciones P2.

    "Manifiesto presente pero ilegible"
        El fichero manifiesto_lab.json esta corrupto. Borrarlo y empezar:
            Remove-Item .\manifiesto_lab.json -Force

    "Capacidad no registrada (carpeta desactivada)"
        La seccion del escenario usa una capacidad cuya carpeta esta
        renombrada a .disabled o cuyo archivo se borro. Reactivar la carpeta
        o quitar la seccion del escenario.

    "ObjectId distinto"
        El objeto del manifiesto ya no coincide con el actual (borrado y
        recreado externamente). El cleanup no lo borra. Revisar manualmente.

    "No se pudo aplicar la vulnerabilidad PimEligibleRole"
        Requiere P2. Usar un tenant con P2 o un escenario sin esa
        vulnerabilidad.

    Encoding roto ("l?nea", acentos raros)
        Algun .ps1 se guardo sin BOM. Guardarlo como UTF-8 con BOM.


-------------------------------------------------------------------------------
15. LIMITACIONES CONOCIDAS
-------------------------------------------------------------------------------

    - Free vs P1/P2: la deteccion es por SKU del tenant, no por usuario. Un
      tenant P1 puede tener usuarios sin P1 asignada; la capacidad se ofrece
      igualmente y fallara en creacion si el usuario no cumple el requisito.

    - PIM requiere P2. Sin P2, la capacidad Pim no se ofrece.

    - TAP requiere P1. Sin P1, la capacidad MetodosAuth no se ofrece.

    - Cleanup con soft-delete: Remove-MgUser, Remove-MgGroup,
      Remove-MgApplication y Remove-MgServicePrincipal hacen soft-delete. Los
      objetos se pueden restaurar durante 30 dias desde el portal. Restaurar
      una aplicacion NO restaura automaticamente su service principal; hay que
      restaurarlos por separado.

    - No es un backup: el manifiesto registra lo creado, no el estado previo
      del tenant. Si un objeto preexistente se modifica a mano durante el
      laboratorio, el cleanup no lo revierte.

    - Los objetos preexistentes no se tocan, pero tampoco se protegen. Si el
      operador los borra a mano, el laboratorio no puede recuperarlos.

    - Las politicas de Acceso Condicional se generan en estado disabled por
      seguridad. Habilitarlas es responsabilidad del operador.

    - Los roles de aplicacion definidos no se revierten individualmente. El
      cleanup solo revierte las asignaciones. Para eliminar los roles, hay que
      borrar la aplicacion completa.

    - La sintaxis de condiciones de Acceso Condicional no se valida en
      profundidad. El operador debe usar la estructura correcta de Graph.


-------------------------------------------------------------------------------
16. LICENCIA Y AVISO LEGAL
-------------------------------------------------------------------------------

Uso educativo y de laboratorio. Sin garantias.

El operador es responsable del uso que haga de los scripts en su tenant. No
usar en entornos de produccion sin revisar y adaptar el codigo.

Los scripts crean y borran objetos en Entra ID. Aunque el cleanup verifica
objectId y respeta preexistentes, no hay garantia absoluta contra errores
humanos o configuraciones inesperadas. Probar siempre en un tenant de
practicas.

===============================================================================