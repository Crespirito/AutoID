Se modulariza totalmente el programa. 
Se cambia la funcionalidad del programa, dando la opción de hacerlo según el nivel de licencia en Azure Entra ID.
Se añaden nuevas funciones, descritas en el README.md.
Las contraseñas autogeneradas siguen siendo creadas por la semilla.

VULNERABILIDADES (ENTIDAD DE PRIMERA CLASE):
- Se separan del escenario. Ahora son una entidad independiente que se aplica sobre objetos existentes.
- Se crean desde el menú [5] y se consultan desde [6].
- El menú de creación es único y compacto: lista los tipos por nivel (Free, P1, P2) y muestra deshabilitados (con motivo) los que no soporta tu licencia.
- Dependen del "nivel efectivo": el mínimo entre el nivel configurado y lo que el tenant soporta realmente.
- Integran un catálogo (A+B): puedes aplicar una vulnerabilidad del catálogo tal cual, o cargarla como plantilla para sobrescribir sus parámetros.
- PimEligibleRole delega la lógica en cap_pim.ps1 para no duplicar código.
- Los tipos están en una tabla de despacho ($script:VulnTipos). Añadir uno nuevo ya no requiere tocar 6 sitios.

SISTEMA DE SEGURIDAD Y BUGS ARREGLADOS:
- Se comprueba que el objeto no exista antes de crearlo (snapshot pre-lab).
- El cleanup verifica el objectId antes de borrar, para no tocar objetos ajenos.
- Se añade el estado "preexistente" a los estados posibles.
- Se diferencian estados reversibles, preexistentes e ignorados.
- Se implementan "ObtenerClaves" (para snapshot) y "PreRevertir" (para deshacer efectos antes del borrado, como cancelar un PIM activo).
- El campo de acceso condicional está deshabilitado por defecto.
- Las vulnerabilidades ahora se registran en $Manifiesto.vulnerabilidades, no mezcladas con objetos. Se incluye migración automática de manifiestos v2 a v2.1.
- El CSV del cleanup ya no mezcla tipos con prefijos.
- Se arregla el flag -SinVulnerabilidad (eliminado) y se sustituye por la lógica del menú [5].
- Se arregla el bug del generador que creaba la clave 'vulnerabilidad' en singular, lo que hacía que se perdieran en la normalización.
- Se elimina el ruido en las secciones del escenario (ya no se crea una sección vacía 'Vulnerabilidades').

MAPA DEL PROGRAMA

<raíz>/
│
├── menu.ps1
├── creauto.ps1
├── creamanual.ps1
├── clean_up.ps1
├── generar_biblioteca.ps1
├── README.md
├── README.txt
├── .gitignore
│
├── lib_ui.ps1
├── lib_graph.ps1
├── lib_config.ps1
├── lib_manifiesto.ps1
├── lib_escenarios.ps1
├── lib_niveles.ps1
├── lib_caps.ps1
├── lib_creadores.ps1
│
├── lib_caps/
│   ├── free/
│   │   ├── cap_usuarios.ps1
│   │   ├── cap_grupos.ps1
│   │   ├── cap_aplicaciones.ps1
│   │   ├── cap_app_roles.ps1
│   │   ├── cap_credenciales_app.ps1
│   │   ├── cap_permisos_api.ps1
│   │   ├── cap_invitados.ps1
│   │   ├── cap_relaciones.ps1
│   │   └── cap_vulnerabilidades.ps1
│   ├── p1/
│   │   ├── cap_administrative_units.ps1
│   │   ├── cap_grupos_dinamicos.ps1
│   │   ├── cap_grupos_role_assignable.ps1
│   │   ├── cap_licencias.ps1
│   │   └── cap_acceso_condicional.ps1
│   └── p2/
│       ├── cap_pim.ps1
│       └── cap_metodos_auth.ps1
│
├── escenarios/
│   ├── escenario/
│   ├── vulnerab/
│   ├── plantillas/
│   └── .secrets/
│
├── schema/
│   └── escenario.schema.json
│
└── docs/
    ├── capacidades.md
    ├── escenarios.md
    ├── manifiesto.md
    └── vulnerabilidades.md

Generar biblioteca sigue estando apartado de los demás, para seguir mejorando el programa sin tocar lo robusto de este.