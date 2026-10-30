CREACIÓN DE ESCENARIOS
======================

Modelo
------
Un escenario es un fichero .json que describe de forma declarativa los objetos a
crear en Entra ID (usuarios, grupos, aplicaciones con su service principal), las
relaciones entre ellos y, opcionalmente, una vulnerabilidad a inyectar.

La creación automática es un orquestador: lee el escenario, itera sobre sus
arrays, invoca las funciones de creación y, si procede, delega la vulnerabilidad
en lib_escenarios.ps1. Añadir un escenario o una vulnerabilidad de un tipo ya
soportado no requiere tocar código.


Layout
------
escenarios/
├── escenario/     # un .json por escenario; el BaseName es el identificador
└── vulnerab/      # un .json por vulnerabilidad; el BaseName es el identificador

Las rutas se resuelven en lib_escenarios.ps1 a partir de $PSScriptRoot. El
manifiesto (manifiesto_lab.json) permanece en la raíz y no se ve afectado por
esta estructura.


Contrato de un escenario
------------------------
Get-LabEscenario valida y normaliza el JSON. Requisitos:

- Deben existir las cuatro secciones: usuarios, grupos, aplicaciones, relaciones.
  Se aceptan claves en español o inglés (usuarios/Usuarios). Cada sección se
  normaliza a array, aunque el JSON traiga un único objeto.
- vulnerabilidad es opcional. Si está presente, debe coincidir con el BaseName de
  un fichero en escenarios/vulnerab/; en caso contrario, creacion_automatica.ps1
  falla al intentar cargarla.
- descripcion es opcional e informativa.

Campos por elemento:

  Sección         | Obligatorios                                  | Opcionales
  ----------------|-----------------------------------------------|----------------------------------
  usuarios        | displayName, upn, mailNickname, password      | department, jobTitle
  grupos          | displayName                                   | description, mailNickname
  aplicaciones    | displayName                                   | description, signInAudience, redirectUris
  relaciones      | tipo + campos del tipo                        | —

- upn admite el placeholder {tenant}, que creacion_automatica.ps1 sustituye por
  el dominio verificado del tenant ($u.upn -replace '\{tenant\}', $TenantDomain).
  Úsalo siempre para que el mismo escenario funcione en cualquier tenant.
- relaciones[].tipo está soportado por un switch en creacion_automatica.ps1.
  Hoy solo existe membresia (campos usuario y grupo, referenciando upn y
  displayName respectivamente). Añadir un tipo nuevo implica añadir su caso al
  switch.


Contrato de una vulnerabilidad
------------------------------
Get-LabVulnerabilidad valida y normaliza el JSON. Requisitos:

- tipo: debe coincidir con uno de los casos del switch de Invoke-LabVulnerabilidad
  en lib_escenarios.ps1. Soportados: ServicePrincipalOwner, ApplicationSecret,
  GroupOwner, PimEligibleRole.
- parametros: objeto con los campos que el aplicador de ese tipo espera. Los
  aplicadores resuelven las referencias contra el $Contexto que construye
  creacion_automatica.ps1 (Usuarios, Grupos, Aplicaciones). Las claves deben
  coincidir exactamente con el upn del usuario (con {tenant} incluido) o el
  displayName del grupo/aplicación.
- descripcion y requiereLicencia son opcionales e informativos. requiereLicencia
  no bloquea la ejecución; sirve para documentar si el tipo necesita P1/P2 (por
  ejemplo, PIM).

El aplicador devuelve un array de objetosAfectados que creacion_automatica.ps1
registra en manifiesto.Vulnerabilidades[].objetosAfectados. clean_up.ps1 usa esos
objetos en su fase de reversión antes de borrar nada.


Activación y omisión
--------------------
- Interactivo: si el escenario declara vulnerabilidad, creacion_automatica.ps1
  pregunta "¿Aplicar la vulnerabilidad? (SI/N)". Solo SI la aplica.
- Forzado benigno: -SinVulnerabilidad omite la pregunta y no la aplica aunque el
  escenario la declare. Útil para comparar el grafo con y sin vulnerabilidad
  sobre el mismo escenario.
- Escenario sin vulnerabilidad: si no declara vulnerabilidad, se crea un entorno
  benigno sin preguntar.


Flujo de ejecución
------------------
1. menu.ps1 establece la sesión de Graph (lib_graph.ps1) e invoca
   creacion_automatica.ps1.
2. creacion_automatica.ps1 verifica sesión (no reconecta), carga
   lib_escenarios.ps1, lista escenarios/escenario/*.json y muestra el selector
   (o usa -Escenario si se pasa).
3. Get-LabEscenario valida y normaliza el escenario elegido.
4. Se crean usuarios, grupos, aplicaciones y relaciones iterando sobre los arrays.
   Las funciones New-EntraGoatUser, New-EntraGoatGroup, New-EntraGoatApplication y
   Add-EntraGoatGroupMember son idempotentes: reutilizan objetos existentes por
   upn/displayName.
5. Si hay vulnerabilidad y se acepta, Get-LabVulnerabilidad la carga e
   Invoke-LabVulnerabilidad la aplica según su tipo.
6. Se guarda el manifiesto con objetos creados y, si procede, Vulnerabilidades con
   objetosAfectados.


Extender el catálogo (solo en código)
-------------------------------------
  Quiero...                                  | ¿Código? | Dónde
  -------------------------------------------|----------|----------------------------------------
  Añadir un escenario                        | No       | escenarios/escenario/<nombre>.json
  Añadir vulnerabilidad de un tipo existente | No       | escenarios/vulnerab/<nombre>.json
  Añadir un tipo nuevo de vulnerabilidad     | Sí       | Invoke-Vulnerabilidad<Tipo> + case en
                                             |          | Invoke-LabVulnerabilidad (lib_escenarios.ps1)
  Añadir un tipo nuevo de relación           | Sí       | case en el switch de relaciones
                                             |          | (creacion_automatica.ps1)
  Añadir campos nuevos a usuarios/grupos/apps| Sí       | Parámetros de New-EntraGoat* y su lectura


Reversión
---------
clean_up.ps1 lee manifiesto.Vulnerabilidades y revierte cada entrada antes de
borrar apps/SPs, grupos y usuarios. Cada tipo tiene su case en el switch de
reversión (Remove-MgServicePrincipalOwnerByRef, Remove-MgGroupOwnerByRef,
Remove-MgApplicationPassword, adminRemove para PIM). Un tipo desconocido se
registra como warning y se omite, sin interrumpir la limpieza. Si el manifiesto no
tiene Vulnerabilidades (manifiestos antiguos), la fase se salta.