# Gestor de Entornos de Laboratorio - Entra ID (Free)

Herramienta en PowerShell para crear, gestionar y limpiar entornos de laboratorio en Microsoft Entra ID (tenant Free). Permite montar escenarios con usuarios, grupos, aplicaciones y vulnerabilidades controladas, y eliminarlos después de forma ordenada.

## Requisitos previos

### 1. PowerShell 7 (recomendado)

El proyecto está pensado para ejecutarse en **PowerShell 7** (`pwsh.exe`). Aunque los scripts declaran `#Requires -Version 5.1` y funcionan en Windows PowerShell 5.1, Microsoft ha iniciado la retirada del soporte de 5.1 en el SDK de Graph, y PowerShell 7 recibe actualizaciones y mejoras de rendimiento [citation:1][citation:5].

**Comprobar qué versión tienes:**

$PSVersionTable.PSVersion

**Instalar PowerShell 7 (si no lo tienes):**

winget install Microsoft.PowerShell

---------------------------------------------------------------------------------------------------
## Requisitos

- Windows PowerShell 5.1 o superior.
- Módulo `Microsoft.Graph` (el script lo instala si falta).
- Una cuenta con permisos suficientes en el tenant (idealmente Global Administrator para el laboratorio).
- Sesión interactiva: el script abre el navegador para autenticarte.

# Estructura del proyecto

menu.ps1 Punto de entrada. Gestiona sesión, config y delega.

creacion_automatica.ps1 Crea un escenario predefinido desde JSON.

creacion_personalizada.ps1 Crea objetos uno a uno de forma interactiva.

clean_up.ps1 Elimina todo lo registrado en el manifiesto.

generar_biblioteca.ps1 Genera escenarios y vulnerabilidades de ejemplo.

lib_ui.ps1 Helpers de consola (colores, pausas, cabeceras).

lib_graph.ps1 Conexión y gestión de la sesión de Graph.

lib_config.ps1 Configuración persistente (menu_config.json).

lib_manifiesto.ps1 Lectura/escritura del manifiesto del laboratorio.

lib_escenarios.ps1 Carga de escenarios y aplicación de vulnerabilidades.


escenarios/

escenario/ Un .json por escenario disponible.

vulnerab/ Un .json por vulnerabilidad disponible.

manifiesto_lab.json Registro de todo lo creado (se genera al crear).

menu_config.json Configuración del menú (se genera al arrancar).

log_*.csv Log de cada ejecución.


## AL ARRANCAR:

1.Carga las librerías.

2.Conecta a Microsoft Graph (abre el navegador si no hay sesión).

3.Muestra el estado actual: sesión, configuración y manifiesto pendiente.

4.Presenta el menú principal.

Si la conexión falla, el menú arranca igualmente y puedes reconectar con la opción [C].


## MENÚ PRINCIPAL.

[1] Creación automática       Crea un escenario predefinido desde JSON.

[2] Creación personalizada    Crea usuarios, grupos y apps uno a uno.

[3] Limpiar entorno           Elimina todo lo registrado en el manifiesto.

[4] Ver manifiesto            Muestra el contenido del manifiesto actual.

[C] Gestionar sesión          Reconectar o cerrar la sesión de Graph.

[V] Alternar Verbose          Activa/desactiva salida detallada.

[R] Resetear configuración    Vuelve a los valores por defecto.

[I] Info sobre tenant Free    Qué se puede y qué no se puede hacer en Free.


[0] Salir                     Cierra sesión y termina.


## FLUJO 1: CREACIÓN AUTOMÁTICA.
### Crea un escenario completo a partir de un JSON en escenarios/escenario/.

1.Elige [1] en el menú.

2.Selecciona un escenario de la lista.

3.El script muestra un resumen: usuarios, grupos, apps, relaciones y vulnerabilidad declarada.

4.Confirma con SI.

5.El script crea todos los objetos en Entra ID y guarda el manifiesto.

6.Si el escenario declara una vulnerabilidad, te pregunta si aplicarla.

7.Al final muestra las credenciales de los usuarios creados y la ruta del log.

**Modo simulación: puedes ejecutar el script con -DryRun para ver el resumen sin crear nada:**

.\creacion_automatica.ps1 -Escenario escenarioej1 -DryRun


##FLUJO 2: CREACIÓN PERSONALIZADA.

### Construye el escenario objeto a objeto.

1.Elige [2] en el menú.

2.Añade elementos con las opciones [1]–[3] (usuario, grupo, app).

3.Añade relaciones con [4]–[5] (miembro a grupo, owner de SP).

4.Revisa lo creado con [L].

5.Guarda con [G] o sal sin guardar con [S].

Al guardar, el manifiesto queda listo para que clean_up.ps1 lo procese.


## FLUJO 3: LIMPIEZA.

### Elimina todo lo registrado en el manifiesto en el orden correcto para romper dependencias:

1.Revierte vulnerabilidades aplicadas (owners, credenciales, PIM).

2.Elimina aplicaciones y service principals.

3.Elimina grupos (vaciando miembros y owners primero).

4.Elimina usuarios.

5.Renombra el manifiesto como procesado.

Desde el menú: elige [3].

Desde línea de comandos:

.\clean_up.ps1                # Pide confirmación
.\clean_up.ps1 -Forzar        # Sin confirmación

## EL MANIFIESTO

manifiesto_lab.json registra todo lo creado para poder eliminarlo después:

{
  "Fecha": "2026-10-27T10:00:00",
  "TenantId": "...",
  "TenantDomain": "midominio.com",
  "Usuarios": ["user1@midominio.com"],
  "Grupos": ["Grupo A"],
  "Aplicaciones": ["App A"],
  "ServicePrincipals": ["<id>"],
  "Vulnerabilidades": [
    {
      "nombre": "...",
      "tipo": "...",
      "objetosAfectados": [...]
    }
  ]
}

Tras un cleanup exitoso se renombra a manifiesto_lab_procesado_<timestamp>.json.

## CONFIGURACIÓN

menu_config.json guarda opciones persistentes del menú:

{
  "Verbose": false
}

Si el fichero no existe o es inválido, se usan los valores por defecto.

## LOGS

Cada ejecución genera un CSV en la carpeta del script:

- log_yyyyMMdd_HHmmss.csv (creación automática).

- log_personalizada_yyyyMMdd_HHmmss.csv (creación personalizada).

- log_cleanup_yyyyMMdd_HHmmss.csv (limpieza).

Columnas: Timestamp, Categoria (Info/Warning/Error), Mensaje, Detalle.


## LIMITACIONES EN TENANT FREE

### Disponible:

- Crear usuarios, grupos de seguridad, aplicaciones y service principals.

- Asignar miembros a grupos.

- Asignar owners a service principals.

- Añadir credenciales a aplicaciones.

### No disponible (requiere P1/P2):

- Asignación de roles de directorio.

- Grupos con asignación de roles.

- Grupos dinámicos.

- Acceso condicional avanzado.

- Gestión de PIM.

El script lo avisa en la opción [I] del menú.


## SOLUCIÓN DE PROBLEMAS

**"No hay sesión de Graph activa"**
Ejecuta desde menu.ps1, no los scripts hijos directamente.

**"No se encuentra el manifiesto"**
Crea primero un escenario con [1] o [2].

**"Faltan módulos de Microsoft.Graph"**
El script los instala automáticamente al conectar. Si falla, instálalos a mano:

Install-Module Microsoft.Graph.Authentication -Scope CurrentUser


**"La conexión se ejecutó pero no hay sesión válida"**
Cierra la sesión con [C] y vuelve a conectar. Si persiste, prueba con -SoloFree desde Connect-LabGraph.

**El cleanup falla parcialmente:**
Revisa el CSV del log. Los objetos no eliminados quedan registrados como Warning o Error. Vuelve a lanzar el cleanup: solo procesará lo que siga en el manifiesto.


