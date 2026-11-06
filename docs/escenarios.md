===============================================================================
                               ESCENARIOS
===============================================================================

Un ESCENARIO es un fichero JSON que declara los objetos que se van a crear en
Entra ID: usuarios, grupos, aplicaciones, unidades administrativas, roles PIM,
etc. El programa lo lee, lo normaliza y lo pasa a las capacidades para que cada
una cree su parte.

Este documento explica el formato del JSON, las secciones por capacidad, los
alias aceptados, las plantillas y el modelo de semilla y contrasenas.


-------------------------------------------------------------------------------
1. ESTRUCTURA BASICA DEL JSON
-------------------------------------------------------------------------------

Un escenario es un objeto JSON con metadatos y una o varias secciones:

    {
      "nombre": "escenarioej1",
      "descripcion": "Escenario de ejemplo 1.",
      "version": "1.0",
      "usuarios": [ ... ],
      "grupos": [ ... ],
      "aplicaciones": [ ... ],
      "relaciones": [ ... ]
    }

CAMPOS DE METADATOS (opcionales, pero recomendados):

    nombre
        Nombre del escenario. Si falta, se usa el nombre del fichero.

    descripcion
        Texto libre. Se muestra en el resumen antes de crear.

    version
        Version del formato. Por defecto "1.0".

Cada seccion es un array de objetos. Si el JSON trae un objeto suelto en lugar
de un array, el normalizador lo envuelve en @(...). Si trae null, lo convierte
en @().


-------------------------------------------------------------------------------
2. SECCIONES POR CAPACIDAD
-------------------------------------------------------------------------------

Cada seccion corresponde a una capacidad. El nombre de la seccion es el
SeccionJson de la capacidad. Los alias permiten usar nombres alternativos.

2.1. USUARIOS  (seccion: usuarios, alias: Usuarios)

    {
      "displayName": "Lucia Garcia",
      "upn": "lucia.g@{tenant}",
      "mailNickname": "lucia.g",
      "department": "Ventas",
      "jobTitle": "Comercial"
    }

    Campos obligatorios:
        displayName, upn, mailNickname

    Campos opcionales:
        department, jobTitle

    El marcador {tenant} se sustituye por el dominio del tenant en tiempo de
    creacion. La contrasena NO va en el JSON: se deriva de la semilla.


2.2. GRUPOS  (seccion: grupos, alias: Grupos)

    {
      "displayName": "Departamento de Ventas",
      "description": "Usuarios del departamento de Ventas",
      "mailNickname": "departamento-ventas"
    }

    Campos obligatorios:
        displayName

    Campos opcionales:
        description, mailNickname


2.3. RELACIONES  (seccion: relaciones, alias: Relaciones)

    {
      "tipo": "membresia",
      "usuario": "lucia.g@{tenant}",
      "grupo": "Departamento de Ventas"
    }

    Tipos soportados:
        membresia   ->  usuario a grupo

    Campos obligatorios:
        tipo, usuario, grupo


2.4. APLICACIONES  (seccion: aplicaciones, alias: Aplicaciones, apps)

    {
      "displayName": "Panel de Analisis Comercial",
      "description": "Aplicacion interna",
      "signInAudience": "AzureADMyOrg",
      "redirectUris": [ "https://panel.empresa.local/callback" ]
    }

    Campos obligatorios:
        displayName

    Campos opcionales:
        description, signInAudience, redirectUris

    Valores de signInAudience:
        AzureADMyOrg
        AzureADMultipleOrgs
        AzureADandPersonalMicrosoftAccount
        PersonalMicrosoftAccount


2.5. APPROLES  (seccion: appRoles, alias: app_roles)

    Definicion de rol:

        {
          "aplicacion": "Panel de Analisis Comercial",
          "displayName": "Administrador",
          "value": "Admin",
          "allowedMemberTypes": [ "User" ]
        }

    Asignacion de rol:

        {
          "aplicacion": "Panel de Analisis Comercial",
          "value": "Admin",
          "principal": "lucia.g@{tenant}"
        }

    El normalizador distingue definicion de asignacion por la presencia de
    "principal". Si tiene principal, es asignacion; si no, es definicion.

    Campos obligatorios (definicion):
        aplicacion, displayName, value

    Campos obligatorios (asignacion):
        aplicacion, value, principal

    allowedMemberTypes:
        User, Application


2.6. CREDENCIALESAPP  (seccion: credencialesApp, alias: credenciales_app, secrets)

    {
      "aplicacion": "Panel de Analisis Comercial",
      "displayName": "Lab secret",
      "endDateTime": "2027-01-01T00:00:00"
    }

    Campos obligatorios:
        aplicacion, displayName

    Campos opcionales:
        endDateTime (por defecto, un ano desde la creacion)

    El SECRETO no va en el JSON. Se genera en la creacion y se muestra UNA
    SOLA VEZ al operador.


2.7. PERMISOSAPI  (seccion: permisosApi, alias: permisos_api, apiPermissions)

    {
      "aplicacion": "Panel de Analisis Comercial",
      "recurso": "Microsoft Graph",
      "permiso": "User.Read.All",
      "tipo": "application"
    }

    Campos obligatorios:
        aplicacion, recurso, permiso

    Campos opcionales:
        tipo (application o delegated; por defecto application)


2.8. INVITADOS  (seccion: invitados, alias: guests)

    {
      "email": "invitado@contoso.com",
      "displayName": "Invitado Ejemplo",
      "redirectUrl": "https://myapplications.microsoft.com",
      "sendMessage": true
    }

    Campos obligatorios:
        email, displayName

    Campos opcionales:
        redirectUrl, sendMessage


2.9. VULNERABILIDADES  (seccion: vulnerabilidades, alias: vulnerability)

    {
      "nombre": "escenarioej1_sp_owner",
      "tipo": "ServicePrincipalOwner",
      "parametros": {
        "usuario": "lucia.g@{tenant}",
        "aplicacion": "Panel de Analisis Comercial"
      }
    }

    Tipos soportados:
        ServicePrincipalOwner
        GroupOwner
        ApplicationSecret
        PimEligibleRole

    Cada tipo tiene sus propios parametros. Ver docs/capacidades.txt.


2.10. ADMINISTRATIVEUNITS  (seccion: administrativeUnits, solo P1+)

    {
      "displayName": "AU Ventas",
      "description": "Unidad administrativa de Ventas",
      "members": [ "lucia.g@{tenant}", "Departamento de Ventas" ],
      "roles": [
        { "rol": "User Administrator", "usuario": "lucia.g@{tenant}" }
      ]
    }

    Campos obligatorios:
        displayName

    Campos opcionales:
        description, members, roles


2.11. GRUPOSDINAMICOS  (seccion: gruposDinamicos, solo P1+)

    {
      "displayName": "Dinamico Guests",
      "description": "Grupo dinamico de invitados",
      "membershipRule": "(user.userType -eq \"Guest\")",
      "processingState": "On"
    }

    Campos obligatorios:
        displayName, membershipRule

    Campos opcionales:
        description, processingState (On o Paused; por defecto On)


2.12. GRUPOSROLEASSIGNABLE  (seccion: gruposRoleAssignable, solo P1+)

    {
      "displayName": "RoleAssignable Ventas",
      "description": "Grupo con asignacion de roles"
    }

    Campos obligatorios:
        displayName


2.13. LICENCIAS  (seccion: licencias, solo P1+)

    {
      "usuario": "lucia.g@{tenant}",
      "skuPartNumber": "ENTERPRISEPACK",
      "disabledPlans": [ "EXCHANGE_S_ENTERPRISE" ]
    }

    Campos obligatorios:
        usuario, skuPartNumber

    Campos opcionales:
        disabledPlans

    El SkuId se resuelve en runtime consultando Get-MgSubscribedSku. Si el
    tenant no tiene el SKU, se avisa y se omite.


2.14. ACCESOCONDICIONAL  (seccion: accesoCondicional, solo P1+)

    {
      "displayName": "CA MFA para admins",
      "state": "disabled",
      "conditions": {
        "users": { "includeRoles": [ "62e90394-69f5-4237-9190-012177145e10" ] },
        "applications": { "includeApplications": [ "All" ] }
      },
      "grantControls": {
        "operator": "OR",
        "builtInControls": [ "mfa" ]
      }
    }

    Campos obligatorios:
        displayName, conditions, grantControls

    Campos opcionales:
        state (disabled, enabled, enabledForReportingButNotEnforced;
        por defecto disabled)

    SEGURIDAD: se recomienda generar en state disabled y habilitar
    manualmente tras revisar.


2.15. METODOSAUTH  (seccion: metodosAuth, solo P1+)

    {
      "usuario": "lucia.g@{tenant}",
      "lifetimeInMinutes": 60,
      "isUsableOnce": true
    }

    Campos obligatorios:
        usuario

    Campos opcionales:
        lifetimeInMinutes (10-43200; por defecto 60),
        isUsableOnce (por defecto true),
        startDateTime

    El CODIGO TAP no va en el JSON. Se genera en la creacion y se muestra UNA
    SOLA VEZ.


2.16. PIM  (seccion: pim, solo P2)

    {
      "usuario": "lucia.g@{tenant}",
      "rol": "User Administrator",
      "duracion": "PT8H",
      "justificacion": "Asignacion de laboratorio"
    }

    Campos obligatorios:
        usuario, rol

    Campos opcionales:
        duracion (formato ISO 8601: PT8H, PT30M; por defecto PT8H),
        justificacion


-------------------------------------------------------------------------------
3. ALIAS ACEPTADOS
-------------------------------------------------------------------------------

Cada capacidad declara un SeccionJson y, opcionalmente, una lista de Alias. El
normalizador prueba primero el SeccionJson y luego cada alias. Eso permite
compatibilidad con escenarios escritos en espanol o en versiones anteriores.

    CAPACIDAD            SECCION JSON         ALIAS
    -------------------  -------------------  --------------------------------
    Usuarios             usuarios             Usuarios
    Grupos               grupos               Grupos
    Relaciones           relaciones           Relaciones
    Aplicaciones         aplicaciones         Aplicaciones, apps
    AppRoles             appRoles             app_roles
    CredencialesApp      credencialesApp      credenciales_app, secrets
    PermisosApi          permisosApi          permisos_api, apiPermissions
    Invitados            invitados            guests
    Vulnerabilidades     vulnerabilidades     vulnerability
    AdministrativeUnits  administrativeUnits  unidadesAdministrativas,
                                              unidades_administrativas,
                                              adminUnits
    GruposDinamicos      gruposDinamicos      dynamicGroups, dynamic_groups
    GruposRoleAssignable gruposRoleAssignable grupos_role_assignable,
                                              gruposAsignablesARoles
    Licencias            licencias            licenses
    AccesoCondicional    accesoCondicional    acceso_condicional,
                                              conditionalAccess
    MetodosAuth          metodosAuth          metodos_auth,
                                              authenticationMethods
    Pim                  pim                  PIM, rolesElegibles


-------------------------------------------------------------------------------
4. PLANTILLAS
-------------------------------------------------------------------------------

Una PLANTILLA es un escenario normalizado que se usa como esqueleto en el flujo
de creacion automatica (nivel -> tipo -> crear). Vive en
escenarios/plantillas/*.json.

Plantillas generadas por generar_biblioteca.ps1:

    basico           usuarios, grupos, aplicaciones, relaciones
    aplicaciones     usuarios, aplicaciones, appRoles, credencialesApp,
                     permisosApi
    invitados        invitados
    mixto            todas las secciones disponibles para el nivel actual
    administracion   usuarios, grupos, administrativeUnits, gruposDinamicos,
                     gruposRoleAssignable (solo P1+)
    acceso           accesoCondicional, metodosAuth (solo P1+)
    pim              usuarios, pim (solo P2)

Las plantillas no contienen datos: son esqueletos con las secciones vacias.
El operador las rellena o las usa como base para crear escenarios propios.


-------------------------------------------------------------------------------
5. NORMALIZACION Y VALIDACION
-------------------------------------------------------------------------------

El programa no lee el JSON directamente. Lo pasa por
ConvertTo-LabEscenarioNormalizado, que produce un objeto con todas las
secciones posibles:

    [pscustomobject]@{
        Nombre          = 'escenarioej1'
        Descripcion     = '...'
        Version         = '1.0'
        SourcePath      = 'C:\...\escenarioej1.json'
        Secciones       = @{ 'Usuarios' = @(...); 'Grupos' = @(...); ... }
        Desconocidas    = @('pim', 'otraSeccion')
        RawDesconocidas = @{ 'pim' = @(...) }
        Errores         = @()
    }

El normalizador descubre las secciones a partir de las capacidades
registradas. Si una seccion no la reclama ninguna capacidad, va a Desconocidas
y se preserva en RawDesconocidas.

La validacion se hace en dos fases:

    FASE 1: normalizacion
        JSON valido, secciones son arrays u objetos, version reconocible.
        Los problemas van a Errores.

    FASE 2: validacion por capacidad
        Invoke-LabValidacionEscenario recorre las secciones no vacias y llama
        a ValidarDef de cada capacidad. Devuelve un array de errores.

Si hay errores en cualquier fase, creauto.ps1 aborta antes de crear nada.


-------------------------------------------------------------------------------
6. MODELO DE SEMILLA Y CONTRASENAS
-------------------------------------------------------------------------------

Los escenarios NO contienen contrasenas. Cada escenario tiene una semilla local
en escenarios/.secrets/<escenario>.seed (32 bytes aleatorios en Base64, fuera
de Git). De ella se deriva la contrasena de cada usuario:

    password = HMAC-SHA256(semilla, upn) -> Base64 -> 16 chars + "!Aa1"

Propiedades:

    - Determinista: misma semilla + mismo UPN -> misma contrasena.
    - Unica por usuario: cada UPN produce una contrasena distinta.
    - Reproducible: conservando la semilla, se regeneran las contrasenas.
    - Fuera de Git: escenarios/.secrets/ esta en .gitignore.

En creauto.ps1 las contrasenas se generan siempre desde la semilla y se
muestran UNA SOLA VEZ al final. En creamanual.ps1 el operador puede
introducirlas manualmente o generarlas desde la semilla de la sesion.

En ningun caso la contrasena se guarda en el manifiesto ni en el JSON.


-------------------------------------------------------------------------------
7. EJEMPLO COMPLETO (FREE)
-------------------------------------------------------------------------------

    {
      "nombre": "escenarioej1",
      "descripcion": "Escenario de ejemplo 1.",
      "version": "1.0",
      "usuarios": [
        {
          "displayName": "Lucia Garcia",
          "upn": "lucia.g@{tenant}",
          "mailNickname": "lucia.g",
          "department": "Ventas",
          "jobTitle": "Comercial"
        }
      ],
      "grupos": [
        {
          "displayName": "Departamento de Ventas",
          "description": "Usuarios del departamento de Ventas",
          "mailNickname": "departamento-ventas"
        }
      ],
      "aplicaciones": [
        {
          "displayName": "Panel de Analisis Comercial",
          "description": "Aplicacion interna",
          "signInAudience": "AzureADMyOrg",
          "redirectUris": [ "https://panel.empresa.local/callback" ]
        }
      ],
      "relaciones": [
        {
          "tipo": "membresia",
          "usuario": "lucia.g@{tenant}",
          "grupo": "Departamento de Ventas"
        }
      ],
      "vulnerabilidades": [
        {
          "nombre": "escenarioej1_sp_owner",
          "tipo": "ServicePrincipalOwner",
          "parametros": {
            "usuario": "lucia.g@{tenant}",
            "aplicacion": "Panel de Analisis Comercial"
          }
        }
      ]
    }


-------------------------------------------------------------------------------
8. EJEMPLO COMPLETO (P1 + P2)
-------------------------------------------------------------------------------

    {
      "nombre": "escenarioej_p1p2",
      "descripcion": "Escenario con secciones P1 y P2.",
      "version": "1.0",
      "usuarios": [
        {
          "displayName": "Lucia Garcia",
          "upn": "lucia.g@{tenant}",
          "mailNickname": "lucia.g"
        }
      ],
      "grupos": [
        {
          "displayName": "Departamento de Ventas",
          "description": "Usuarios del departamento de Ventas",
          "mailNickname": "departamento-ventas"
        }
      ],
      "administrativeUnits": [
        {
          "displayName": "AU Ventas",
          "description": "Unidad administrativa de Ventas",
          "members": [ "lucia.g@{tenant}", "Departamento de Ventas" ],
          "roles": [
            { "rol": "User Administrator", "usuario": "lucia.g@{tenant}" }
          ]
        }
      ],
      "gruposDinamicos": [
        {
          "displayName": "Dinamico Guests",
          "description": "Grupo dinamico de invitados",
          "membershipRule": "(user.userType -eq \"Guest\")",
          "processingState": "On"
        }
      ],
      "gruposRoleAssignable": [
        {
          "displayName": "RoleAssignable Ventas",
          "description": "Grupo con asignacion de roles"
        }
      ],
      "accesoCondicional": [
        {
          "displayName": "CA MFA para admins",
          "state": "disabled",
          "conditions": {
            "users": { "includeRoles": [ "62e90394-69f5-4237-9190-012177145e10" ] },
            "applications": { "includeApplications": [ "All" ] }
          },
          "grantControls": {
            "operator": "OR",
            "builtInControls": [ "mfa" ]
          }
        }
      ],
      "metodosAuth": [
        {
          "usuario": "lucia.g@{tenant}",
          "lifetimeInMinutes": 60,
          "isUsableOnce": true
        }
      ],
      "pim": [
        {
          "usuario": "lucia.g@{tenant}",
          "rol": "User Administrator",
          "duracion": "PT8H"
        }
      ]
    }


-------------------------------------------------------------------------------
9. RESUMEN
-------------------------------------------------------------------------------

    - Un escenario es un JSON con metadatos y secciones por capacidad.
    - Cada seccion es un array de objetos.
    - Los alias permiten nombres alternativos (espanol, versiones antiguas).
    - Las plantillas son esqueletos para el flujo nivel -> tipo.
    - El normalizador descubre secciones a partir de las capacidades.
    - La validacion se hace en dos fases: normalizacion y por capacidad.
    - Las contrasenas no van en el JSON: se derivan de la semilla local.
    - El secreto de app y el codigo TAP se muestran una sola vez.

===============================================================================