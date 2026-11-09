===============================================================================
                              CAPACIDADES
===============================================================================

Una CAPACIDAD es un plugin autocontenido que implementa una funcionalidad del
laboratorio: crear usuarios, grupos, aplicaciones, unidades administrativas,
roles PIM, etc. El núcleo del programa no sabe qué capacidades existen; las
descubre al arrancar y las usa a través de un contrato fijo.

Este documento explica el contrato, cómo añadir o quitar capacidades, y las
capacidades disponibles por nivel.

NOTA SOBRE VULNERABILIDADES:
La capacidad 'Vulnerabilidades' es especial: no consume una sección del
escenario (SeccionJson = $null). Se aplica sobre objetos existentes desde
un flujo dedicado en menu.ps1 [5]. Su contrato y su catálogo se documentan
en docs/vulnerabilidades.md. Aquí solo se describe su encaje en el sistema
de capacidades.


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
            cap_vulnerabilidades.ps1
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

Renombrar p2/ a p2.disabled/ desactiva P2 sin tocar código. El loader
ignora cualquier carpeta que no se llame exactamente free, p1 o p2.


-------------------------------------------------------------------------------
2. EL CONTRATO DE CAPACIDAD
-------------------------------------------------------------------------------

Cada cap_*.ps1 declara un hashtable $Capacidad y lo registra con
Register-LabCapacidad. El hashtable debe tener los campos obligatorios y
puede tener los opcionales.


2.1. CAMPOS OBLIGATORIOS
------------------------

    CAMPO            TIPO            PROPÓSITO
    ---------------  --------------  ------------------------------------------
    Nombre           string          Identificador único. Sin acentos,
                                     PascalCase. Se usa en el manifiesto.
    SeccionJson      string/$null    Clave del JSON del escenario que consume.
                                     $null si no consume sección (p. ej.
                                     Vulnerabilidades, que se aplica desde
                                     un flujo dedicado).
    DependeDe        array strings   Nombres de capacidades que deben existir
                                     antes. Puede ser @().
    PermisosApp      array strings   Permisos de aplicación de Graph.
    TestDisponible   scriptblock     param($Contexto) -> {Disponible, Motivo}
                                     Puede incluir campos extra como
                                     TiposDisponibles (Vulnerabilidades).
    ValidarDef       scriptblock     param($Def) -> array de errores.
                                     Array vacío = válido.
    Describir        scriptblock     param($Def) -> string. Texto resumen.
    Crear            scriptblock     param($Def, $Contexto) -> array creados.
    Revertir         scriptblock     param($Objeto, $Contexto) -> bool.
                                     Idempotente.
    PreguntarUI      scriptblock     param($Contexto) -> definición o $null.
                                     Solo para menú manual.


2.2. CAMPOS OPCIONALES
----------------------

    CAMPO            TIPO            PROPÓSITO
    ---------------  --------------  ------------------------------------------
    Descripcion      string          Nombre legible para el menú. Si no
                                     existe, se usa Nombre.
    Nivel            string          Fuerza el nivel (Free, P1, P2).
                                     Normalmente se hereda de la carpeta.
    Alias            array strings   Nombres alternativos de SeccionJson.
    ObtenerClaves    scriptblock     param($Def) -> array de claves.
                                     Usado para snapshot pre-lab por capacidad.
    PostCrear        scriptblock     param($Objetos, $Contexto). Tras crear.
    PreRevertir      scriptblock     param($Objetos, $Contexto). Antes de
                                     revertir (p. ej. desactivar una
                                     asignación PIM activa).


2.3. EL $Contexto
-----------------

El contexto es un hashtable que el núcleo pasa a TestDisponible, Crear,
Revertir y PreguntarUI. Contiene:

    CLAVE              TIPO            CONTENIDO
    -----------------  --------------  ----------------------------------------
    TenantId           string          Tenant actual.
    TenantDomain       string          Dominio por defecto.
    Nivel              string          Nivel configurado (Free, P1, P2).
    NivelEfectivo      string          min(configurado, real del tenant).
                                     Lo usa Vulnerabilidades para filtrar
                                     tipos disponibles.
    Manifiesto         object          Manifiesto en construcción.
    ObjetosCreados     hashtable       Por capacidad, objetos creados.
    Config             hashtable       Configuración actual.
    SnapshotPreLab     hashtable       Identificadores preexistentes.
    PasswordsPorUpn    hashtable       Contraseñas derivadas (usuarios).
    DerivarPassword    scriptblock     param($upn) -> string.
    Semilla            byte[]          Semilla de la sesión.
    Log                List[object]    Log compartido.
    VulnerabilidadesExcluidas array     Nombres a excluir (solo
                                     Vulnerabilidades).

REGLA: las capacidades no modifican $Contexto directamente. Si necesitan
compartir algo, usan $Contexto.ObjetosCreados[$suCapacidad].


2.4. FORMA DE LOS OBJETOS CREADOS
---------------------------------

Cada objeto que Crear devuelve debe tener, como mínimo:

    [pscustomobject]@{
        tipo          = 'Usuario'      # tipo de objeto Graph
        estadoDetalle = 'creado'       # 'creado', 'reutilizado' o 'preexistente'
        # ... datos específicos de la capacidad ...
    }

El núcleo añade id, capacidad, timestamp, tenantId y envuelve el resto en
datos. La capacidad solo se preocupa de tipo, estadoDetalle y sus datos.


-------------------------------------------------------------------------------
3. CÓMO SE REGISTRA UNA CAPACIDAD
-------------------------------------------------------------------------------

Al final de cada cap_*.ps1:

    Register-LabCapacidad -Capacidad $Capacidad

El loader (Initialize-LabCapacidades) recorre lib_caps/free|p1|p2/, ejecuta
cada cap_*.ps1 y llama a Register-LabCapacidad. Si un archivo está mal
formado, se rechaza con warning y no rompe el arranque.


VALIDACIONES DEL REGISTRO
-------------------------

    1. Campos obligatorios presentes.
    2. Scriptblocks son scriptblocks.
    3. Nombre no duplicado.
    4. SeccionJson no duplicada (si no es $null).
    5. Dependencias existen.
    6. Sin ciclos en DependeDe.
    7. Dependencias de nivel igual o inferior (una capacidad P1 no puede
       depender de P2).

Si algo falla, la capacidad no se registra y se avisa.

CAPACIDADES CON SECCIONJSON = $NULL:
No crean entrada en $esc.Secciones (ConvertTo-LabEscenarioNormalizado las
omite). No se procesan en Invoke-LabCreacion. Se aplican desde su flujo
dedicado (menu.ps1 [5] para Vulnerabilidades). Siguen registrándose en el
sistema de capacidades y aparecen en [K] Ver capacidades.


-------------------------------------------------------------------------------
4. CÓMO AÑADIR UNA CAPACIDAD NUEVA
-------------------------------------------------------------------------------

    1. Crear el archivo lib_caps/<nivel>/cap_<nombre>.ps1.
    2. Declarar $Capacidad con los campos obligatorios y los opcionales
       que apliquen.
    3. Implementar los scriptblocks según el contrato.
    4. Registrarla con Register-LabCapacidad -Capacidad $Capacidad.
    5. Añadir Descripcion en español para el menú.
    6. Añadir Alias con la versión española de la sección si aplica.
    7. Probar con menu.ps1 -> [K] Ver capacidades para confirmar que se
       registra.

No hay que tocar lib_caps.ps1, lib_creadores.ps1, menu.ps1, creauto.ps1,
creamanual.ps1 ni clean_up.ps1. La capacidad aparece automáticamente en el
flujo automático (si el escenario declara su sección) y en el menú manual.

EXCEPCIÓN: si la capacidad no consume sección del escenario
(SeccionJson = $null), hay que añadir un flujo dedicado en menu.ps1. Es el
caso de Vulnerabilidades ([5] y [6]). Ver docs/vulnerabilidades.md.


-------------------------------------------------------------------------------
5. CÓMO QUITAR UNA CAPACIDAD
-------------------------------------------------------------------------------

OPCIÓN 1: BORRAR EL ARCHIVO
    Se elimina del registro y el programa sigue funcionando. Los escenarios
    que declaren su sección fallarán la validación con un mensaje claro.

OPCIÓN 2: RENOMBRAR LA CARPETA DEL NIVEL
    p2/ -> p2.disabled/. El loader no la encuentra y todas las capacidades
    de ese nivel quedan desactivadas. Es la forma de hacer una distribución
    "solo hasta P1" o "solo Free".

OPCIÓN 3: RENOMBRAR EL ARCHIVO
    cap_pim.ps1 -> cap_pim.ps1.disabled. El loader no lo encuentra (solo
    carga cap_*.ps1) y esa capacidad concreta desaparece.

En los tres casos, el programa no requiere cambios. Los escenarios que usen
la sección eliminada fallan con "capacidad no registrada" o "carpeta
desactivada".

CASO ESPECIAL: VULNERABILIDADES
    - Si se borra cap_vulnerabilidades.ps1, el menú [5] avisa y no permite
      crear vulnerabilidades.
    - Si se renombra p2/ a p2.disabled/, PimEligibleRole no se ofrece
      (aparece deshabilitado con motivo en [5]).
    - Las vulnerabilidades pendientes en el manifiesto se marcan como
      no-revertidas al limpiar, con aviso.


-------------------------------------------------------------------------------
6. CAPACIDADES DISPONIBLES POR NIVEL
-------------------------------------------------------------------------------

FREE
----

    CAPACIDAD            SECCIÓN JSON         DESCRIPCIÓN
    -------------------  -------------------  --------------------------------
    Usuarios             usuarios             Usuarios de Entra ID.
    Grupos               grupos               Grupos de seguridad.
    Relaciones           relaciones           Membresías usuario -> grupo.
    Aplicaciones         aplicaciones         Aplicaciones y SPs.
    AppRoles             appRoles             Roles de app y asignaciones.
    CredencialesApp      credencialesApp      Client secrets de apps.
    PermisosApi          permisosApi          Permisos de API concedidos.
    Invitados            invitados            Usuarios B2B (guest).
    Vulnerabilidades     (ninguna)            Modificaciones maliciosas
                                              sobre objetos existentes.
                                              Ver docs/vulnerabilidades.md.

P1
--

    CAPACIDAD            SECCIÓN JSON         DESCRIPCIÓN
    -------------------  -------------------  --------------------------------
    AdministrativeUnits  administrativeUnits  Unidades administrativas.
    GruposDinamicos      gruposDinamicos      Grupos con membresía dinámica.
    GruposRoleAssignable gruposRoleAssignable Grupos con IsAssignableToRole.
    Licencias            licencias            Asignación de licencias M365.
    AccesoCondicional    accesoCondicional    Políticas de Acceso Condicional.
    MetodosAuth          metodosAuth          Temporary Access Pass (TAP).

P2
--

    CAPACIDAD            SECCIÓN JSON         DESCRIPCIÓN
    -------------------  -------------------  --------------------------------
    Pim                  pim                  Roles elegibles PIM.
    Vulnerabilidades     (ninguna)            Tipos P2 disponibles:
    (tipo PimEligibleRole)                     PimEligibleRole.


-------------------------------------------------------------------------------
7. LICENCIAS Y TestDisponible
-------------------------------------------------------------------------------

Cada capacidad decide en TestDisponible si puede operar en el tenant actual.
Las capacidades P1/P2 consultan Get-MgSubscribedSku y buscan:

    AAD_PREMIUM      con ProvisioningStatus = 'Success'  ->  P1.
    AAD_PREMIUM_P2   con ProvisioningStatus = 'Success'  ->  P2.

Si no encuentran el plan, devuelven Disponible = $false con un motivo claro.
El menú manual filtra esas capacidades automáticamente
(Get-LabCapacidades -SoloDisponibles). El flujo automático las omite con aviso.

IMPORTANTE: la comprobación está en la capacidad, no en el menú. Eso mantiene
la modularidad: añadir una capacidad nueva con requisito de licencia solo
requiere implementar su TestDisponible.

TESTDISPONIBLE CON TIPOS:
Algunas capacidades agrupan varios tipos con niveles distintos. Es el caso
de Vulnerabilidades, que en un solo archivo ofrece tipos Free y P2. En esos
casos, TestDisponible puede devolver un campo extra TiposDisponibles con los
tipos que el nivel efectivo permite. El menú y PreguntarUI lo usan para
mostrar solo lo disponible. Ver docs/vulnerabilidades.md sección 3.


-------------------------------------------------------------------------------
8. EJEMPLO MÍNIMO
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
                return [pscustomobject]@{ Disponible = $false; Motivo = 'Sin sesión' }
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
    - Añadir capacidad = añadir archivo.
      Quitar = borrar archivo o renombrar carpeta.
    - La comprobación de licencia vive en TestDisponible, no en el menú.
    - El núcleo no conoce tipos concretos.
    - Vulnerabilidades es especial: SeccionJson = $null, flujo dedicado.
      Ver docs/vulnerabilidades.md.

===============================================================================