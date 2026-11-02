Laboratorio para la versión completa con diferentes niveles de acceso 
en EntraID.
Revisado con VS Code, con la herramienta PSscriptanalyzer.
En esta versión se saca la comprobación e instalación de los módulos
 del graph para agilizar la instalación de entornos.
Se añaden diferentes tipos de conexiones con Microsoft
Copiando el ps1 creacion_automatica.ps1 se logra crear más escenarios.

Diferencias entre otras versiones:
Conexiones con Microsoft de pago.
.- PIM (Privileged Identity Management) P2 o Entra ID Governance. 
Para roles elegibles como ruta de escalada.
.- Unidades administrativas (AUs) Free para crearlas, P1 para 
administrarlas.
.-Roles personalizados. P1.
Free permite "gestionar usuarios y grupos", mientras que P1 añade 
grupos dinámicos y P2 añade PIM.
-Creación automaática no crea AU ni asigna roles PIM

Revisión de la versión:
Ahora se añade la creación de escenarios automaticos con más de ellos.
La inyección de vulnerabilidad ahora es elegible. No hace falta 
modificar el script.
Se modifica el clean_up para que revierta vulnerabilidades
Se añade la verificación de lo creado antes de enviarlo a Entra ID en creación automática.
