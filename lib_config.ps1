<#
.SYNOPSIS
    Librería de configuración persistente del menú.
.DESCRIPTION
    Proporciona:
      - Ruta canónica de menu_config.json
      - Valores por defecto
      - Carga con validación de tipos
      - Guardado (con relleno de claves ausentes)
      - Reseteo
      - Actualización parcial
.NOTES
    Depende de lib_ui.ps1 (funciones Write-Lab*).
    Se carga por dot-sourcing.
    Guardar este fichero como UTF-8 con BOM para compatibilidad con PS 5.1.
#>
#Requires -Version 5.1

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabConfigFileName = "menu_config.json"
$script:LabConfigPath     = Join-Path $PSScriptRoot $script:LabConfigFileName

# ============================================================
# VALORES POR DEFECTO
# ============================================================
function Get-LabConfigDefaults {
    return @{
        Verbose            = $false
        # --- Datos para autenticación App-Only ---
        AppOnlyClientId    = $null
        AppOnlyTenantId    = $null
        AppOnlyThumbprint  = $null
        AppOnlyCertName    = $null
    }
}

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabConfigPath {
    return $script:LabConfigPath
}

function Test-LabConfigExists {
    return (Test-Path $script:LabConfigPath)
}

function Get-LabConfig {
    <#
    .SYNOPSIS
        Carga la configuración desde disco. Si no existe o es inválida,
        devuelve los valores por defecto.
    #>
    $defaults = Get-LabConfigDefaults

    if (-not (Test-Path $script:LabConfigPath)) {
        return $defaults
    }

    try {
        $loaded = Get-Content -Path $script:LabConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-LabWarn "No se pudo leer menu_config.json. Usando valores por defecto."
        return $defaults
    }

    $config = Get-LabConfigDefaults

    # --- Verbose (booleano) ---
    if ($null -ne $loaded.PSObject.Properties['Verbose']) {
        $raw = $loaded.Verbose
        if ($raw -is [bool]) {
            $config.Verbose = $raw
        } elseif ($raw -is [string]) {
            $config.Verbose = ($raw -match '^(?i:true|1|yes|si)$')
        } elseif ($raw -is [int] -or $raw -is [long] -or $raw -is [double]) {
            $config.Verbose = ($raw -ne 0)
        }
    }

    # --- AppOnly (strings) ---
    foreach ($key in @('AppOnlyClientId', 'AppOnlyTenantId', 'AppOnlyThumbprint', 'AppOnlyCertName')) {
        if ($null -ne $loaded.PSObject.Properties[$key]) {
            $val = $loaded.$key
            if (-not [string]::IsNullOrWhiteSpace($val)) {
                $config[$key] = $val.ToString().Trim()
            }
        }
    }

    return $config
}

function Save-LabConfig {
    <#
    .SYNOPSIS
        Guarda la configuración en disco, rellenando claves ausentes.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )

    try {
        $completa = Get-LabConfigDefaults
        foreach ($key in $Config.Keys) {
            $completa[$key] = $Config[$key]
        }

        $completa | ConvertTo-Json -Depth 3 | Set-Content -Path $script:LabConfigPath -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar la configuración: $($_.Exception.Message)"
        return $false
    }
}

function Reset-LabConfig {
    $defaults = Get-LabConfigDefaults
    $null = Save-LabConfig -Config $defaults
    return $defaults
}

function Update-LabConfig {
    param([Parameter(Mandatory=$true)] [hashtable]$Cambios)

    $config = Get-LabConfig
    foreach ($key in $Cambios.Keys) {
        $config[$key] = $Cambios[$key]
    }

    if (-not (Save-LabConfig -Config $config)) {
        return $null
    }
    return $config
}