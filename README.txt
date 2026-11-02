# Registro de cambios - Versión actual

## Autenticación (App-Only)

- **Nuevo método de conexión**: El menú ahora está diseñado para conectarse a Graph usando una App Registration y un certificado (App-Only), evitando el fallo de WAM en la versión 2.41 del módulo.
- **Configuración manual**: La opción `[C]` del menú permite introducir los datos necesarios (Client ID, Tenant ID y Thumbprint) y guardarlos en `menu_config.json` para futuras conexiones.
- **Fallback interactivo**: Si no hay datos App-Only o fallan, el sistema intenta el flujo de código de dispositivo (`-UseDeviceCode`).
- **Indicador visual**: La pantalla principal muestra si hay datos App-Only configurados.

## Cambios en el menú

- **Opción `[C]` ampliada**: Ahora incluye la gestión de credenciales App-Only además de la reconexión.
- **Orden de carga corregido**: `lib_config.ps1` se carga antes que `lib_graph.ps1` para garantizar que `Get-LabConfig` esté disponible al conectar.

## Renombrado de archivos

- `creacion_personalizada.ps1` → **`creamanual.ps1`**
- `creacion_automatica.ps1` → **`creauto.ps1`**

Las rutas y referencias internas en `menu.ps1` han sido actualizadas. Los logs ahora se guardan como `log_creauto_*.csv` y `log_creamanual_*.csv`.

## Scripts hijos

- **`creauto.ps1`**: Mantiene la simulación global antes de crear objetos.
- **`creamanual.ps1`**: Mantiene las simulaciones para usuarios, grupos y aplicaciones.
- **`clean_up.ps1`**: Sin cambios funcionales (reintentos y protección del manifiesto intactos).