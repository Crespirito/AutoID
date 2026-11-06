===============================================================================
                                MANIFIESTO
===============================================================================

El MANIFIESTO es un fichero JSON que registra todo lo que el laboratorio ha
creado en Entra ID, para poder revertirlo despues de forma controlada. Es el
contrato entre la creacion y la limpieza: lo que no esta en el manifiesto, no
se borra.

Este documento explica la estructura v2 del manifiesto, los estados de cada
objeto, la migracion desde v1 y como funciona la limpieza con verificacion de
objectId.


-------------------------------------------------------------------------------
1. ESTRUCTURA DEL MANIFIESTO V2
-------------------------------------------------------------------------------

Un manifiesto v2 tiene metadatos y dos listas: objetos y vulnerabilidades.

    {
      "manifestVersion": "2.0",
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
        Version del formato. Hoy es "2.0". Permite migraciones futuras.

    fecha
        Fecha ISO 8601 de creacion del manifiesto.

    tenantId
        Tenant donde se creo. Sirve para detectar si el manifiesto se esta
        aplicando en otro tenant.

    tenantDomain
        Dominio por defecto. Solo informativo.

    nivel
        Nivel elegido (Free, P1, P2). Informativo; el cleanup no lo usa para
        decidir.

    escenario
        Nombre del escenario o de la sesion manual. Informativo.

    semilla
        Nombre de la semilla usada (no la semilla en si). Informativo; permite
        saber que semilla regenerar.

    objetos
        Lista plana de objetos creados. Ver seccion 2.

    vulnerabilidades
        Lista de vulnerabilidades aplicadas. Se mantiene separada porque el
        cleanup las revierte ANTES que los objetos. Ver seccion 3.


-------------------------------------------------------------------------------
2. FORMA DE CADA OBJETO
-------------------------------------------------------------------------------

Cada entrada de objetos tiene campos comunes (que pone el nucleo) y campos
especificos (que decide la capacidad):

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

CAMPOS COMUNES (los pone el nucleo, no la capacidad):

    id
        Identificador unico dentro del manifiesto (obj-0001, obj-0002...).
        Sirve para referencias cruzadas y para logs.

    tipo
        Tipo de objeto Graph (Usuario, Grupo, Aplicacion, ServicePrincipal,
        AppRole, AdministrativeUnit, AppRoleAssignment, CredencialApp,
        PermisoApi, Licencia, PimEligibleRole, etc.). Informativo.

    capacidad
        NOMBRE DE LA CAPACIDAD que lo creo. Es lo que el cleanup usa para
        despachar. Si la capacidad no esta registrada, el cleanup no puede
        revertir el objeto.

    estado
        Estado del objeto. Ver seccion 4.

    timestamp
        Fecha ISO 8601 de creacion.

    tenantId
        Tenant donde se creo. Sirve para detectar drift.

    datos
        Datos especificos de la capacidad. El nucleo no los interpreta; solo
        los guarda y los pasa a Revertir.

CAMPOS ESPECIFICOS (van dentro de datos, los decide la capacidad):

    Cada capacidad decide que guardar en datos para poder revertir. Regla:
    datos debe contener todo lo que Revertir necesita, ni mas ni menos.
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
3. LA SECCION VULNERABILIDADES
-------------------------------------------------------------------------------

Se mantiene separada de objetos por una razon de orden: el cleanup revierte
PRIMERO las vulnerabilidades y DESPUES los objetos. Si estuvieran mezclados,
el cleanup tendria que ordenar por tipo, y eso volveria a acoplar.

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
        "directoryObjectId": "..."
      }
    }

Los campos comunes son los mismos que en objetos. La diferencia es que tipo es
el tipo de vulnerabilidad, y datos son los objetos afectados que devolvio el
aplicador.

Estados de vulnerabilidad:

    aplicada       ->  la vulnerabilidad se aplico y se puede revertir.
    revertido      ->  ya se revirtio.
    fallido        ->  no se pudo revertir.
    no-revertido   ->  no se pudo revertir (capacidad no disponible, etc.).


-------------------------------------------------------------------------------
4. ESTADOS DE CADA OBJETO
-------------------------------------------------------------------------------

    ESTADO          SIGNIFICADO
    --------------  ------------------------------------------------------------
    creado          Creado por el laboratorio en esta ejecucion.
    reutilizado     Ya existia en el tenant (creado por una ejecucion anterior
                    del laboratorio), reutilizado sin crear.
    preexistente    Ya existia ANTES del laboratorio (estaba en el snapshot
                    pre-lab). NO se adopta, NO se modifica, NO se revierte.
    fallido         Intento de creacion fallido; se puede reintentar la
                    reversion.
    revertido       Ya revertido.
    no-revertido    No se pudo revertir (capacidad no disponible, objectId
                    distinto, etc.).
    omitido         Omitido por alguna razon (por ejemplo, preexistente).

ESTADOS QUE EL CLEANUP INTENTA REVERTIR:

    creado, reutilizado, fallido

ESTADOS QUE EL CLEANUP IGNORA:

    preexistente, revertido, no-revertido, omitido

La distincion entre reutilizado y preexistente es clave:

    - reutilizado: el objeto lo creo una ejecucion anterior del laboratorio.
      Se puede revertir.
    - preexistente: el objeto existia antes de que el laboratorio empezara.
      No se toca.


-------------------------------------------------------------------------------
5. COMO SE RELLENA EL MANIFIESTO
-------------------------------------------------------------------------------

El nucleo (lib_creadores.ps1) hace lo siguiente por cada objeto que devuelve
Crear de una capacidad:

    1. Anade id, capacidad, estado, timestamp, tenantId.
    2. Mete los datos especificos en datos.
    3. Lo anade a objetos.

La capacidad NO rellena los campos comunes; solo devuelve un objeto con tipo,
estadoDetalle y los datos especificos. El nucleo los envuelve:

    LO QUE DEVUELVE Crear:

        [pscustomobject]@{
            tipo          = 'AppRole'
            estadoDetalle = 'creado'
            appId         = '...'
            value         = 'Admin'
        }

    LO QUE EL NUCLEO GUARDA EN EL MANIFIESTO:

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

Consecuencia: la capacidad no necesita saber nada del manifiesto. Solo
devuelve objetos con tipo, estadoDetalle y sus datos. El nucleo hace el resto.


-------------------------------------------------------------------------------
6. COMO SE USA EL MANIFIESTO EN EL CLEANUP
-------------------------------------------------------------------------------

clean_up.ps1 no tiene un switch por tipo. Hace esto:

    1. Revertir vulnerabilidades primero:

        foreach ($v in $manifiesto.vulnerabilidades) {
            $cap = Get-LabCapacidad -Nombre $v.capacidad
            if (-not $cap) { avisar y continuar }
            $ok = & $cap.Revertir $v $ctx
            if ($ok) { marcar como revertido } else { dejar en manifiesto }
        }

    2. Revertir objetos en orden inverso de creacion (LIFO):

        $objetosOrdenados = $manifiesto.objetos | Sort-Object timestamp -Descending
        foreach ($o in $objetosOrdenados) {
            if ($o.estado -notin @('creado','reutilizado','fallido')) { continue }
            $cap = Get-LabCapacidad -Nombre $o.capacidad
            if (-not $cap) { avisar y continuar }
            if (-not (Test-LabObjetoCoincideConManifiesto -Objeto $o)) {
                avisar y omitir
                continue
            }
            $ok = & $cap.Revertir $o $ctx
            if ($ok) { marcar como revertido } else { dejar en manifiesto }
        }

POR QUE LIFO:

    Si una capacidad crea un objeto que depende de otro (por ejemplo, un
    AppRoleAssignment depende de un AppRole y de un User), revertir en orden
    inverso rompe las dependencias sin necesidad de un grafo explicito. Es el
    mismo principio que usa un finally anidado.

SI UNA CAPACIDAD NO ESTA DISPONIBLE:

    - Conservadora (recomendada): dejar el objeto en el manifiesto con estado
      no-revertido y avisar. El operador puede reactivar la capacidad y
      reejecutar el cleanup.
    - Agresiva (opcional, con -Forzar): intentar un borrado generico por tipo
      (Usuario, Grupo, Aplicacion, ServicePrincipal). Solo funciona para tipos
      Graph estandar.


-------------------------------------------------------------------------------
7. VERIFICACION DE objectId ANTES DE BORRAR
-------------------------------------------------------------------------------

Antes de llamar a Revertir de cada objeto, el cleanup verifica que el objectId
del manifiesto coincide con el actual en el tenant:

    - Si el objeto ya no existe: idempotente, se puede "revertir" (no-op).
    - Si el objeto existe y el objectId coincide: es el mismo objeto, se puede
      borrar.
    - Si el objeto existe pero el objectId NO coincide: es otro objeto con el
      mismo nombre (borrado y recreado externamente). NO se borra. Se marca
      como no-revertido y se avisa.

Esta verificacion es la ultima linea de defensa contra borrar objetos que no
son del laboratorio. Si el manifiesto no tiene objectId (por ejemplo, migrado
de v1 sin ese dato), no se puede verificar y se confia en el manifiesto.


-------------------------------------------------------------------------------
8. MIGRACION DESDE V1
-------------------------------------------------------------------------------

Los manifiestos v1 (sin manifestVersion o con listas por tipo) se migran
automaticamente al cargar:

    Usuarios          ->  objetos con capacidad Usuarios, datos { upn }
    Grupos            ->  objetos con capacidad Grupos, datos { displayName }
    Aplicaciones      ->  objetos con capacidad Aplicaciones, datos { displayName }
    ServicePrincipals ->  objetos con capacidad Aplicaciones, datos { objectId }
    Vulnerabilidades  ->  lista vulnerabilidades con capacidad Vulnerabilidades

Los objetos migrados se marcan como creado, porque v1 no guardaba informacion
de preexistencia. Es un compromiso: si el objeto era preexistente, el cleanup
intentara borrarlo. El operador debe revisar el manifiesto migrado antes de
ejecutar el cleanup.

La migracion la hace ConvertTo-LabManifiestoV2 en lib_manifiesto.ps1. Se
invoca automaticamente desde Get-LabManifiesto.


-------------------------------------------------------------------------------
9. GUARDADO Y RENOMBRADO
-------------------------------------------------------------------------------

Guardado:

    Save-LabManifiesto serializa el manifiesto con ConvertTo-Json -Depth 15.
    El manifiesto se MUTA durante la reversion: los estados cambian de creado a
    revertido o fallido. Se guarda con el estado actualizado para que se pueda
    reintentar solo lo que fallo.

Renombrado:

    Rename-LabManifiestoProcesado renombra el manifiesto con sufijo
    _procesado_<timestamp>.json cuando todo se ha revertido. Eso evita
    reprocesarlo por error.

    Si quedan pendientes (fallidos, no-revertidos), el manifiesto se conserva
    con su nombre original para reintentar.


-------------------------------------------------------------------------------
10. SEGURIDAD
-------------------------------------------------------------------------------

    - El manifiesto NO contiene contrasenas. Solo guarda identificadores y
      datos necesarios para revertir.
    - Las contrasenas se derivan de la semilla local del escenario y nunca se
      persisten en el manifiesto.
    - El secreto de app (client secret) y el codigo TAP NO se guardan. Solo se
      guarda el keyId o el methodId para poder revocarlos.
    - El manifiesto esta en .gitignore (manifiesto_lab*.json). No debe
      subirse a Git: contiene UPNs y nombres de objetos del tenant real.


-------------------------------------------------------------------------------
11. EJEMPLO COMPLETO
-------------------------------------------------------------------------------

    {
      "manifestVersion": "2.0",
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
            "directoryObjectId": "11111111-1111-1111-1111-111111111111"
          }
        }
      ]
    }


-------------------------------------------------------------------------------
12. RESUMEN
-------------------------------------------------------------------------------

    - El manifiesto registra todo lo creado para poder revertirlo.
    - Tiene metadatos, una lista plana de objetos y una lista de
      vulnerabilidades.
    - Cada objeto tiene id, tipo, capacidad, estado, timestamp, tenantId y
      datos.
    - datos es especifico de la capacidad y debe bastar para revertir.
    - El cleanup despacha por capacidad, revierte vulnerabilidades primero y
      objetos en LIFO.
    - Verifica objectId antes de borrar para no tocar objetos ajenos.
    - Ignora preexistentes, revertidos y no-revertidos.
    - Se migra automaticamente desde v1.
    - No contiene contrasenas ni secretos.

===============================================================================