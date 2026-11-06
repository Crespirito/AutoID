Se modulariza totalmente el programa. 
Se cambia la funcionalidad del programa, dando la opcion de hacerlo según el nivel de licencia en Azure Entra ID.
Se añaden nuevas funciones, descritas en el README.md.
Las contraseñas autogeneradas siguen siendo creadas por la semilla.
Se añade nuevo sistema de seguridad en Entra ID. Se comporueba que le objeto no exista, y después se comprueba que el objeto ha sido creado en ese escenario.
- Se añade un snapshot de lo existente.
- Consulta antes de crear el prelab para no sobreescribir el objeto.si
- Avisa de la existencia del objeto a borrar.
- Se añade el estado "preexistente" a los estados posibles.
- Estado reversibles, preexistentes e ignorados.
- Se añade "obtenerclaves" como campo opcional. 
- El campo de acceso condicional está deshabilitado por defecto.

mapa del programa

<raíz>/
│
├── menu.ps1
├── creauto.ps1
├── creamanual.ps1
├── clean_up.ps1
├── generar_biblioteca.ps1
├── README.md
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
    └── manifiesto.md

Generar biblioteca sigue estando apartado de los demás, para seguir mejorando el programa sin tocar lo robusto de este
