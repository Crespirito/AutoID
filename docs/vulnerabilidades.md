===============================================================================
#                           VULNERABILIDADES
===============================================================================

El subsistema de vulnerabilidades aplica modificaciones maliciosas (owners,
client secrets, roles PIM) sobre objetos que **YA EXISTEN** en el tenant. No es
una sección del escenario: es una entidad de primera clase con su propio
flujo, su propio catálogo y sus propios estados en el manifiesto.

Este documento explica qué son, qué tipos hay, cómo se aplican, cómo se
revierte y cómo encajan en la arquitectura modular.


-------------------------------------------------------------------------------
# 1. QUÉ ES UNA VULNERABILIDAD (Y QUÉ NO)
-------------------------------------------------------------------------------

## ES:
 - Una modificación maliciosa sobre un objeto preexistente.
 - Un cambio que se puede revertir de forma controlada.
 - Un elemento que se registra en $Manifiesto.vulnerabilidades.

## NO ES:
 - Un objeto que se crea desde cero (eso es un escenario).
 - Una sección del escenario JSON.
 - Un requisito para crear el laboratorio: puedes crear el escenario sin
      vulnerabilidades y aplicarlas después.

## DIFERENCIA CON EL ESCENARIO:

    ESCENARIO                            VULNERABILIDAD
    -----------------------------------  -----------------------------------
    Crea objetos desde cero.             Modifica objetos existentes.
    Vive en $Manifiesto.objetos.         Vive en $Manifiesto.vulnerabilidades.
    Se aplica con creauto/creamanual.    Se aplica con menu.ps1 [5].
    Orden: primero.                      Orden: después del escenario.
    Reversión: LIFO.                     Reversión: PRIMERO, antes que
                                         los objetos.


-------------------------------------------------------------------------------
# 2. TIPOS DISPONIBLES
-------------------------------------------------------------------------------

Cada tipo declara su nivel mínimo, sus dependencias, cómo se valida, cómo se
aplica, cómo se revierte y qué parámetros pide. La tabla vive en $script:VulnTipos en cap_vulnerabilidades.ps1.

## 2.1. ServicePrincipalOwner (Free)
---------------------------------
    Añade un usuario como owner de un Service Principal.

    Parámetros:
        usuario     UPN del usuario owner.
        aplicacion  DisplayName de la aplicación.

    Efecto: New-MgServicePrincipalOwnerByRef.
    Reversión: Remove-MgServicePrincipalOwnerByRef.
    Idempotente: si el usuario ya es owner, se marca 'reutilizado'.

## 2.2. GroupOwner (Free)
----------------------
    Añade un usuario como owner de un grupo de seguridad.

    Parámetros:
        usuario     UPN del usuario owner.
        grupo       DisplayName del grupo.

    Efecto: New-MgGroupOwnerByRef.
    Reversión: Remove-MgGroupOwnerByRef.
    Idempotente: si el usuario ya es owner, se marca 'reutilizado'.

## 2.3. ApplicationSecret (Free)
-----------------------------
    Añade un client secret a una aplicación.

    Parámetros:
        aplicacion  DisplayName de la aplicación.
        dias        Días hasta expirar (1-730, por defecto 365).

    Efecto: Add-MgApplicationPassword.
    Reversión: Remove-MgApplicationPassword por keyId.
    Idempotente: si ya existe un secreto con el mismo displayName, se marca
    'reutilizado'. El displayName se deriva del nombre de la vulnerabilidad:
    "Vuln secret - <nombre>".

  **SEGURIDAD:** el SecretText solo se devuelve en la creación. Se muestra
    UNA SOLA VEZ en un bloque unificado. No se guarda en el manifiesto.

## 2.4. PimEligibleRole (P2)
-------------------------
    Asigna un rol de directorio como elegible (no activo) vía PIM.

    Parámetros:
        usuario     UPN del usuario.
        rol         Nombre del rol (ej. Global Administrator).
        duracion    Duración ISO 8601 (por defecto PT8H).

  Efecto: **DELEGA** en cap_pim.ps1 (P2). Si cap_pim.ps1 no está registrada
    (carpeta p2 desactivada), el tipo no se ofrece.
  Reversión: **DELEGA** en cap_pim.Revertir. Adicionalmente, PreRevertir
    cancela la RoleAssignmentScheduleRequest activa si la hay (para que el
    rol no quede activo tras el cleanup).


-------------------------------------------------------------------------------
# 3. NIVEL EFECTIVO
-------------------------------------------------------------------------------

### El nivel efectivo es el mínimo entre:
 - Nivel configurado en menu_config.json (menu.ps1 [N]).
 - Nivel real del tenant (SKUs contratados: AAD_PREMIUM, AAD_PREMIUM_P2).

### Se calcula con Get-LabNivelEfectivo en lib_niveles.ps1.

    CONFIGURADO   TENANT   EFECTIVO   QUÉ SE OFRECE
    ------------  -------  ---------  -------------------------------------
    Free          P2       Free       Solo tipos Free.
    P1            P2       P1         Tipos Free + P1 (ninguno hoy).
    P2            P1       P1         Solo tipos Free (el tenant no
                                      soporta P2).
    P2            P2       P2         Todos.

### Se aplica en:
 - TestDisponible: devuelve TiposDisponibles.
 - PreguntarUI: muestra los tipos agrupados por nivel; los no disponibles
      aparecen deshabilitados con el motivo.
 - ValidarDef: rechaza tipos que superan el nivel efectivo.
 - Crear: omite tipos que superan el nivel efectivo.

Si falla la consulta de SKUs, el nivel real es Free. El efectivo cae a Free.
Es conservador a propósito.


-------------------------------------------------------------------------------
# 4. CÓMO SE CREAN: FLUJO [5]
-------------------------------------------------------------------------------

Desde menu.ps1, opción [5] Crear vulnerabilidad.

## 4.1. Pantalla única
-------------------
  - Listado plano de tipos agrupados por nivel:
        --- Free ---
          [1] ServicePrincipalOwner
          [2] GroupOwner
          [3] ApplicationSecret
        --- P2 ---
          [!] PimEligibleRole  (requiere P2 (efectivo: P1))
  - Los tipos no disponibles aparecen deshabilitados con el motivo.
  - Opciones:
        [número]  Elegir tipo y definir manualmente.
        [C]       Cargar del catálogo por nombre.
        [0]       Cancelar.

## 4.2. Definición manual
----------------------
  - Se elige el tipo.
  - Se pide el nombre de la vulnerabilidad.
  - Se piden los parámetros con defaults entre corchetes (Enter mantiene).
  - Se valida localmente con $script:VulnTipos[tipo].Validar.

## 4.3. Carga desde el catálogo (A + B)
------------------------------------
  - Se listan las vulnerabilidades de escenarios/vulnerab/*.json cuyo
      tipo esté disponible en el nivel efectivo.
  - Se agrupan por nivel del tipo.
  - Al elegir una:
      * Se muestra el detalle (nombre, tipo, descripción, parámetros).
      * Se pregunta si quieres cambiar el nombre (Enter mantiene el del
          catálogo).
      * Se pregunta si quieres modificar parámetros (SI/N, por defecto N).
      * Si SI, se piden uno a uno con el valor del catálogo como default.
  - Se valida localmente.

## 4.4. Aplicación
---------------
  - menu.ps1 llama a ValidarDef (validación completa).
  - Se muestra un resumen y se pide confirmación.
  - Se construye el snapshot pre-lab.
  - Se llama a Crear.
  - Cada resultado se registra con Add-LabManifiestoVulnerabilidad, con
      -Capacidad <capacidadAplicadora> ('Vulnerabilidades' o 'Pim').
  - Se guarda el manifiesto.

## 4.5. Secretos
-------------
  - Los client secrets se muestran UNA SOLA VEZ en un bloque unificado
      al final de Crear.
  - No se guardan en el manifiesto. Solo el keyId, para poder revocarlos.
  - Si pierdes un secreto, tienes que crear una vulnerabilidad nueva.


-------------------------------------------------------------------------------
# 5. CÓMO SE VEN: FLUJO [6]
-------------------------------------------------------------------------------

Desde menu.ps1, opción [6] Ver vulnerabilidades del manifiesto.

  - Lista $Manifiesto.vulnerabilidades con:
      * Nombre.
      * Tipo.
      * Capacidad aplicadora.
      * Estado (con color: amarillo aplicada, verde revertida, rojo
          fallida/no-revertida, gris preexistente/omitida).
      * Timestamp.
  - Al final: total y pendientes de revertir.
  - Para revertirlas: [3] Limpiar entorno.


-------------------------------------------------------------------------------
# 6. CÓMO SE REVIERTEN
-------------------------------------------------------------------------------

Desde clean_up.ps1, que llama a Invoke-LabReversion en lib_creadores.ps1.

## 6.1. Orden
----------
  1. Vulnerabilidades PRIMERO, una a una.
  2. Objetos después, en LIFO.
    El orden importa: si una vulnerabilidad añadió un owner a un grupo,
    quitar el owner antes de borrar el grupo evita errores.

## 6.2. Por cada vulnerabilidad
----------------------------
 - Si el estado es ignorado (preexistente, revertida, no-revertida,
       omitida), se salta.
 - Se busca la capacidad aplicadora (v.capacidad).
 - Se valida que v.datos exista.
 - Se verifica el objectId del objeto afectado:
 - Test-LabVulnerabilidadCoincideConManifiesto.
 - Si el objeto afectado se borró y recreó, se marca no-revertida.
 - Se llama a PreRevertir de la capacidad si existe (para PIM:
       cancelar la asignación activa).
 - Se llama a Revertir de la capacidad.
 - Según el resultado:
      1. true   -> estado = revertida.
      2. false  -> estado = fallida.
      3. throw  -> estado = fallida.

## 6.3. Idempotencia
-----------------
    Todos los Revertir son idempotentes: si el objeto ya no existe o la
    relación ya se ha quitado, devuelven true sin error.


-------------------------------------------------------------------------------
# 7. ESTADOS EN EL MANIFIESTO
-------------------------------------------------------------------------------

Estados posibles de una vulnerabilidad (en $Manifiesto.vulnerabilidades):

    aplicada        Aplicada y pendiente de revertir.
    preexistente    No se aplicó porque el objeto afectado era preexistente
                    (estaba en el snapshot pre-lab). No se toca.
    fallida         Intento de aplicación fallido. Se puede reintentar la
                    reversión.
    revertida       Ya revertida.
    no-revertida    No se pudo revertir (capacidad no disponible, objectId
                    distinto, etc.).
    omitida         Omitida por configuración (exclusión).

Estados que el cleanup intenta revertir:
    aplicada, fallida.

Estados que el cleanup ignora:
    preexistente, revertida, no-revertida, omitida.

Las listas viven en lib_manifiesto.ps1:
    $script:LabEstadosReversiblesVulnerabilidad
    $script:LabEstadosIgnoradosVulnerabilidad


-------------------------------------------------------------------------------
# 8. SEGURIDAD DE PREEXISTENTES
-------------------------------------------------------------------------------

Antes de aplicar una vulnerabilidad, se consulta el snapshot pre-lab. Si el
objeto afectado ya existía antes del laboratorio, no se toca:

    - SP preexistente     -> ServicePrincipalOwner no se aplica.
    - Grupo preexistente  -> GroupOwner no se aplica.
    - App preexistente    -> ApplicationSecret no se aplica.
    - Usuario preexistente-> PimEligibleRole no se aplica.

En ese caso, la vulnerabilidad se registra con estadoDetalle = 'preexistente'
y en el manifiesto queda como 'preexistente'. El cleanup la ignora.

Esto evita modificar objetos que no son del laboratorio.


-------------------------------------------------------------------------------
# 9. OBTENERCLAVES Y PREREVERTIR
-------------------------------------------------------------------------------

## 9.1. ObtenerClaves
------------------
    Scriptblock opcional del contrato de capacidad. Devuelve las claves de
    los objetos que la capacidad va a tocar, para que el snapshot pre-lab
    pueda construirse por capacidad.

    En cap_vulnerabilidades.ps1 devuelve:
        ServicePrincipalOwner  ->  app:<displayName>, user:<upn>
        GroupOwner             ->  group:<displayName>, user:<upn>
        ApplicationSecret      ->  app:<displayName>
        PimEligibleRole        ->  user:<upn>

    Lo usa lib_creadores.ps1 (Get-LabCapacidadClaves) para construir el
    snapshot. Las claves son informativas; el snapshot real lo construye
    New-LabSnapshotPreLab consultando el tenant.

## 9.2. PreRevertir
----------------
    Scriptblock opcional del contrato de capacidad. Se llama ANTES de
    Revertir, para deshacer algo que no es un borrado directo.

    En cap_vulnerabilidades.ps1:
        PimEligibleRole  ->  cancela la RoleAssignmentScheduleRequest activa
                             si la hay, antes de que cap_pim.Revertir cancele
                             la elegible.

    Lo usa lib_creadores.ps1 en Invoke-LabReversion, tanto para objetos como
    para vulnerabilidades.


-------------------------------------------------------------------------------
# 10. CATÁLOGO DE VULNERABILIDADES
-------------------------------------------------------------------------------

El catálogo vive en escenarios/vulnerab/*.json. Cada archivo declara una
vulnerabilidad por nombre:

    {
      "nombre": "escenarioej1_sp_owner",
      "descripcion": "Owner de SP para el escenario 1.",
      "tipo": "ServicePrincipalOwner",
      "parametros": {
        "usuario": "lucia.g@{tenant}",
        "aplicacion": "Panel de Analisis Comercial"
      },
      "requiereLicencia": "Free"
    }

Se genera con generar_biblioteca.ps1. NO forma parte del escenario.

Se usa desde cap_vulnerabilidades.ps1 [C] para cargar una vulnerabilidad por
nombre y, opcionalmente, sobrescribir sus parámetros (A + B).

Funciones implicadas:
    - Get-LabVulnerabilidadesDisponibles (lista nombres).
    - Get-LabVulnerabilidad (carga una por nombre).

El filtrado por nivel efectivo se hace en Read-VulnDesdeCatalogo: los tipos
no disponibles se muestran deshabilitados con el motivo.


-------------------------------------------------------------------------------
# 11. DATOS POR TIPO EN EL MANIFIESTO
-------------------------------------------------------------------------------

El campo datos de cada vulnerabilidad contiene lo necesario para revertir.
Además de los campos específicos, todas incluyen:

    capacidadAplicadora    'Vulnerabilidades' o 'Pim'.
    tipoVulnerabilidad     El tipo (ServicePrincipalOwner, etc.).
    objetoAfectadoObjectId objectId del objeto afectado (para verificación).

Datos específicos por tipo:

    ServicePrincipalOwner
        servicePrincipalId, directoryObjectId, aplicacion, usuario.

    GroupOwner
        groupId, directoryObjectId, grupo, usuario.

    ApplicationSecret
        applicationId, keyId, aplicacion, displayName.

    PimEligibleRole
        userId, roleDefinitionId, scheduleRequestId, upn, rol.


-------------------------------------------------------------------------------
# 12. AÑADIR UN TIPO NUEVO
-------------------------------------------------------------------------------

  1. Añadir una entrada en $script:VulnTipos de cap_vulnerabilidades.ps1 con:
      - Nivel ('Free', 'P1', 'P2').
      - DependeDe (informativo).
      - Validar (scriptblock).
      - Aplicar (scriptblock).
      - Revertir (scriptblock).
      - Describir (scriptblock).
      - ParametrosUI (array de { Nombre, Prompt, Default }).
      - PreRevertir (opcional).
  2. Implementar las funciones auxiliares Invoke-Vuln<NuevoTipo> e
       Invoke-RevertirVuln<NuevoTipo>.
  3. (Opcional) Añadir el tipo a ObtenerClaves si toca objetos con claves
       específicas.

### No hay que tocar:
   - lib_caps.ps1.
   - menu.ps1 (PreguntarUI se adapta automáticamente).
   - lib_creadores.ps1 (usa la dispatch table).
   - lib_manifiesto.ps1 (Add-LabManifiestoVulnerabilidad acepta -Capacidad).


-------------------------------------------------------------------------------
# 13. QUITAR UN TIPO
-------------------------------------------------------------------------------

  - Borrar la entrada de $script:VulnTipos.
  - Borrar las funciones auxiliares.
  - Si quedan vulnerabilidades del tipo en algún manifiesto, el cleanup
      las marcará como no-revertidas con aviso. El operador debe revertirlas
      a mano si quiere limpiarlas.

Para desactivar solo el tipo PimEligibleRole sin tocar código, renombrar la
carpeta p2/ a p2.disabled/. Entonces cap_pim.ps1 no se registra y el tipo
no se ofrece (se muestra deshabilitado con motivo).


-------------------------------------------------------------------------------
# 14. RESUMEN
-------------------------------------------------------------------------------

  - Vulnerabilidad = modificación maliciosa sobre un objeto existente.
  - Vive en $Manifiesto.vulnerabilidades, no en objetos.
  - Se crea desde menu.ps1 [5], se ve desde [6].
  - Depende del nivel efectivo (min config, tenant).
  - Catálogo en escenarios/vulnerab/*.json, con A + B.
  - Tipos no disponibles se muestran deshabilitados con motivo.
  - PimEligibleRole delega en cap_pim.ps1.
  - Secretos se muestran UNA SOLA VEZ.
  - Reversión: primero vulnerabilidades, luego objetos (LIFO).
  - Verificación de objectId del objeto afectado.
  - PreRevertir para deshacer efectos colaterales (PIM activo).
  - Estados: aplicada, preexistente, fallida, revertida, no-revertida,
      omitida.
  - Añadir un tipo = añadir entrada en $script:VulnTipos + 2 funciones.
      No se toca el núcleo.

===============================================================================