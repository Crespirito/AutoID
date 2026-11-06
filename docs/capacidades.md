===============================================================================
                              CAPACIDADES
===============================================================================

Una CAPACIDAD es un plugin autocontenido que implementa una funcionalidad del
laboratorio: crear usuarios, grupos, aplicaciones, unidades administrativas,
roles PIM, etc. El nucleo del programa no sabe que capacidades existen; las
descubre al arrancar y las usa a traves de un contrato fijo.

Este documento explica el contrato, como anadir o quitar capacidades, y las
capacidades disponibles por nivel.


-------------------------------------------------------------------------------
1. ESTRUCTURA DE UNA CAPACIDAD
-------------------------------------------------------------------------------

Cada capacidad vive en un archivo cap_*.ps1 dentro de lib_caps/<nivel>/:

    lib_caps/
        free/
            cap_usuarios.ps1
            cap_grupos.ps1
            cap_aplicaciones.ps1
            ...
        p1/
            cap_administrative_units.ps1
            cap_grupos_dinamicos.ps1
            ...
        p2/
            cap_pim.ps1
            cap_metodos_auth.ps1

LA CARPETA DETERMINA EL NIVEL de la capacidad:

    free/   ->  disponible en Entra ID Free.
    p1/     ->  requiere Entra ID P1 (o P2).
    p2/     ->  requiere Entra ID P2.

Renombrar p2/ a p2.disabled/ desactiva P2 sin tocar codigo. El loader ignora
cualquier carpeta que no se llame exactamente free, p1 o p2.


-------------------------------------------------------------------------------
2. EL CONTRATO DE CAPACIDAD
-------------------------------------------------------------------------------

Cada cap_*.ps1 declara un hashtable $Capacidad y lo registra con
Register-LabCapacidad. El hashtable debe tener los campos obligatorios y puede
tener los opcionales.


2.1. CAMPOS OBLIGATORIOS
------------------------

    CAMPO            TIPO            PROPOSITO
    ---------------  --------------  ------------------------------------------
    Nombre           string          Identificador unico. Sin acentos,
                                     PascalCase. Se usa en el manifiesto.
    SeccionJson      string/$null    Clave del JSON del escenario que consume.
                                     $null si solo se usa en manual.
    DependeDe        array strings   Nombres de capacidades que deben existir
                                     antes. Puede ser @().
    PermisosApp      array strings   Permisos de aplicacion de Graph.
    TestDisponible   scriptblock     param($Contexto) -> {Disponible, Motivo}
    ValidarDef       scriptblock     param($Def) -> array de errores.
                                     Array vacio = valido.
    Describir        scriptblock     param($Def) -> string. Texto resumen.
    Crear            scriptblock     param($Def, $Contexto) -> array creados.
    Revertir         scriptblock     param($Objeto, $Contexto) -> bool.
                                     Idempotente.
    PreguntarUI      scriptblock     param($Contexto) -> definicion o $null.
                                     Solo para menu manual.


2.2. CAMPOS OPCIONALES
----------------------

    CAMPO            TIPO            PROPOSITO
    ---------------  --------------  ------------------------------------------
    Descripcion      string          Nombre legible para el menu. Si no
                                     existe, se usa Nombre.
    Nivel            string          Fuerza el nivel (Free, P1, P2).
                                     Normalmente se hereda de la carpeta.
    Alias            array strings   Nombres alternativos de SeccionJson.
    ObtenerClaves    scriptblock     param($Def) -> array de claves.
    PostCrear        scriptblock     param($Objetos, $Contexto). Tras crear.
    PreRevertir      scriptblock     param($Objetos, $Contexto). Antes de
                                     revertir.


2.3. EL $Contexto
-----------------

El contexto es un hashtable que el nucleo pasa a TestDisponible, Crear,
Revertir y PreguntarUI. Contiene:

    CLAVE              TIPO            CONTENIDO
    -----------------  --------------  ----------------------------------------
    TenantId           string          Tenant actual.
    TenantDomain       string          Dominio por defecto.
    Nivel              string          Nivel elegido (Free, P1, P2).
    Manifiesto         object          Manifiesto en construccion.
    ObjetosCreados     hashtable       Por capacidad, objetos creados.
    Config             hashtable       Configuracion actual.
    SnapshotPreLab     hashtable       Identificadores preexistentes.
    PasswordsPorUpn    hashtable       Contrasenas derivadas (usuarios).
    DerivarPassword    scriptblock     param($upn) -> string.
    Semilla            byte[]          Semilla de la sesion.
    Log                List[object]    Log compartido.

REGLA: las capacidades no modifican $Contexto directamente. Si necesitan
compartir algo, usan $Contexto.ObjetosCreados[$suCapacidad].


2.4. FORMA DE LOS OBJETOS CREADOS
---------------------------------

Cada objeto que Crear devuelve debe tener, como minimo:

    [pscustomobject]@{
        tipo          = 'Usuario'      # tipo de objeto Graph
        estadoDetalle = 'creado'       # 'creado', 'reutilizado' o 'preexistente'
        # ... datos especificos de la capacidad ...
    }

El nucleo anade id, capacidad, timestamp, tenantId y envuelve el resto en
datos. La capacidad solo se preocupa de tipo, estadoDetalle y sus datos.


-------------------------------------------------------------------------------
3. COMO SE REGISTRA UNA CAPACIDAD
-------------------------------------------------------------------------------

Al final de cada cap_*.ps1:

    Register-LabCapacidad -Capacidad $Capacidad

El loader (Initialize-LabCapacidades) recorre lib_caps/free|p1|p2/, ejecuta
cada cap_*.ps1 y llama a Register-LabCapacidad. Si un archivo esta mal
formado, se rechaza con warning y no rompe el arranque.


VALIDACIONES DEL REGISTRO
-------------------------

    1. Campos obligatorios presentes.
    2. Scriptblocks son scriptblocks.
    3. Nombre no duplicado.
    4. SeccionJson no duplicada.
    5. Dependencias existen.
    6. Sin ciclos en DependeDe.
    7. Dependencias de nivel igual o inferior (una capacidad P1 no puede
       depender de P2).

Si algo falla, la capacidad no se registra y se avisa.


-------------------------------------------------------------------------------
4. COMO ANADIR UNA CAPACIDAD NUEVA
-------------------------------------------------------------------------------

    1. Crear el archivo lib_caps/<nivel>/cap_<nombre>.ps1.
    2. Declarar $Capacidad con los campos obligatorios y los opcionales
       que apliquen.
    3. Implementar los scriptblocks segun el contrato.
    4. Registrarla con Register-LabCapacidad -Capacidad $Capacidad.
    5. Anadir Descripcion en espanol para el menu.
    6. Anadir Alias con la version espanola de la seccion si aplica.
    7. Probar con menu.ps1 -> [K] Ver capacidades para confirmar que se
       registra.

No hay que tocar lib_caps.ps1, lib_creadores.ps1, menu.ps1, creauto.ps1,
creamanual.ps1 ni clean_up.ps1. La capacidad aparece automaticamente en el
flujo automatico (si el escenario declara su seccion) y en el menu manual.


-------------------------------------------------------------------------------
5. COMO QUITAR UNA CAPACIDAD
-------------------------------------------------------------------------------

OPCION 1: BORRAR EL ARCHIVO
    Se elimina del registro y el programa sigue funcionando. Los escenarios
    que declaren su seccion fallaran la validacion con un mensaje claro.

OPCION 2: RENOMBRAR LA CARPETA DEL NIVEL
    p2/ -> p2.disabled/. El loader no la encuentra y todas las capacidades
    de ese nivel quedan desactivadas. Es la forma de hacer una distribucion
    "solo hasta P1" o "solo Free".

OPCION 3: RENOMBRAR EL ARCHIVO
    cap_pim.ps1 -> cap_pim.ps1.disabled. El loader no lo encuentra (solo
    carga cap_*.ps1) y esa capacidad concreta desaparece.

En los tres casos, el programa no requiere cambios. Los escenarios que usen
la seccion eliminada fallan con "capacidad no registrada" o "carpeta
desactivada".


-------------------------------------------------------------------------------
6. CAPACIDADES DISPONIBLES POR NIVEL
-------------------------------------------------------------------------------

FREE
----

    CAPACIDAD            SECCION JSON         DESCRIPCION
    -------------------  -------------------  --------------------------------
    Usuarios             usuarios             Usuarios de Entra ID.
    Grupos               grupos               Grupos de seguridad.
    Relaciones           relaciones           Membresias usuario -> grupo.
    Aplicaciones         aplicaciones         Aplicaciones y SPs.
    AppRoles             appRoles             Roles de app y asignaciones.
    CredencialesApp      credencialesApp      Client secrets de apps.
    PermisosApi          permisosApi          Permisos de API concedidos.
    Invitados            invitados            Usuarios B2B (guest).
    Vulnerabilidades     vulnerabilidades     Vulnerabilidades aplicadas.

P1
--

    CAPACIDAD            SECCION JSON         DESCRIPCION
    -------------------  -------------------  --------------------------------
    AdministrativeUnits  administrativeUnits  Unidades administrativas.
    GruposDinamicos      gruposDinamicos      Grupos con membresia dinamica.
    GruposRoleAssignable gruposRoleAssignable Grupos con IsAssignableToRole.
    Licencias            licencias            Asignacion de licencias M365.
    AccesoCondicional    accesoCondicional    Politicas de Acceso Condicional.
    MetodosAuth          metodosAuth          Temporary Access Pass (TAP).

P2
--

    CAPACIDAD            SECCION JSON         DESCRIPCION
    -------------------  -------------------  --------------------------------
    Pim                  pim                  Roles elegibles PIM.


-------------------------------------------------------------------------------
7. LICENCIAS Y TestDisponible
-------------------------------------------------------------------------------

Cada capacidad decide en TestDisponible si puede operar en el tenant actual.
Las capacidades P1/P2 consultan Get-MgSubscribedSku y buscan:

    AAD_PREMIUM      con ProvisioningStatus = 'Success'  ->  P1.
    AAD_PREMIUM_P2   con ProvisioningStatus = 'Success'  ->  P2.

Si no encuentran el plan, devuelven Disponible = $false con un motivo claro.
El menu manual filtra esas capacidades automaticamente
(Get-LabCapacidades -SoloDisponibles). El flujo automatico las omite con aviso.

IMPORTANTE: la comprobacion esta en la capacidad, no en el menu. Eso mantiene
la modularidad: anadir una capacidad nueva con requisito de licencia solo
requiere implementar su TestDisponible.


-------------------------------------------------------------------------------
8. EJEMPLO MINIMO
-------------------------------------------------------------------------------

    $Capacidad = @{
        Nombre       = 'Ejemplo'
        Descripcion  = 'Capacidad de ejemplo'
        SeccionJson  = 'ejemplo'
        Alias        = @('ejemplos')
        Nivel        = 'Free'
        DependeDe    = @()
        PermisosApp  = @('Directory.Read.All')

        TestDisponible = {
            param($Contexto)
            if (-not (Test-LabGraphSession)) {
                return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesion' }
            }
            return [pscustomobject]@{ Disponible = $true; Motivo = $null }
        }

        ValidarDef = {
            param($Def)
            $errores = @()
            foreach ($e in @($Def)) {
                if ([string]::IsNullOrWhiteSpace($e.nombre)) {
                    $errores += "Elemento sin 'nombre'."
                }
            }
            return $errores
        }

        Describir = {
            param($Def)
            return "Ejemplos: $(@($Def).Count)"
        }

        Crear = {
            param($Def, $Contexto)
            $creados = @()
            foreach ($e in @($Def)) {
                $creados += [pscustomobject]@{
                    tipo          = 'Ejemplo'
                    nombre        = $e.nombre
                    estadoDetalle = 'creado'
                }
            }
            return $creados
        }

        Revertir = {
            param($Objeto, $Contexto)
            # Implementar borrado idempotente
            return $true
        }

        PreguntarUI = {
            param($Contexto)
            $nombre = Read-Host '  Nombre'
            if ([string]::IsNullOrWhiteSpace($nombre)) { return $null }
            return [pscustomobject]@{ nombre = $nombre }
        }
    }

    Register-LabCapacidad -Capacidad $Capacidad


-------------------------------------------------------------------------------
9. RESUMEN
-------------------------------------------------------------------------------

    - Una capacidad = un archivo cap_*.ps1 en lib_caps/<nivel>/.
    - La carpeta determina el nivel.
    - El contrato tiene 10 campos obligatorios y 6 opcionales.
    - Anadir capacidad = anadir archivo.
      Quitar = borrar archivo o renombrar carpeta.
    - La comprobacion de licencia vive en TestDisponible, no en el menu.
    - El nucleo no conoce tipos concretos.

===============================================================================