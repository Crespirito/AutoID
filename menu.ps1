<#
.SYNOPSIS
    Menú orquestador para entornos de laboratorio en Entra ID.
.DESCRIPTION
    Punto de entrada del programa. Gestiona:
      - Conexión App-Only con certificado (por defecto, al arrancar).
      - Conexión delegada vía az login (opcional, manual, desde [C] -> [3]).
        La opción [3] fuerza el flujo de navegador (desactiva WAM) para que
        az login pida el usuario en lugar de reutilizar la cuenta de Windows.
      - Configuración persistente (nivel, App-Only).
      - Carga de capacidades desde lib_caps/.
      - Delegación en creauto.ps1, creamanual.ps1 y clean_up.ps1.

    El menú no conoce tipos de objeto: las capacidades se descubren
    dinámicamente desde lib_caps/ y se filtran por nivel y disponibilidad.
.NOTES
    Depende de: lib_ui.ps1, lib_graph.ps1, lib_config.ps1,
    lib_manifiesto.ps1, lib_escenarios.ps1, lib_niveles.ps1,
    lib_caps.ps1, lib_creadores.ps1.
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $PSScriptRoot) {
    throw 'Ejecuta este script como archivo .ps1, no pegado en consola.'
}

# ============================================================
# CARGA DE LIBRERÍAS
# ============================================================
. (Join-Path $PSScriptRoot 'lib_ui.ps1')
. (Join-Path $PSScriptRoot 'lib_graph.ps1')
. (Join-Path $PSScriptRoot 'lib_config.ps1')
. (Join-Path $PSScriptRoot 'lib_manifiesto.ps1')
. (Join-Path $PSScriptRoot 'lib_escenarios.ps1')
. (Join-Path $PSScriptRoot 'lib_niveles.ps1')
. (Join-Path $PSScriptRoot 'lib_caps.ps1')
. (Join-Path $PSScriptRoot 'lib_creadores.ps1')
<<<<<<< Updated upstream
=======
. (Join-Path $PSScriptRoot 'lib_helpers.ps1')
>>>>>>> Stashed changes

# ============================================================
# RUTAS A LOS SCRIPTS HIJOS
# ============================================================
$ScriptAuto    = Join-Path $PSScriptRoot 'creauto.ps1'
$ScriptManual  = Join-Path $PSScriptRoot 'creamanual.ps1'
$ScriptCleanup = Join-Path $PSScriptRoot 'clean_up.ps1'

# ============================================================
# ESTADO DEL MENÚ
# ============================================================
$config = Get-LabConfig
$null = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps')

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Invoke-EnsureSession {
    <#
    .SYNOPSIS
        Garantiza sesión de Graph antes de una operación.
        Devuelve $true si hay sesión, $false si no se pudo conectar.
    #>
    if (Test-LabGraphSession) { return $true }

    if (-not (Test-LabAppOnlyConfigComplete -Config $config)) {
        Write-LabWarn 'No hay configuración App-Only completa (ClientId, TenantId, Thumbprint).'
        Write-LabInfo 'Usa [C] Gestionar sesión de Graph para configurar el certificado o conectar vía az login.'
        return $false
    }

    Write-LabWarn 'No hay sesión de Graph activa. Conectando con App-Only...'
    $conectado = Connect-LabGraph `
        -ClientId              $config.ClientId `
        -TenantId              $config.TenantId `
        -CertificateThumbprint $config.CertificateThumbprint

    return [bool]$conectado
}

function Test-ScriptHijo {
    <#
    .SYNOPSIS
        Comprueba que existe un script hijo en la ruta indicada.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [string]$Nombre
    )
    if (-not (Test-Path -Path $Path)) {
        Write-LabError "No se encuentra el script '$Nombre' en: $Path"
        return $false
    }
    return $true
}

function Invoke-ScriptHijo {
    <#
    .SYNOPSIS
        Ejecuta un script hijo con los argumentos indicados.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [hashtable]$Argumentos
    )

    Write-Host ''
    Write-Host "Ejecutando: $(Split-Path -Path $Path -Leaf)" -ForegroundColor Green
    Write-Host '------------------------------------------------------------' -ForegroundColor Gray

    $exitCode = 0
    try {
        & $Path @Argumentos
	if (Test-Path variable:LASTEXITCODE) { 
        	if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
	}
    } catch {
        Write-LabError "Fallo durante la ejecución: $($_.Exception.Message)"
        $exitCode = 1
    }

    if ($exitCode -ne 0) {
        Write-LabWarn "El script finalizó con código $exitCode."
    }

    Write-Host '------------------------------------------------------------' -ForegroundColor Gray
}

# ============================================================
# GESTIÓN DE CERTIFICADOS APP-ONLY
# ============================================================

function Show-LabCertificateList {
    <#
    .SYNOPSIS
        Pinta la lista numerada de certificados disponibles.
    #>
    param(
        [Parameter(Mandatory = $true)] [array]$Certificados
    )

    Write-Host '  Certificados disponibles en Cert:\CurrentUser\My (con clave privada):' -ForegroundColor Cyan
    Write-Host ''
    
    # Forzamos a array para evitar el error de Count con un solo elemento
    $lista = @($Certificados)

    if ($lista.Count -eq 0) {
        Write-Host '    (ninguno)' -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    for ($i = 0; $i -lt $lista.Count; $i++) {
        $c = $lista[$i]
        Write-Host ('    [{0}] {1}' -f $i, $c.Thumbprint) -ForegroundColor White
        Write-Host ('        Subject : {0}' -f $c.Subject) -ForegroundColor Gray
        Write-Host ('        Expira  : {0}' -f $c.NotAfter.ToString('yyyy-MM-dd')) -ForegroundColor Gray
    }
    Write-Host ''
}

function Select-LabCertificate {
    <#
    .SYNOPSIS
        Muestra los certificados del store y permite seleccionar uno o importar un .pfx.
    .OUTPUTS
        El certificado seleccionado, o $null si se cancela.
    #>
    $certificados = @(Get-LabAvailableCertificates)
    Show-LabCertificateList -Certificados $certificados

    Write-Host '  Opciones:' -ForegroundColor Cyan
    Write-Host '    [número] Seleccionar un certificado de la lista'
    Write-Host '    [C]      Cargar un certificado desde fichero .pfx'
    Write-Host '    [X]      Cancelar'
    Write-Host ''

    $sel = Read-Host '  Selecciona una opción'

    if ($sel -match '^(?i)x$') { return $null }

    if ($sel -match '^(?i)c$') {
        $imported = Import-LabPfxCertificate
        if ($null -eq $imported) { return $null }
        return $imported
    }

    if ($sel -match '^\d+$' -and [int]$sel -lt $certificados.Count) {
        return $certificados[[int]$sel]
    }

    Write-LabWarn 'Selección inválida.'
    return $null
}

function Invoke-ConfigurarAppOnly {
    <#
    .SYNOPSIS
        Configura ClientId, TenantId y CertificateThumbprint para App-Only.
    #>
    Show-LabHeader -Titulo 'CONFIGURAR CERTIFICADO APP-ONLY'

    Write-Host '  Datos actuales:' -ForegroundColor Yellow
    Write-Host "    ClientId    : $($config.ClientId)"
    Write-Host "    TenantId    : $($config.TenantId)"
    Write-Host "    Thumbprint  : $($config.CertificateThumbprint)"
    Write-Host ''

    $cert = Select-LabCertificate
    if ($null -eq $cert) {
        Write-LabInfo 'Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    Write-Host ''
    Write-LabOk "Certificado seleccionado: $($cert.Thumbprint)"
    Write-Host "  Subject : $($cert.Subject)"
    Write-Host "  Expira  : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
    Write-Host ''

    $clientId = Read-Host "  ClientId de la App [$($config.ClientId)]"
    if ([string]::IsNullOrWhiteSpace($clientId)) { $clientId = $config.ClientId }
    if ([string]::IsNullOrWhiteSpace($clientId)) {
        Write-LabWarn 'ClientId vacío. Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    $tenantId = Read-Host "  TenantId [$($config.TenantId)]"
    if ([string]::IsNullOrWhiteSpace($tenantId)) { $tenantId = $config.TenantId }
    if ([string]::IsNullOrWhiteSpace($tenantId)) {
        Write-LabWarn 'TenantId vacío. Configuración cancelada.'
        Start-Sleep -Seconds 1
        return
    }

    $cambios = @{
        ClientId              = $clientId.Trim()
        TenantId              = $tenantId.Trim()
        CertificateThumbprint = $cert.Thumbprint
    }
    $script:config = Update-LabConfig -Cambios $cambios

    Write-LabOk 'Configuración App-Only guardada en menu_config.json.'
    Start-Sleep -Seconds 1
}

# ============================================================
# ACCIONES DEL MENÚ
# ============================================================

function Invoke-GestionSesion {
    <#
    .SYNOPSIS
        Submenú de gestión de sesión de Graph.
        Permite App-Only con certificado o delegada vía az login.
        La opción [3] fuerza el flujo de navegador (desactiva WAM) para que
        az login pida el usuario en lugar de reutilizar la cuenta de Windows.
    #>
    while ($true) {
        Show-LabHeader -Titulo 'GESTION DE SESION DE GRAPH'
        $status = Get-LabGraphStatus

        if ($status) {
            Write-LabOk 'Sesión activa.'
            Write-Host "  AuthType : $($status.AuthType)"
            Write-Host "  Tenant   : $($status.TenantId)"
            if ($status.ClientId) { Write-Host "  ClientId : $($status.ClientId)" }
        } else {
            Write-LabWarn 'No hay sesión activa.'
        }

        Write-Host ''
        Write-Host '  Configuración App-Only:' -ForegroundColor Yellow
        Write-Host "    ClientId    : $($config.ClientId)"
        Write-Host "    TenantId    : $($config.TenantId)"
        Write-Host "    Thumbprint  : $($config.CertificateThumbprint)"
        Write-Host ''

        Write-Host '  [1] Conectar / Reconectar (App-Only)'
        Write-Host '  [2] Configurar certificado App-Only'
        Write-Host '  [3] Conectar vía az login (usuario)'
        Write-Host '  [4] Desconectar'
        Write-Host '  [0] Volver al menú principal'
        Write-Host ''

        $op = Read-Host 'Selecciona una opción'

        switch ($op) {
            '1' {
                if (-not (Test-LabAppOnlyConfigComplete -Config $config)) {
                    Write-LabWarn 'Faltan datos App-Only. Usa [2] para configurarlos.'
                    Wait-LabKey
                    continue
                }
                if (Test-LabGraphSession) {
                    $resp = Read-Host '¿Reconectar (cerrar y abrir sesión)? (SI/N)'
                    if ($resp -eq 'SI') {
                        Disconnect-LabGraph
                        $conectado = Connect-LabGraph `
                            -ClientId              $config.ClientId `
                            -TenantId              $config.TenantId `
                            -CertificateThumbprint $config.CertificateThumbprint
                        if (-not $conectado) {
                            Write-LabError 'No se pudo reconectar con App-Only.'
                        }
                    }
                } else {
                    $conectado = Connect-LabGraph `
                        -ClientId              $config.ClientId `
                        -TenantId              $config.TenantId `
                        -CertificateThumbprint $config.CertificateThumbprint
                    if (-not $conectado) {
                        Write-LabError 'No se pudo conectar con App-Only.'
                    }
                }
                Wait-LabKey
            }
            '2' { Invoke-ConfigurarAppOnly }
            '3' {
                if (Test-LabGraphSession) {
                    Disconnect-LabGraph
                }

                Write-Host ''
                Write-LabInfo 'Preparando az login para que pida el usuario (desactivando WAM)...'

                try {
                    $null = az config set core.enable_broker_on_windows=false 2>$null
                    $null = az account clear 2>$null
                } catch {
                    Write-LabWarn "No se pudo configurar az: $($_.Exception.Message)"
                }

                Write-Host ''
                Write-LabInfo 'Se abrirá el navegador para que inicies sesión con el usuario que quieras.'
                Write-LabInfo 'Si no se abre, ejecuta manualmente en otra consola:'
                Write-LabInfo '  az login'
                Write-Host ''

                try {
                    $null = az login 2>&1
                } catch {
                    Write-LabWarn "az login falló o se canceló: $($_.Exception.Message)"
                }

                $conectado = Connect-LabGraphConAzLogin
                if (-not $conectado) {
                    Write-LabError 'No se pudo conectar vía az login.'
                    Write-LabInfo 'Verifica que Azure CLI está instalado y que has ejecutado "az login".'
                }
                Wait-LabKey
            }
            '4' { Disconnect-LabGraph; Wait-LabKey }
            '0' { return }
            default { Write-LabError 'Opción no válida.'; Start-Sleep -Seconds 1 }
        }
    }
}

function Invoke-CambiarNivel {
    <#
    .SYNOPSIS
        Cambia el nivel de licencia configurado.
    #>
    Show-LabHeader -Titulo 'CAMBIAR NIVEL DE LICENCIA'
    $niveles = Get-LabNivelesDisponibles
    if ($niveles.Count -eq 0) {
        Write-LabError 'No hay niveles disponibles (¿carpetas de capacidades vacías?).'
        Wait-LabKey
        return
    }

    $actual = Get-LabNivelActual -Config $config
    for ($i = 0; $i -lt $niveles.Count; $i++) {
        $desc = Get-LabNivelDescripcion -Nivel $niveles[$i]
        $marca = if ($niveles[$i] -eq $actual) { ' (actual)' } else { '' }
        Write-Host ('  [{0}] {1} - {2}{3}' -f $i, $niveles[$i], $desc, $marca)
    }
    Write-Host ''

    $sel = Read-Host 'Selecciona un nivel (Enter para cancelar)'
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    if (-not ($sel -match '^\d+$') -or [int]$sel -ge $niveles.Count) {
        Write-LabWarn 'Selección inválida.'
        Wait-LabKey
        return
    }

    $nuevo = $niveles[[int]$sel]
    try {
        $script:config = Set-LabNivel -Nivel $nuevo -Config $config
<<<<<<< Updated upstream
        Write-LabOk "Nivel cambiado a $nuevo."
=======
        $config = $script:config

        # Recarga del registro de capacidades: el loader se llamaba una sola vez
        # al arrancar, así que tras cambiar de nivel el registro seguía siendo el
        # del nivel anterior. Se cargan todos los niveles hasta el elegido, porque
        # las capacidades de P1/P2 declaran DependeDe sobre las de Free y sin ellas
        # el registro quedaría vacío.
        $hasta = @($niveles | Where-Object {
            (Get-LabNivelOrden -Nivel $_) -le (Get-LabNivelOrden -Nivel $nuevo)
        })
        $registradas = Initialize-LabCapacidades -Root (Join-Path $PSScriptRoot 'lib_caps') -Niveles $hasta
        Write-LabOk "Nivel cambiado a $nuevo. Capacidades recargadas: $registradas."
>>>>>>> Stashed changes
    } catch {
        Write-LabError "No se pudo cambiar el nivel: $($_.Exception.Message)"
    }
    Wait-LabKey
}

function Invoke-VerCapacidades {
    <#
    .SYNOPSIS
        Muestra las capacidades disponibles y su estado.
    #>
    Show-LabHeader -Titulo 'CAPACIDADES DISPONIBLES'
    $nivel = Get-LabNivelActual -Config $config

    $ctx = @{
        TenantId     = (Get-MgContext -ErrorAction SilentlyContinue).TenantId
        TenantDomain = (Get-MgContext -ErrorAction SilentlyContinue).TenantId
        Nivel        = $nivel
        Config       = $config
    }

<<<<<<< Updated upstream
    $capacidades = Get-LabCapacidades -Nivel $nivel
=======
    $capacidades = @(Get-LabCapacidades -Nivel $nivel)
>>>>>>> Stashed changes
    foreach ($cap in $capacidades) {
        $nombre = if ($cap.ContainsKey('Descripcion') -and $cap.Descripcion) { $cap.Descripcion } else { $cap.Nombre }
        $estado = 'OK'
        try {
            $t = & $cap.TestDisponible $ctx
            if (-not $t.Disponible) { $estado = "NO ($($t.Motivo))" }
        } catch {
            $estado = "ERROR ($($_.Exception.Message))"
        }
        Write-Host ("  {0,-35} {1}" -f $nombre, $estado)
    }
    Write-Host ''
    Write-Host "Nivel actual: $nivel" -ForegroundColor Gray
    Wait-LabKey
}

function Invoke-CrearAutomatica {
    <#
    .SYNOPSIS
        Lanza el script creauto.ps1.
    #>
    if (-not (Test-ScriptHijo -Path $ScriptAuto -Nombre 'creauto.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn 'Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno.'
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne 'SI') {
            Write-LabInfo 'Operación cancelada.'
            Start-Sleep -Seconds 1
            return
        }
    }

    Write-Host ''
    Write-LabInfo 'Las contraseñas de los usuarios se derivan de la semilla local del escenario.'
    Write-LabInfo 'Se mostrarán UNA SOLA VEZ al finalizar la creación. Anótalas antes de continuar.'
    Write-Host ''

    $argumentos = @{}
    if ($config.Verbose) { $argumentos['Verbose'] = $true }

    Invoke-ScriptHijo -Path $ScriptAuto -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-CrearPersonalizada {
    <#
    .SYNOPSIS
        Lanza el script creamanual.ps1.
    #>
    if (-not (Test-ScriptHijo -Path $ScriptManual -Nombre 'creamanual.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (Test-LabManifiestoExists) {
        Write-LabWarn 'Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno.'
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne 'SI') {
            Write-LabInfo 'Operación cancelada.'
            Start-Sleep -Seconds 1
            return
        }
    }

    $argumentos = @{}
    if ($config.Verbose) { $argumentos['Verbose'] = $true }

    Invoke-ScriptHijo -Path $ScriptManual -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-Limpiar {
    <#
    .SYNOPSIS
        Lanza el script clean_up.ps1 sobre el manifiesto pendiente.
    #>
    if (-not (Test-ScriptHijo -Path $ScriptCleanup -Nombre 'clean_up.ps1')) { Wait-LabKey; return }
    if (-not (Invoke-EnsureSession)) { Wait-LabKey; return }

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn 'No hay manifiesto pendiente. Nada que limpiar.'
        Wait-LabKey
        return
    }

    $argumentos = @{ ManifiestoPath = (Get-LabManifiestoPath) }
    if ($config.Verbose) { $argumentos['Verbose'] = $true }

    Invoke-ScriptHijo -Path $ScriptCleanup -Argumentos $argumentos
    Wait-LabKey
}

function Invoke-VerManifiesto {
    <#
    .SYNOPSIS
        Muestra el contenido del manifiesto pendiente.
    #>
    Show-LabHeader -Titulo 'MANIFIESTO'

    if (-not (Test-LabManifiestoExists)) {
        Write-LabWarn 'No hay manifiesto pendiente.'
        Wait-LabKey
        return
    }

    try {
        $m = Get-LabManifiesto
        Write-Host "Versión           : $($m.manifestVersion)"
        Write-Host "Fecha             : $($m.fecha)"
        Write-Host "Tenant            : $($m.tenantDomain)"
        Write-Host "Nivel             : $($m.nivel)"
        Write-Host "Escenario         : $($m.escenario)"
        Write-Host ''

        $pendientes = Get-LabManifiestoPendientes -Manifiesto $m
        Write-Host "Objetos pendientes: $($pendientes.objetos.Count)" -ForegroundColor Cyan
        foreach ($o in $pendientes.objetos) {
            Write-Host "  - [$($o.capacidad)] $($o.tipo): $($o.id)" -ForegroundColor Gray
        }
        Write-Host ''
        Write-Host "Vulnerabilidades pendientes: $($pendientes.vulnerabilidades.Count)" -ForegroundColor Cyan
        foreach ($v in $pendientes.vulnerabilidades) {
            Write-Host "  - [$($v.capacidad)] $($v.tipo): $($v.id)" -ForegroundColor Gray
        }
    } catch {
        Write-LabError "No se pudo leer el manifiesto: $($_.Exception.Message)"
    }

    Wait-LabKey
}

function Invoke-ToggleVerbose {
    <#
    .SYNOPSIS
        Alterna el modo Verbose en la configuración y lo persiste.
    #>
    $script:config.Verbose = -not $config.Verbose
    $null = Save-LabConfig -Config $script:config
    Write-LabOk "Modo Verbose: $($script:config.Verbose)"
    Start-Sleep -Seconds 1
}

function Invoke-ResetConfig {
    <#
    .SYNOPSIS
        Restaura la configuración a los valores por defecto.
    #>
    Write-LabWarn 'Esto restaura la configuración a valores por defecto.'
    $resp = Read-Host '¿Borrar también los datos App-Only (ClientId, TenantId, Thumbprint)? (SI/N)'
    $datosAppOnly = @{
        ClientId              = $config.ClientId
        TenantId              = $config.TenantId
        CertificateThumbprint = $config.CertificateThumbprint
    }
    $script:config = Reset-LabConfig
    if ($resp -eq 'SI') {
        Write-LabInfo 'Datos App-Only borrados.'
    } else {
        $script:config = Update-LabConfig -Cambios $datosAppOnly
        Write-LabInfo 'Datos App-Only conservados.'
    }
    Write-LabOk 'Configuración reseteada.'
    Start-Sleep -Seconds 1
}

# ============================================================
# PANTALLAS DE ESTADO
# ============================================================

function Show-EstadoSesion {
    <#
    .SYNOPSIS
        Pinta el estado de la sesión de Graph.
    #>
    Write-Host '--- Sesion Graph ---' -ForegroundColor Yellow
    $s = Get-LabGraphStatus
    if ($s) {
        Write-Host "  Conectado : $($s.AuthType)" -ForegroundColor Green
        Write-Host "  Tenant    : $($s.TenantId)"
        if ($s.ClientId) { Write-Host "  ClientId  : $($s.ClientId)" }
    } else {
        Write-Host '  Sin sesion activa' -ForegroundColor Red
    }
    Write-Host ''
}

function Show-EstadoNivel {
    <#
    .SYNOPSIS
        Pinta el nivel de licencia actual.
    #>
    Write-Host '--- Nivel de licencia ---' -ForegroundColor Yellow
    $nivel = Get-LabNivelActual -Config $config
    Write-Host "  Nivel     : $nivel ($(Get-LabNivelDescripcion -Nivel $nivel))"
    Write-Host ''
}

function Show-EstadoManifiesto {
    <#
    .SYNOPSIS
        Pinta un resumen del manifiesto pendiente.
    #>
    Write-Host '--- Manifiesto ---' -ForegroundColor Yellow
    $m = Get-LabManifiestoStatus
    if ($null -eq $m) {
        Write-Host '  Sin manifiesto pendiente' -ForegroundColor DarkGray
    } elseif ($m -eq 'ilegible') {
        Write-Host '  Manifiesto presente pero ilegible' -ForegroundColor Red
    } else {
        Write-Host "  Escenario : $($m.Escenario) | Nivel: $($m.Nivel)"
        Write-Host "  Pendientes: $($m.Pendientes) objetos | $($m.Vulnerabilidades) vulnerabilidades"
    }
    Write-Host ''
}

# ============================================================
# ARRANQUE: CONEXIÓN INICIAL APP-ONLY (POR DEFECTO)
# ============================================================
Show-LabHeader -Titulo 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID'

if (Test-LabAppOnlyConfigComplete -Config $config) {
    Write-LabInfo 'Conectando con App-Only...'
    $conectado = Connect-LabGraph `
        -ClientId              $config.ClientId `
        -TenantId              $config.TenantId `
        -CertificateThumbprint $config.CertificateThumbprint

    if (-not $conectado) {
        Write-LabError 'No se pudo establecer la sesión inicial App-Only.'
        Write-LabWarn 'El menú arrancará sin sesión.'
        Write-LabInfo 'Opciones:'
        Write-LabInfo '  - [C] -> [2] Revisar o reconfigurar el certificado App-Only.'
        Write-LabInfo '  - [C] -> [3] Conectar vía az login (requiere Azure CLI y "az login").'
        Wait-LabKey
    }
} else {
    Write-LabWarn 'No hay configuración App-Only completa.'
    Write-LabInfo 'Opciones:'
    Write-LabInfo '  - [C] -> [2] Configurar el certificado App-Only.'
    Write-LabInfo '  - [C] -> [3] Conectar vía az login (requiere Azure CLI y "az login").'
    Wait-LabKey
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
while ($true) {
    Show-LabHeader
    Show-EstadoSesion
    Show-EstadoNivel
    Show-EstadoManifiesto

    Write-Host '--- Creacion ---' -ForegroundColor Cyan
    Write-Host '  [1] Creacion automatica (nivel -> tipo -> crear)'
    Write-Host '  [2] Creacion manual (menu generado desde capacidades)'
    Write-Host ''
    Write-Host '--- Limpieza ---' -ForegroundColor Cyan
    Write-Host '  [3] Limpiar entorno (despacho por capacidad)'
    Write-Host ''
    Write-Host '--- Manifiesto ---' -ForegroundColor Cyan
    Write-Host '  [4] Ver manifiesto'
    Write-Host ''
    Write-Host '--- Sesion / Configuracion ---' -ForegroundColor Cyan
    Write-Host '  [C] Gestionar sesion de Graph (App-Only / az login)'
    Write-Host '  [N] Cambiar nivel de licencia'
    Write-Host '  [K] Ver capacidades disponibles'
    Write-Host '  [V] Alternar Verbose'
    Write-Host '  [R] Resetear configuracion'
    Write-Host ''
    Write-Host '  [0] Salir'
    Write-Host ''

    $opcion = Read-Host 'Selecciona una opcion'

    switch ($opcion.ToUpper()) {
        '1' { Invoke-CrearAutomatica }
        '2' { Invoke-CrearPersonalizada }
        '3' { Invoke-Limpiar }
        '4' { Invoke-VerManifiesto }
        'C' { Invoke-GestionSesion }
        'N' { Invoke-CambiarNivel }
        'K' { Invoke-VerCapacidades }
        'V' { Invoke-ToggleVerbose }
        'R' { Invoke-ResetConfig }
        '0' {
            $null = Save-LabConfig -Config $config
            Disconnect-LabGraph
            Write-Host ''
            Write-LabOk 'Sesión cerrada. Saliendo...'
            exit 0
        }
        default {
            Write-LabError 'Opcion no valida.'
            Start-Sleep -Seconds 1
        }
    }
}