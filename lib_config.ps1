<#
.SYNOPSIS
    Librería de configuración persistente del menú.
.DESCRIPTION
    Proporciona:
      - Ruta canónica de menu_config.json
      - Valores por defecto (Verbose, NivelLicencia, App-Only)
      - Carga con validación de tipos
      - Guardado
      - Reseteo
      - Actualización parcial de claves

    Claves gestionadas:
      Verbose               (bool)   - más detalle en la salida
      NivelLicencia         (string) - Free | P1 | P2
      ClientId              (string) - Application (client) ID de la App
      TenantId              (string) - Directory (tenant) ID
      CertificateThumbprint (string) - Thumbprint del certificado en Cert:\CurrentUser\My

    SEGURIDAD:
    menu_config.json contiene ClientId, TenantId y CertificateThumbprint.
    NO contiene la clave privada del certificado (esa vive en
    Cert:\CurrentUser\My). El Thumbprint identifica el certificado y debe
    tratarse como dato sensible. El fichero está en .gitignore y no debe
    subirse a Git.
.NOTES
    Depende de lib_ui.ps1 (Write-Lab*).
    Se carga por dot-sourcing desde menu.ps1.
#>

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabConfigFileName = 'menu_config.json'
$script:LabConfigPath     = Join-Path $PSScriptRoot $script:LabConfigFileName

# ============================================================
# VALORES POR DEFECTO
# ============================================================
function Get-LabConfigDefaults {
    <#
    .SYNOPSIS
        Devuelve una copia nueva de los valores por defecto.
    .DESCRIPTION
        Incluye las claves de UI (Verbose), el nivel de licencia y los
        datos App-Only. Las claves App-Only se rellenan desde menu.ps1
        ([C] Gestionar sesión de Graph).
    #>
    return @{
        Verbose               = $false
        NivelLicencia         = 'Free'
        ClientId              = ''
        TenantId              = ''
        CertificateThumbprint = ''
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
    return (Test-Path -Path $script:LabConfigPath)
}

function Get-LabConfig {
    <#
    .SYNOPSIS
        Carga la configuración desde disco. Si no existe o es inválida,
        devuelve los valores por defecto.
    .DESCRIPTION
        Valida tipos para evitar que un JSON editado a mano con strings
        ("true"/"false") rompa la lógica booleana del menú. Las claves
        App-Only se normalizan a string (vacío si no están).
    .OUTPUTS
        Hashtable con las claves de configuración.
    #>
    $defaults = Get-LabConfigDefaults

    if (-not (Test-Path -Path $script:LabConfigPath)) {
        return $defaults
    }

    try {
        $loaded = Get-Content -Path $script:LabConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-LabWarn 'No se pudo leer menu_config.json. Usando valores por defecto.'
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

    # --- NivelLicencia ---
    if ($null -ne $loaded.PSObject.Properties['NivelLicencia']) {
        $raw = $loaded.NivelLicencia
        if ($null -ne $raw) {
            $valor = ([string]$raw).Trim()
            if ($valor -in @('Free','P1','P2')) {
                $config.NivelLicencia = $valor
            }
        }
    }

    # --- ClientId ---
    if ($null -ne $loaded.PSObject.Properties['ClientId']) {
        $raw = $loaded.ClientId
        if ($null -ne $raw) { $config.ClientId = ([string]$raw).Trim() }
    }

    # --- TenantId ---
    if ($null -ne $loaded.PSObject.Properties['TenantId']) {
        $raw = $loaded.TenantId
        if ($null -ne $raw) { $config.TenantId = ([string]$raw).Trim() }
    }

    # --- CertificateThumbprint ---
    if ($null -ne $loaded.PSObject.Properties['CertificateThumbprint']) {
        $raw = $loaded.CertificateThumbprint
        if ($null -ne $raw) { $config.CertificateThumbprint = ([string]$raw).Trim() }
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
        [Parameter(Mandatory = $true)]
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
    .PARAMETER Cambios
        Hashtable con las claves a modificar.
    .OUTPUTS
        Hashtable con la configuración resultante.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Cambios
    )

    $config = Get-LabConfig
    foreach ($key in $Cambios.Keys) {
        $config[$key] = $Cambios[$key]
    }
    $null = Save-LabConfig -Config $config
    return $config
}

# ============================================================
# HELPERS APP-ONLY
# ============================================================

function Test-LabAppOnlyConfigComplete {
    <#
    .SYNOPSIS
        Devuelve $true si la configuración App-Only tiene los tres datos.
    .PARAMETER Config
        Hashtable de configuración.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    return (
        -not [string]::IsNullOrWhiteSpace($Config.ClientId) -and
        -not [string]::IsNullOrWhiteSpace($Config.TenantId) -and
        -not [string]::IsNullOrWhiteSpace($Config.CertificateThumbprint)
    )
}