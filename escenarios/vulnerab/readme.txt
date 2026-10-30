CREACIÓN DE VULNERABILIDADES
============================

Modelo
------
Una vulnerabilidad es un fichero .json que describe una configuración insegura a
inyectar en el entorno creado por un escenario. Es dato, no código: añadir una
vulnerabilidad de un tipo ya soportado no requiere tocar los scripts. Añadir un
tipo nuevo sí requiere código, pero está acotado a lib_escenarios.ps1.

Cada vulnerabilidad declara:
- un tipo (qué configuración insegura se aplica),
- unos parámetros (sobre qué objetos del escenario se aplica),
- metadatos opcionales (descripción, licencia requerida).

El escenario la referencia por nombre en su campo "vulnerabilidad". La creación
automática la carga, pregunta si aplicarla y, si se acepta, la ejecuta. El
resultado (objetos afectados) se registra en el manifiesto para que clean_up.ps1
pueda revertirla.


Layout
------
escenarios/
├── escenario/     # un .json por escenario
└── vulnerab/      # un .json por vulnerabilidad; el BaseName es el identificador

El identificador de la vulnerabilidad es el nombre del fichero sin extensión. Un
escenario la referencia con "vulnerabilidad": "<BaseName>". Por ejemplo, si el
fichero es escenarios/vulnerab/sp_owner.json, el escenario debe declarar
"vulnerabilidad": "sp_owner".

Las rutas se resuelven en lib_escenarios.ps1 a partir de $PSScriptRoot.


Contrato de una vulnerabilidad
------------------------------
Get-LabVulnerabilidad valida y normaliza el JSON. Requisitos:

- tipo (obligatorio): debe coincidir exactamente con uno de los casos del switch
  de Invoke-LabVulnerabilidad en lib_escenarios.ps1. Tipos soportados:
    * ServicePrincipalOwner
    * ApplicationSecret
    * GroupOwner
    * PimEligibleRole
- parametros (obligatorio): objeto con los campos que el aplicador de ese tipo
  espera. Las claves deben coincidir exactamente con las del escenario:
    * para usuarios: el upn tal cual aparece en el escenario, con {tenant}
      incluido (por ejemplo, "pepito.sl@{tenant}"),
    * para grupos y aplicaciones: el displayName exacto.
  Los aplicadores resuelven estas claves contra el $Contexto que construye
  creacion_automatica.ps1 (diccionarios Usuarios, Grupos y Aplicaciones).
- descripcion (opcional): texto libre.
- requiereLicencia (opcional, informativo): "Free", "P1" o "P2". No bloquea la
  ejecución; sirve para documentar si el tipo necesita licencia superior (por
  ejemplo, PIM requiere P2).


Tipos soportados y sus parámetros
---------------------------------
Cada tipo tiene un aplicador en lib_escenarios.ps1 que define exactamente qué
claves de parametros espera. Hoy:

ServicePrincipalOwner
  Aplica: asigna un usuario como propietario de un service principal.
  Parametros:
    - usuario:      upn del usuario (con {tenant}).
    - aplicacion:   displayName de la aplicación del escenario.
  Reversión: Remove-MgServicePrincipalOwnerByRef.

ApplicationSecret
  Aplica: añade una credencial (secret) a una aplicación.
  Parametros:
    - aplicacion:   displayName de la aplicación.
    - displayName:  (opcional) nombre de la credencial. Por defecto "Lab credential".
  Reversión: Remove-MgApplicationPassword por KeyId.

GroupOwner
  Aplica: asigna un usuario como propietario de un grupo.
  Parametros:
    - usuario:      upn del usuario (con {tenant}).
    - grupo:        displayName del grupo.
  Reversión: Remove-MgGroupOwnerByRef.

PimEligibleRole
  Aplica: asigna un rol de directorio como elegible (PIM) a un usuario.
  Parametros:
    - usuario:      upn del usuario (con {tenant}).
    - rol:          displayName del rol (por ejemplo, "Global Administrator").
    - duracion:     (opcional) duración ISO 8601. Por defecto "PT8H".
  Requiere: licencia P2 y módulo Microsoft.Graph.Identity.Governance.
  Reversión: adminRemove sobre el schedule de elegibilidad.


Cómo se crea una vulnerabilidad nueva (tipo existente)
------------------------------------------------------
1. Crea un fichero .json en escenarios/vulnerab/. El BaseName será el identificador.
2. Incluye tipo y parametros con las claves que ese tipo espera (ver tabla arriba).
3. Opcionalmente añade descripcion y requiereLicencia.
4. Referénciala desde un escenario con "vulnerabilidad": "<BaseName>".
5. Ejecuta creacion_automatica.ps1. Si el escenario la declara, preguntará si
   aplicarla. Responde SI para inyectarla; N o -SinVulnerabilidad para omitirla.

No hay que tocar código. La vulnerabilidad aparece automáticamente porque
Get-LabVulnerabilidad la carga por nombre desde escenarios/vulnerab/.


Cómo se crea un tipo nuevo (requiere código)
--------------------------------------------
Un "tipo" es un aplicador en lib_escenarios.ps1. Añadir uno nuevo implica:

1. Escribir una función Invoke-Vulnerabilidad<TipoNuevo> con la firma:
     param($Parametros, $Contexto)
   - $Parametros es el objeto "parametros" del JSON.
   - $Contexto es el hashtable con TenantDomain, Usuarios, Grupos, Aplicaciones,
     Manifiesto.
   - Debe devolver un array de objetos afectados. Cada objeto debe contener los
     IDs necesarios para que clean_up.ps1 pueda revertir la operación (por
     ejemplo, servicePrincipalId y directoryObjectId, o applicationId y keyId).
2. Añadir un case en el switch de Invoke-LabVulnerabilidad:
     "<TipoNuevo>" { return (Invoke-Vulnerabilidad<TipoNuevo> -Parametros ... -Contexto ...) }
3. Añadir un case equivalente en el switch de reversión de clean_up.ps1, para que
   la fase de reversión sepa deshacerla antes de borrar los objetos.
4. Crear el .json correspondiente en escenarios/vulnerab/ y referenciarlo desde un
   escenario.

Convención: el nombre del tipo en el JSON debe coincidir exactamente con el case
del switch (sensible a mayúsculas).


Qué registra el manifiesto
--------------------------
Por cada vulnerabilidad aplicada, creacion_automatica.ps1 añade una entrada a
manifiesto.Vulnerabilidades con:

  - nombre:          BaseName del fichero de vulnerabilidad.
  - tipo:            el tipo del JSON.
  - parametros:      los parámetros tal cual venían en el JSON.
  - objetosAfectados: array devuelto por el aplicador, con los IDs necesarios
                      para revertir.

clean_up.ps1 lee esa lista y revierte cada entrada antes de borrar apps/SPs,
grupos y usuarios. Si el manifiesto no tiene Vulnerabilidades (manifiestos
antiguos), la fase se salta.


Activación y omisión
--------------------
- Interactivo: si el escenario declara vulnerabilidad, creacion_automatica.ps1
  pregunta "¿Aplicar la vulnerabilidad? (SI/N)". Solo SI la aplica.
- Forzado benigno: -SinVulnerabilidad omite la pregunta y no la aplica aunque el
  escenario la declare. Útil para comparar el grafo con y sin vulnerabilidad
  sobre el mismo escenario.
- Escenario sin vulnerabilidad: si no declara vulnerabilidad, se crea un entorno
  benigno sin preguntar.


Buenas prácticas al escribir una vulnerabilidad
-----------------------------------------------
- Usa {tenant} en las claves de usuario para que el JSON sea portable entre
  tenants.
- Las claves de parametros deben coincidir literalmente con el upn o el
  displayName del escenario. Si no coinciden, el aplicador lanza un error claro
  ("Usuario 'X' no encontrado en el contexto del escenario").
- El aplicador debe ser idempotente siempre que sea posible: comprobar si la
  relación ya existe antes de crearla, para que reejecutar no rompa.
- Devuelve siempre objetosAfectados con IDs suficientes para revertir. Si un tipo
  no se puede revertir (por ejemplo, porque la API no lo permite), indícalo en
  descripcion y registra un warning en la reversión.
- Documenta requiereLicencia aunque no bloquee la ejecución: ayuda a saber qué
  tenant necesitas para probar el escenario.
- Para tipos que requieren módulos adicionales (por ejemplo,
  Microsoft.Graph.Identity.Governance para PIM), asegúrate de que el módulo está
  instalado o captura el error y regístralo como warning.


Resumen rápido
--------------
  Quiero...                                       | ¿Código? | Dónde
  ------------------------------------------------|----------|-------------------------------------
  Añadir vulnerabilidad de un tipo existente      | No       | escenarios/vulnerab/<nombre>.json
  Referenciarla desde un escenario                | No       | "vulnerabilidad": "<nombre>"
  Omitirla al crear                               | No       | responder N o -SinVulnerabilidad
  Añadir un tipo nuevo                            | Sí       | Invoke-Vulnerabilidad<Tipo> + case en
                                                  |          | Invoke-LabVulnerabilidad y en la reversión
                                                  |          | de clean_up.ps1
  Revertirla en cleanup                           | No       | clean_up.ps1 (automático vía manifiesto)