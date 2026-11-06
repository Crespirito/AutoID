# Laboratorio Entra ID — Gestor de entornos

Conjunto de scripts PowerShell para crear, inspeccionar y limpiar entornos de laboratorio en **Microsoft Entra ID**: usuarios, grupos, aplicaciones, service principals, unidades administrativas, roles PIM y sus relaciones.

Arquitectura modular por capacidades: añadir o quitar una funcionalidad es añadir o borrar un archivo. No hay que tocar el núcleo.

**Requisitos:** PowerShell 5.1+ | Microsoft.Graph | Entra ID (Free, P1 o P2)

---

## Qué es y qué no es

**Es:** un gestor de entornos de laboratorio, modular, multi-nivel (Free/P1/P2), reproducible (contraseñas derivadas de semilla local) y seguro por defecto (no adopta objetos preexistentes, verifica `objectId` antes de borrar).

**No es:** una herramienta de producción, un reemplazo de Terraform/Bicep, ni un backup de Entra ID.

---

## Características principales

- **Modular por capacidades.** Añadir o quitar una capacidad = añadir o borrar un `cap_*.ps1`. Nada más.
- **Niveles Free / P1 / P2.** Cada capacidad comprueba en runtime si el tenant soporta su licencia.
- **Creación automática** (nivel → tipo → crear) y **manual** (menú generado desde capacidades).
- **Contraseñas derivadas de semilla local.** Los JSON no contienen contraseñas.
- **Snapshot pre-lab.** Los objetos preexistentes no se adoptan ni se modifican.
- **Cleanup con despacho por capacidad** y verificación de `objectId` antes de borrar.
- **App-Only con certificado** por defecto, y **`az login`** como alternativa manual.

---

## Requisitos

- PowerShell 5.1+.
- Módulo `Microsoft.Graph`.
- Tenant de Entra ID (Free, P1 o P2).
- App registrada con certificado y permisos de aplicación concedidos (ver `docs/capacidades.txt` para la lista según nivel).
- Certificado con clave privada en `Cert:\CurrentUser\My` (o `.pfx` para importar desde el menú).

---

## Instalación rápida

1. Clonar el repositorio.
2. Ejecutar:
./menu.ps1


3. Configurar App-Only desde `[C] → [2]` (seleccionar certificado, introducir `ClientId` y `TenantId`).

4. (Opcional) Generar escenarios de ejemplo:
./generar_biblioteca.ps1

---

## Conexión a Graph

**Por defecto:** App-Only con certificado al arrancar. Si falla, el menú arranca sin sesión y avisa.

**Alternativa:** `az login` desde `[C] → [3]`. La opción desactiva WAM (`az config set core.enable_broker_on_windows=false`) y limpia la sesión (`az account clear`) para que te pida elegir el usuario.

**Si `az login` falla tras autenticarte:** comprueba que el módulo `Microsoft.Graph.Authentication` no está en la versión 2.35.1 (regresión conocida con `-AccessToken`).

---

## Uso

[1] Creación automática (nivel → tipo → crear)
[2] Creación manual (menú generado)
[3] Limpiar entorno
[4] Ver manifiesto
[C] Gestionar sesión de Graph
[N] Cambiar nivel de licencia
[K] Ver capacidades disponibles
[V] Alternar Verbose
[R] Resetear configuración
[0] Salir

Ficheros generados: `menu_config.json`, `manifiesto_lab.json`, `log_*.csv` (todos en `.gitignore`).

---

## Modelo de semilla y contraseñas

Los escenarios no contienen contraseñas. Cada escenario tiene una semilla local en `escenarios/.secrets/<escenario>.seed`. De ella se deriva la contraseña de cada usuario con `HMAC-SHA256(semilla, UPN)`. Se muestran una sola vez al crear. Si se pierde la semilla, no se pueden reproducir.

Detalle completo: `docs/escenarios.txt`.

---

## Seguridad

- **No se sube a Git:** `escenarios/.secrets/`, `*.seed`, `manifiesto_lab*.json`, `menu_config.json`, `log_*.csv`, `biblioteca.json`.
- **Sí se sube:** scripts, `lib_caps/`, `docs/`, escenarios de ejemplo (sin secretos), plantillas.

Detalle completo: `.gitignore` y `docs/manifiesto.txt`.

---

## Documentación

- `docs/capacidades.txt` — contrato de capacidad, cómo añadir/quitar capacidades, niveles, licencias.
- `docs/escenarios.txt` — formato del JSON de escenario, secciones, alias, plantillas, semilla.
- `docs/manifiesto.txt` — estructura v2 del manifiesto, estados, migración, cleanup.

---

## Solución de problemas

**"No hay sesión de Graph activa"**
Configurar App-Only desde `[C] → [2]`, o conectar vía `az login` desde `[C] → [3]`.

**"No se encuentra el certificado con Thumbprint ..."**
El Thumbprint guardado no coincide con ningún certificado en `Cert:\CurrentUser\My`. Reconfigurar desde `[C] → [2]`.

**"Requiere licencia Entra ID P1/P2"**
El tenant no tiene esa licencia. Cambiar de nivel con `[N]` o usar un escenario sin esas secciones.

**"Manifiesto presente pero ilegible"**
Borrar `manifiesto_lab.json` y empezar de nuevo.

**"Capacidad no registrada (carpeta desactivada)"**
La sección del escenario usa una capacidad cuya carpeta está renombrada a `.disabled`. Reactivarla o quitar la sección del escenario.

**Encoding roto ("l?nea", acentos raros)**
Algún `.ps1` se guardó sin BOM. Guardarlo como UTF-8 con BOM.

---

## Licencia

Uso educativo y de laboratorio. Sin garantías. El operador es responsable del uso en su tenant. No usar en producción sin revisar y adaptar el código.
