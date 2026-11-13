===============================================================================
                                MANIFIESTO
===============================================================================

El MANIFIESTO es un fichero JSON que registra todo lo que el laboratorio ha
creado o modificado en Entra ID, para poder revertirlo después de forma
controlada. Es el contrato entre la creación y la limpieza: lo que no está en
el manifiesto, no se borra.

Este documento explica la estructura v2.1 del manifiesto, los estados de cada
objeto y vulnerabilidad, la migración desde versiones anteriores y cómo
funciona la limpieza con verificación de objectId.


-------------------------------------------------------------------------------
1. ESTRUCTURA DEL MANIFIESTO V2.1
-------------------------------------------------------------------------------

Un manifiesto v2.1 tiene metadatos y dos listas: objetos y vulnerabilidades.

    {
      "manifestVersion": "2.1",
      "fecha": "2026-11-05T10:30:00",
      "tenantId": "00000000-0000-0000-0000-000000000000",
      "tenantDomain": "contoso.onmicrosoft.com",
      "nivel": "P1",
      "escenario": "escenarioej1",
      "semilla": "escenarioej1",
      "objetos": [ ... ],
      "vulnerabilidades": [ ... ]
    }

CAMPOS DE NIVEL SUPERIOR:

    manifestVersion
        Versión del formato. Hoy es "2.1". Permite migraciones futuras.

    fecha
        Fecha ISO 8601 de creación del manifiesto.

    tenantId
        Tenant donde se creó. Sirve para detectar si el manifiesto se está
        aplicando en otro tenant.

    tenantDomain
        Dominio por defecto. Solo informativo.

    nivel
        Nivel elegido (Free, P1, P2). Informativo; el cleanup no lo usa para
        decidir.

    escenario
        Nombre del escenario o de la sesión manual. Informativo.

    semilla
        Nombre de la semilla usada (no la semilla en sí). Informativo; permite
        saber qué semilla regenerar.

    objetos
        Lista plana de objetos creados. Ver sección 2.

    vulnerabilidades
        Lista de vulnerabilidades aplicadas. Se mantiene separada porque el
        cleanup las revierte ANTES que los objetos. Ver sección 3.


-------------------------------------------------------------------------------
2. FORMA DE CADA OBJETO
-------------------------------------------------------------------------------

Cada entrada de objetos tiene campos comunes (que pone el núcleo) y campos
específicos (que decide la capacidad):

    {
      "id": "obj-0001",
      "tipo": "AppRole",
      "capacidad": "AppRoles",
      "estado": "creado",
      "timestamp": "2026-11-05T10:31:00",
      "tenantId": "00000000-0000-0000-0000-000000000000",
      "datos": {
        "appId": "11111111-1111-1111-1111-111111111111",
        "value": "Admin"
      }
    }

CAMPOS COMUNES (los pone el núcleo, no la capacidad):

    id
        Identificador único dentro del manifiesto (obj-0001, obj-0002...).
        Sirve para referencias cruzadas y para logs.

    tipo
        Tipo de objeto Graph (Usuario, Grupo, Aplicacion, ServicePrincipal,
        AppRole, AdministrativeUnit, AppRoleAssignment, CredencialApp,
        PermisoApi, Licencia, PimEligibleRole, etc.). Informativo.

    capacidad
        NOMBRE DE LA CAPACIDAD que lo creó. Es lo que el cleanup usa para
        despachar. Si la capacidad no está registrada, el cleanup no puede
        revertir el objeto.

    estado
        Estado del objeto. Ver sección 4.

    timestamp
        Fecha ISO 8601 de creación.

    tenantId
        Tenant donde se creó. Sirve para detectar drift.

    datos
        Datos específicos de la capacidad. El núcleo no los interpreta; solo
        los guarda y los pasa a Revertir.

CAMPOS ESPECÍFICOS (van dentro de datos, los decide la capacidad):

    Cada capacidad decide qué guardar en datos para poder revertir. Regla:
    datos debe contener todo lo que Revertir necesita, ni más ni menos.
    Ejemplos:

        Usuario          ->  upn, objectId, displayName
        Grupo            ->  displayName, objectId
        Aplicacion       ->  displayName, objectId, appId
        ServicePrincipal ->  displayName, objectId, appId
        AppRole          ->  appId, value
        AppRoleAssignment->  servicePrincipalId, principalId, appRoleId
        CredencialApp    ->  appId, keyId
        PermisoApi       ->  clientSpId, appRoleId o grantId
        AdministrativeUnit-> displayName, objectId
        PimEligibleRole  ->  userId, roleDefinitionId, scheduleRequestId

    El manifiesto es AUTOCONTENIDO: datos debe bastar para revertir sin
    consultar el escenario original.


-------------------------------------------------------------------------------
3. LA SECCIÓN VULNERABILIDADES
-------------------------------------------------------------------------------

Se mantiene separada de objetos por una razón de orden: el cleanup revierte
PRIMERO las vulnerabilidades y DESPUÉS los objetos. Si estuvieran mezclados,
el cleanup tendría que ordenar por tipo, y eso volvería a acoplar.

Forma de cada vulnerabilidad:

    {
      "id": "vuln-0001",
      "nombre": "escenarioej1_sp_owner",
      "tipo": "ServicePrincipalOwner",
      "capacidad": "Vulnerabilidades",
      "estado": "aplicada",
      "timestamp": "2026-11-05T10:32:00",
      "datos": {
        "servicePrincipalId": "...",
        "directoryObjectId": "...",
        "objetoAfectadoObjectId": "..."
      }
    }

Los campos comunes son los mismos que en objetos. La diferencia es que tipo es
el tipo de vulnerabilidad, y datos son los objetos afectados que devolvió el
aplicador.

IMPORTANTE - CAMPO CAPACIDAD:
    El campo 'capacidad' es OBLIGATORIO y refleja la capacidad que aplicó la
    vulnerabilidad. Hoy puede ser 'Vulnerabilidades' o 'Pim' (si
    PimEligibleRole se delegó en cap_pim.ps1). El cleanup usará esta
    capacidad para despachar la reversión.

IMPORTANTE - OBJECTID DEL OBJETO AFECTADO:
    Todos los datos de vulnerabilidad incluyen 'objetoAfectadoObjectId'.
    Es el objectId del SP, grupo, app o usuario sobre el que se aplicó.
    Se usa en Test-LabVulnerabilidadCoincideConManifiesto antes de revertir,
    para evitar revertir sobre un objeto borrado y recreado externamente.

Estados de vulnerabilidad:

    aplicada       ->  la vulnerabilidad se aplicó y se puede revertir.
    preexistente   ->  no se aplicó porque el objeto afectado era preexistente.
    fallida        ->  no se pudo revertir (o se aplicó parcialmente).
    revertida      ->  ya se revirtió.
    no-revertida   ->  no se pudo revertir (capacidad no disponible, objectId
                       distinto, etc.).
    omitida        ->  omitida por configuración (exclusión).

El detalle de tipos, catálogo y flujo está en docs/vulnerabilidades.md.


-------------------------------------------------------------------------------
4. ESTADOS DE CADA OBJETO
-------------------------------------------------------------------------------

    ESTADO          SIGNIFICADO
    --------------  ------------------------------------------------------------
    creado          Creado por el laboratorio en esta ejecución.
    reutilizado     Ya existía en el tenant (creado por una ejecución anterior
                    del laboratorio), reutilizado sin crear.
    preexistente    Ya existía ANTES del laboratorio (estaba en el snapshot
                    pre-lab). NO se adopta, NO se modifica, NO se revierte.
    fallido         Intento de creación fallido; se puede reintentar la
                    reversión.
    revertido       Ya revertido.
    no-revertido    No se pudo revertir (capacidad no disponible, objectId
                    distinto, etc.).
    omitido         Omitido por alguna razón (por ejemplo, preexistente).

ESTADOS QUE EL CLEANUP INTENTA REVERTIR:

    Objetos:
        creado, reutilizado, fallido
    Vulnerabilidades:
        aplicada, fallida

ESTADOS QUE EL CLEANUP IGNORA:

    Objetos:
        preexistente, revertido, no-revertido, omitido
    Vulnerabilidades:
        preexistente, revertida, no-revertida, omitida

La distinción entre reutilizado y preexistente es clave:

    - reutilizado: el objeto lo creó una ejecución anterior del laboratorio.
      Se puede revertir.
    - preexistente: el objeto existía antes de que el laboratorio empezara.
      No se toca.

Las listas viven en lib_manifiesto.ps1:
    $script:LabEstadosReversiblesObjeto
    $script:LabEstadosIgnoradosObjeto
    $script:LabEstadosReversiblesVulnerabilidad
    $script:LabEstadosIgnoradosVulnerabilidad

No hay que duplicar esta lógica en ningún otro sitio. Get-LabManifiestoPendientes
es la única fuente de verdad.


-------------------------------------------------------------------------------
5. CÓMO SE RELLENA EL MANIFIESTO
-------------------------------------------------------------------------------

5.1. Objetos (escenario)
------------------------
El núcleo (lib_creadores.ps1) hace lo siguiente por cada objeto que devuelve
Crear de una capacidad:

    1. Añade id, capacidad, estado, timestamp, tenantId.
    2. Mete los datos específicos en datos.
    3. Lo añade a objetos.

La capacidad NO rellena los campos comunes; solo devuelve un objeto con tipo,
estadoDetalle y los datos específicos. El núcleo los envuelve:

    LO QUE DEVUELVE Crear:

        [pscustomobject]@{
            tipo          = 'AppRole'
            estadoDetalle = 'creado'
            appId         = '...'
            value         = 'Admin'
        }

    LO QUE EL NÚCLEO GUARDA EN EL MANIFIESTO:

        [pscustomobject]@{
            id        = 'obj-0042'
            tipo      = 'AppRole'
            capacidad = 'AppRoles'
            estado    = 'creado'
            timestamp = '2026-11-05T10:31:00'
            tenantId  = '...'
            datos     = @{
                appId = '...'
                value = 'Admin'
            }
        }

5.2. Vulnerabilidades
---------------------
Las vulnerabilidades NO se procesan en Invoke-LabCreacion (no están en el
escenario). Se registran desde menu.ps1 [5] con Add-LabManifiestoVulnerabilidad:

    $null = Add-LabManifiestoVulnerabilidad `
        -Manifiesto $m `
        -Nombre $def.nombre `
        -Tipo $r.tipo `
        -Capacidad $r.capacidadAplicadora `
        -Datos $datos `
        -Estado $estado

Add-LabManifiestoVulnerabilidad requiere -Capacidad. Ya no se hardcodea
'Vulnerabilidades'. Se usa la capacidad que la aplicó ('Vulnerabilidades' o
'Pim').


-------------------------------------------------------------------------------
6. CÓMO SE USA EL MANIFIESTO EN EL CLEANUP
-------------------------------------------------------------------------------

clean_up.ps1 no tiene un switch por tipo. Hace esto:

    1. Revertir vulnerabilidades primero:

        foreach ($v in $manifiesto.vulnerabilidades) {
            si estado ignorado -> saltar.
            $cap = Get-LabCapacidad -Nombre $v.capacidad
            if (-not $cap) { avisar, marcar no-revertida, continuar }
            if (-not $v.datos) { avisar, marcar no-revertida, continuar }
            if (-not (Test-LabVulnerabilidadCoincideConManifiesto -Vulnerabilidad $v)) {
                avisar, marcar no-revertida, continuar
            }
            if ($cap.PreRevertir) { & $cap.PreRevertir @($v) $ctx }
            $ok = & $cap.Revertir $v $ctx
            if ($ok) { estado = revertida } else { estado = fallida }
        }

    2. Revertir objetos en orden inverso de creación (LIFO):

        $objetosOrdenados = $manifiesto.objetos | Sort-Object timestamp -Descending
        foreach ($o in $objetosOrdenados) {
            if ($o.estado -notin $script:LabEstadosReversiblesObjeto) { continue }
            $cap = Get-LabCapacidad -Nombre $o.capacidad
            if (-not $cap) { avisar y continuar }
            if (-not (Test-LabObjetoCoincideConManifiesto -Objeto $o)) {
                avisar y omitir
                continue
            }
            if ($cap.PreRevertir) { & $cap.PreRevertir @($o) $ctx }
            $ok = & $cap.Revertir $o $ctx
            if ($ok) { estado = revertido } else { estado = fallido }
        }

POR QUÉ LIFO:

    Si una capacidad crea un objeto que depende de otro (por ejemplo, un
    AppRoleAssignment depende de un AppRole y de un User), revertir en orden
    inverso rompe las dependencias sin necesidad de un grafo explícito. Es el
    mismo principio que usa un finally anidado.

POR QUÉ VULNERABILIDADES PRIMERO:

    Si una vulnerabilidad añadió un owner a un SP, quitar el owner antes de
    borrar el SP evita errores de Graph (no puedes borrar un objeto con
    owners si el owner no existe, etc.).

SI UNA CAPACIDAD NO ESTÁ DISPONIBLE:

    - Conservadora (recomendada): dejar el objeto/vulnerabilidad en el
      manifiesto con estado no-revertido/no-revertida y avisar. El operador
      puede reactivar la capacidad y reejecutar el cleanup.
    - Agresiva (opcional, con -Forzar): intentar un borrado genérico por tipo
      para objetos (Usuario, Grupo, Aplicacion, ServicePrincipal). No funciona
      para vulnerabilidades: cada tipo sabe cómo revertirse.


-------------------------------------------------------------------------------
7. VERIFICACIÓN DE OBJECTID ANTES DE BORRAR
-------------------------------------------------------------------------------

Antes de llamar a Revertir de cada objeto/vulnerabilidad, el cleanup verifica
que el objectId del manifiesto coincide con el actual en el tenant.

7.1. Objetos
------------
    - Si el objeto ya no existe: idempotente, se puede "revertir" (no-op).
    - Si el objeto existe y el objectId coincide: es el mismo objeto, se puede
      borrar.
    - Si el objeto existe pero el objectId NO coincide: es otro objeto con el
      mismo nombre (borrado y recreado externamente). NO se borra. Se marca
      como no-revertido y se avisa.

    Tipos con verificación específica (Test-LabObjetoCoincideConManifiesto):
        Usuario, Grupo, Aplicacion, ServicePrincipal, AdministrativeUnit.
    El resto cae en default -> $true (se confía en el manifiesto).

7.2. Vulnerabilidades
---------------------
    - Test-LabVulnerabilidadCoincideConManifiesto verifica el objectId del
      objeto afectado (objetoAfectadoObjectId en datos).
    - Si el objeto ya no existe: idempotente (no-op en la verificación).
    - Si el objectId coincide: se puede revertir.
    - Si el objectId NO coincide: no se revierte, se marca no-revertida y se
      avisa.

    Tipos cubiertos:
        ServicePrincipalOwner, GroupOwner, ApplicationSecret, PimEligibleRole.

Esta verificación es la última línea de defensa contra borrar objetos que no
son del laboratorio. Si el manifiesto no tiene objectId (por ejemplo, migrado
de v1 sin ese dato), no se puede verificar y se confía en el manifiesto.


-------------------------------------------------------------------------------
8. MIGRACIÓN DESDE V1 Y V2
-------------------------------------------------------------------------------

8.1. V1 -> V2
-------------
Los manifiestos v1 (sin manifestVersion o con listas por tipo) se migran
automáticamente al cargar:

    Usuarios          ->  objetos con capacidad Usuarios, datos { upn }
    Grupos            ->  objetos con capacidad Grupos, datos { displayName }
    Aplicaciones      ->  objetos con capacidad Aplicaciones, datos { displayName }
    ServicePrincipals ->  objetos con capacidad Aplicaciones, datos { objectId }
    Vulnerabilidades  ->  lista vulnerabilidades con capacidad Vulnerabilidades

Los objetos migrados se marcan como creado, porque v1 no guardaba información
de preexistencia. Es un compromiso: si el objeto era preexistente, el cleanup
intentará borrarlo. El operador debe revisar el manifiesto migrado antes de
ejecutar el cleanup.

8.2. V2 -> V2.1
---------------
En v2, las vulnerabilidades se guardaban en la lista 'objetos' con
tipo = 'VulnerabilidadAplicada' y capacidad = 'Vulnerabilidades'. En v2.1
viven en 'vulnerabilidades'.

La migración v2 -> v2.1 (ConvertTo-LabManifiestoV21):
    1. Separa los objetos con capacidad = 'Vulnerabilidades' (o tipo que
       empiece por 'Vulnerab') del resto.
    2. Los convierte a la forma de vulnerabilidad (id, nombre, tipo,
       capacidad, estado, timestamp, datos).
    3. Mapea el estado:
           'creado'        -> 'aplicada'
           'preexistente'  -> 'preexistente'
           'fallido'       -> 'fallida'
           'revertido'     -> 'revertida'
           'no-revertido'  -> 'no-revertida'
           'omitido'       -> 'omitida'
    4. Deja el resto de objetos intactos.
    5. Marca manifestVersion = '2.1'.

Es automática al cargar con Get-LabManifiesto. El operador no tiene que hacer
nada.

8.3. Estructura del código de migración
---------------------------------------
La migración la hace lib_manifiesto.ps1:
    - ConvertTo-LabManifiestoV2  (v1 -> v2)
    - ConvertTo-LabManifiestoV21 (v2 -> v2.1)

Se invocan automáticamente desde Get-LabManifiesto.


-------------------------------------------------------------------------------
9. GUARDADO Y RENOMBRADO
-------------------------------------------------------------------------------

Guardado:

    Save-LabManifiesto serializa el manifiesto con ConvertTo-Json -Depth 15.
    El manifiesto se MUTA durante la reversión: los estados cambian de creado a
    revertido (o fallido). Se guarda con el estado actualizado para que se pueda
    reintentar solo lo que falló.

Renombrado:

    Rename-LabManifiestoProcesado renombra el manifiesto con sufijo
    _procesado_<timestamp>.json cuando TODO se ha revertido (objetos y
    vulnerabilidades). Eso evita reprocesarlo por error.

    Si quedan pendientes (fallidos, no-revertidos, vulnerabilidades aplicadas),
    el manifiesto se conserva con su nombre original para reintentar.


-------------------------------------------------------------------------------
10. SEGURIDAD
-------------------------------------------------------------------------------

    - El manifiesto NO contiene contraseñas. Solo guarda identificadores y
      datos necesarios para revertir.
    - Las contraseñas se derivan de la semilla local del escenario y nunca se
      persisten en el manifiesto.
    - El secreto de app (client secret) y el código TAP NO se guardan. Solo se
      guarda el keyId o el methodId para poder revocarlos.
    - El manifiesto está en .gitignore (manifiesto_lab*.json). No debe
      subirse a Git: contiene UPNs y nombres de objetos del tenant real.


-------------------------------------------------------------------------------
11. EJEMPLO COMPLETO V2.1
-------------------------------------------------------------------------------

    {
      "manifestVersion": "2.1",
      "fecha": "2026-11-05T10:30:00",
      "tenantId": "00000000-0000-0000-0000-000000000000",
      "tenantDomain": "contoso.onmicrosoft.com",
      "nivel": "Free",
      "escenario": "escenarioej1",
      "semilla": "escenarioej1",
      "objetos": [
        {
          "id": "obj-0001",
          "tipo": "Usuario",
          "capacidad": "Usuarios",
          "estado": "creado",
          "timestamp": "2026-11-05T10:31:00",
          "tenantId": "00000000-0000-0000-0000-000000000000",
          "datos": {
            "upn": "lucia.g@contoso.onmicrosoft.com",
            "objectId": "11111111-1111-1111-1111-111111111111",
            "displayName": "Lucia Garcia"
          }
        },
        {
          "id": "obj-0002",
          "tipo": "Grupo",
          "capacidad": "Grupos",
          "estado": "creado",
          "timestamp": "2026-11-05T10:31:05",
          "tenantId": "00000000-0000-0000-0000-000000000000",
          "datos": {
            "displayName": "Departamento de Ventas",
            "objectId": "22222222-2222-2222-2222-222222222222"
          }
        },
        {
          "id": "obj-0003",
          "tipo": "MembresiaGrupo",
          "capacidad": "Relaciones",
          "estado": "creado",
          "timestamp": "2026-11-05T10:31:10",
          "tenantId": "00000000-0000-0000-0000-000000000000",
          "datos": {
            "groupId": "22222222-2222-2222-2222-222222222222",
            "userId": "11111111-1111-1111-1111-111111111111"
          }
        }
      ],
      "vulnerabilidades": [
        {
          "id": "vuln-0001",
          "nombre": "escenarioej1_sp_owner",
          "tipo": "ServicePrincipalOwner",
          "capacidad": "Vulnerabilidades",
          "estado": "aplicada",
          "timestamp": "2026-11-05T10:31:15",
          "datos": {
            "servicePrincipalId": "33333333-3333-3333-3333-333333333333",
            "directoryObjectId": "11111111-1111-1111-1111-111111111111",
            "objetoAfectadoObjectId": "33333333-3333-3333-3333-333333333333",
            "aplicacion": "Panel de Analisis Comercial",
            "usuario": "lucia.g@contoso.onmicrosoft.com",
            "capacidadAplicadora": "Vulnerabilidades",
            "tipoVulnerabilidad": "ServicePrincipalOwner"
          }
        }
      ]
    }


-------------------------------------------------------------------------------
12. RESUMEN
-------------------------------------------------------------------------------

    - El manifiesto registra todo lo creado y modificado para poder revertirlo.
    - Tiene metadatos, una lista plana de objetos y una lista de
      vulnerabilidades.
    - Cada objeto/vulnerabilidad tiene id, tipo, capacidad, estado, timestamp,
      tenantId y datos.
    - datos es específico de la capacidad y debe bastar para revertir.
    - El cleanup despacha por capacidad, revierte vulnerabilidades primero y
      objetos en LIFO.
    - Verifica objectId antes de borrar (objetos y vulnerabilidades).
    - Llama a PreRevertir si la capacidad lo implementa.
    - Ignora preexistentes, revertidos/revertidas y no-revertidos/no-revertidas.
    - Se migra automáticamente desde v1 (a v2) y desde v2 (a v2.1).
    - No contiene contraseñas ni secretos.
    - Detalle de vulnerabilidades en docs/vulnerabilidades.md.

===============================================================================