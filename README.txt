Cambios de la Versión 03
Se cambian los nombres de los archivos: 
- creacion_automatica.ps1 = creauto.ps1
- creacion_personalizada = creamanual.ps1
Cambios en las contraseñas:
- Se crean en local.
- la semilla de generación se asocia a un nombre de escenario manual que se pide al principio o se generar como manal_<timestamp> 
- Se generan con RandomNumberGenerator con limitación de 32 Bytes.
- Los escenarios ya no tienen el campo contraseña
Se meten en .gitignore para no replicar las contraseñas guardadas
Se normalizan los archivos