<#
.SYNOPSIS
    Librería de configuración persistente del menú.
.DESCRIPTION
    Proporciona:
      - Ruta canónica de menu_config.json
      - Valores por defecto
      - Carga con validación de tipos
      - Guardado
      - Reseteo
      - Actualización parcial de claves
.NOTES
    Depende de lib_ui.ps1 (funciones Write-Lab*).
    Se carga por dot-sourcing.
#>

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabConfigFileName = "menu_config.json"
$script:LabConfigPath     = Join-Path $PSScriptRoot $script:LabConfigFileName

# ============================================================
# VALORES POR DEFECTO
# ============================================================
# Para añadir una nueva opción persistente:
#   1. Añadir la clave aquí con su valor por defecto.
#   2. Añadir su lectura/validación en Get-LabConfig.
#   3. Añadir su escritura en Save-LabConfig (ya es genérica).
#   4. Añadir la acción correspondiente en menu.ps1.
function Get-LabConfigDefaults {
    <#
    .SYNOPSIS
        Devuelve una copia nueva de los valores por defecto.
    #>
    return @{
        Verbose = $false
    }
}

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabConfigPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de menu_config.json.
    #>
    return $script:LabConfigPath
}

function Test-LabConfigExists {
    <#
    .SYNOPSIS
        Devuelve $true si existe el fichero de configuración.
    #>
    return (Test-Path $script:LabConfigPath)
}

function Get-LabConfig {
    <#
    .SYNOPSIS
        Carga la configuración desde disco. Si no existe o es inválida,
        devuelve los valores por defecto.
    .DESCRIPTION
        Valida tipos para evitar que un JSON editado a mano con strings
        ("true"/"false") rompa la lógica booleana del menú.
    .OUTPUTS
        Hashtable con las claves de configuración.
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

    # --- Verbose ---
    if ($null -ne $loaded.PSObject.Properties['Verbose']) {
        $raw = $loaded.Verbose
        if ($raw -is [bool]) {
            $config.Verbose = $raw
        } elseif ($raw -is [string]) {
            $config.Verbose = ($raw -match '^(?i:true|1|yes|si)$')
        } elseif ($raw -is [int]) {
            $config.Verbose = ($raw -ne 0)
        }
    }

    return $config
}

function Save-LabConfig {
    <#
    .SYNOPSIS
        Guarda la configuración en disco.
    .PARAMETER Config
        Hashtable con las claves de configuración.
    .OUTPUTS
        $true si se guardó correctamente, $false si falló.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Config
    )

    try {
        $Config | ConvertTo-Json -Depth 3 | Set-Content -Path $script:LabConfigPath -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar la configuración: $($_.Exception.Message)"
        return $false
    }
}

function Reset-LabConfig {
    <#
    .SYNOPSIS
        Resetea la configuración a los valores por defecto y la guarda.
    .OUTPUTS
        Hashtable con los valores por defecto restaurados.
    #>
    $defaults = Get-LabConfigDefaults
    $null = Save-LabConfig -Config $defaults
    return $defaults
}

function Update-LabConfig {
    <#
    .SYNOPSIS
        Aplica cambios parciales a la configuración y la guarda.
    .DESCRIPTION
        Útil para que el menú modifique una clave sin tener que leer,
        modificar y guardar manualmente.
    .PARAMETER Cambios
        Hashtable con las claves a modificar.
    .OUTPUTS
        Hashtable con la configuración resultante.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Cambios
    )

    $config = Get-LabConfig
    foreach ($key in $Cambios.Keys) {
        $config[$key] = $Cambios[$key]
    }
    $null = Save-LabConfig -Config $config
    return $config
}