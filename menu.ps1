<#
.SYNOPSIS
    Menú orquestador para entornos de laboratorio en Entra ID (Free).
.DESCRIPTION
    Gestiona la sesión de Microsoft Graph (persistente hasta salir con 0),
    la configuración y el manifiesto, y delega la creación/limpieza en
    los scripts hijos:
      - creauto.ps1
      - creamanual.ps1
      - clean_up.ps1
.NOTES
    Requiere que estén presentes en la misma carpeta:
      lib_ui.ps1, lib_graph.ps1, lib_config.ps1, lib_manifiesto.ps1
#>
#Requires -Version 5.1
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# VALIDACIÓN DE CONTEXTO
# ============================================================
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

# ============================================================
# FUNCIONES AUXILIARES
# ============================================================

function Invoke-EnsureSession {
    <#
    .SYNOPSIS
        Garantiza sesión de Graph antes de una operación. Si expiró, intenta reconectar.
    #>
    if (Test-LabGraphSession) { return $true }
    Write-LabWarn 'No hay sesión de Graph activa. Conectando...'
    return (Connect-LabGraph)
}

function Test-ScriptHijo {
    <#
    .SYNOPSIS
        Comprueba que existe un script hijo en la ruta indicada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Nombre
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
        Ejecuta un script hijo con los argumentos indicados y muestra su código de salida.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Argumentos
    )

    Write-Host ''
    Write-Host "Ejecutando: $(Split-Path -Path $Path -Leaf)" -ForegroundColor Green
    Write-Host '------------------------------------------------------------' -ForegroundColor Gray

    $exitCode = 0
    try {
        & $Path @Argumentos
        if ($null -ne $LASTEXITCODE) { $exitCode = $LASTEXITCODE }
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
# ACCIONES DEL MENÚ
# ============================================================

function Invoke-GestionSesion {
    <#
    .SYNOPSIS
        Muestra el estado de la sesión de Graph y permite reconectar.
    #>
    Show-LabHeader -Titulo 'GESTION DE SESION DE GRAPH'
    $status = Get-LabGraphStatus

    if ($status) {
        Write-LabOk 'Sesión activa.'
        Write-Host "  Usuario : $($status.Account)"
        Write-Host "  Tenant  : $($status.TenantId)"
        Write-Host "  Scopes  : $($status.Scopes)"
        Write-Host ''
        $resp = Read-Host '¿Quieres reconectar (cerrar y abrir sesión)? (SI/N)'
        if ($resp -eq 'SI') {
            Disconnect-LabGraph
            $null = Connect-LabGraph
        }
    } else {
        Write-LabWarn 'No hay sesión activa.'
        $null = Connect-LabGraph
    }
    Wait-LabKey
}

function Invoke-CrearAutomatica {
    <#
    .SYNOPSIS
        Lanza el script creauto.ps1.
    .DESCRIPTION
        Las contraseñas de los usuarios NO están en el escenario: se derivan
        de una semilla local (escenarios/.secrets/<escenario>.seed) que el
        script creauto.ps1 gestiona. Se avisa al operador de que las
        contraseñas se mostrarán una sola vez al final de la creación.
    #>
    if (-not (Test-ScriptHijo -Path $ScriptAuto -Nombre 'creauto.ps1')) {
        Wait-LabKey
        return
    }
    if (-not (Invoke-EnsureSession)) {
        Wait-LabKey
        return
    }

    if (Test-LabManifiestoExists) {
        Write-LabWarn 'Ya existe un manifiesto pendiente. Se sobrescribirá si creas un nuevo entorno.'
        $resp = Read-Host "Escribe 'SI' para continuar"
        if ($resp -ne 'SI') {
            Write-LabInfo 'Operación cancelada.'
            Start-Sleep -Seconds 1
            return
        }
    }

    # Aviso explícito sobre la gestión de contraseñas
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
    if (-not (Test-ScriptHijo -Path $ScriptManual -Nombre 'creamanual.ps1')) {
        Wait-LabKey
        return
    }
    if (-not (Invoke-EnsureSession)) {
        Wait-LabKey
        return
    }

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
    if (-not (Test-ScriptHijo -Path $ScriptCleanup -Nombre 'clean_up.ps1')) {
        Wait-LabKey
        return
    }
    if (-not (Invoke-EnsureSession)) {
        Wait-LabKey
        return
    }

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

        Write-Host "Fecha             : $($m.Fecha)"
        Write-Host "Tenant ID         : $($m.TenantId)"
        Write-Host "Tenant Domain     : $($m.TenantDomain)"
        Write-Host ''

        Write-Host "Usuarios ($($m.Usuarios.Count)):" -ForegroundColor Cyan
        if ($m.Usuarios.Count -gt 0) {
            $m.Usuarios | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host '  (ninguno)' -ForegroundColor DarkGray
        }
        Write-Host ''

        Write-Host "Grupos ($($m.Grupos.Count)):" -ForegroundColor Cyan
        if ($m.Grupos.Count -gt 0) {
            $m.Grupos | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host '  (ninguno)' -ForegroundColor DarkGray
        }
        Write-Host ''

        Write-Host "Aplicaciones ($($m.Aplicaciones.Count)):" -ForegroundColor Cyan
        if ($m.Aplicaciones.Count -gt 0) {
            $m.Aplicaciones | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host '  (ninguna)' -ForegroundColor DarkGray
        }
        Write-Host ''

        Write-Host "Service Principals ($($m.ServicePrincipals.Count)):" -ForegroundColor Cyan
        if ($m.ServicePrincipals.Count -gt 0) {
            $m.ServicePrincipals | ForEach-Object { Write-Host "  - $_" }
        } else {
            Write-Host '  (ninguno)' -ForegroundColor DarkGray
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
    $script:config = Reset-LabConfig
    Write-LabOk 'Configuración reseteada a valores por defecto.'
    Start-Sleep -Seconds 1
}

function Invoke-InfoLicencia {
    <#
    .SYNOPSIS
        Muestra qué se puede hacer en un tenant Free y qué requiere P1/P2.
    #>
    Show-LabHeader -Titulo 'INFORMACION - TENANT FREE'

    Write-Host 'Esta versión está adaptada a tenants Microsoft Entra ID Free.' -ForegroundColor White
    Write-Host ''

    Write-Host 'Disponible en Free:' -ForegroundColor Green
    Write-Host '  - Creación de usuarios'
    Write-Host '  - Creación de grupos de seguridad'
    Write-Host '  - Creación de aplicaciones y service principals'
    Write-Host '  - Asignación de miembros a grupos'
    Write-Host '  - Asignación de propietarios a service principals'
    Write-Host '  - Añadir credenciales a aplicaciones'
    Write-Host ''

    Write-Host 'NO disponible en Free (requiere P1/P2):' -ForegroundColor Red
    Write-Host '  - Asignación de roles de directorio'
    Write-Host '  - Grupos con asignación de roles'
    Write-Host '  - Grupos dinámicos'
    Write-Host '  - Acceso condicional avanzado'
    Write-Host '  - Gestión de PIM'

    Wait-LabKey
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
        Write-Host "  Conectado : $($s.Account)" -ForegroundColor Green
        Write-Host "  Tenant    : $($s.TenantId)"
    } else {
        Write-Host '  Sin sesion activa' -ForegroundColor Red
    }
    Write-Host ''
}

function Show-EstadoConfig {
    <#
    .SYNOPSIS
        Pinta el estado de la configuración actual.
    #>
    Write-Host '--- Configuracion ---' -ForegroundColor Yellow
    Write-Host "  Verbose   : $($config.Verbose)"
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
        Write-Host "  Fecha     : $($m.Fecha)"
        Write-Host "  Tenant    : $($m.Tenant)"
        Write-Host "  Usuarios  : $($m.Usuarios) | Grupos: $($m.Grupos) | Apps: $($m.Apps)"
    }
    Write-Host ''
}

# ============================================================
# ARRANQUE: CONEXIÓN INICIAL A GRAPH
# ============================================================
Show-LabHeader -Titulo 'GESTOR DE ENTORNOS DE LABORATORIO - ENTRA ID (FREE)'

Write-LabInfo 'Iniciando sesión de Microsoft Graph...'
if (-not (Connect-LabGraph)) {
    Write-LabError 'No se pudo establecer la sesión inicial.'
    Write-LabWarn 'El menú arrancará sin sesión. Usa la opción [C] para conectar manualmente.'
    Wait-LabKey
}

# ============================================================
# BUCLE PRINCIPAL
# ============================================================
while ($true) {
    Show-LabHeader
    Show-EstadoSesion
    Show-EstadoConfig
    Show-EstadoManifiesto

    Write-Host '--- Creacion ---' -ForegroundColor Cyan
    Write-Host '  [1] Creacion automatica (creauto.ps1)'
    Write-Host '  [2] Creacion personalizada (creamanual.ps1)'
    Write-Host ''
    Write-Host '--- Limpieza ---' -ForegroundColor Cyan
    Write-Host '  [3] Limpiar entorno'
    Write-Host ''
    Write-Host '--- Manifiesto ---' -ForegroundColor Cyan
    Write-Host '  [4] Ver manifiesto'
    Write-Host ''
    Write-Host '--- Sesion / Configuracion ---' -ForegroundColor Cyan
    Write-Host '  [C] Gestionar sesion de Graph'
    Write-Host '  [V] Alternar Verbose'
    Write-Host '  [R] Resetear configuracion'
    Write-Host '  [I] Info sobre tenant Free'
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
        'V' { Invoke-ToggleVerbose }
        'R' { Invoke-ResetConfig }
        'I' { Invoke-InfoLicencia }
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