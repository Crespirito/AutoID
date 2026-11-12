<#
.SYNOPSIS
    Librería de configuración persistente del menú (PowerShell 7).
.DESCRIPTION
    Proporciona:
      - Ruta canónica de menu_config.json.
      - Valores por defecto.
      - Carga, guardado, reseteo y actualización parcial.
      - Normalización centralizada PSCustomObject -> Hashtable.

    Claves gestionadas:
      Verbose               (bool)   - más detalle en la salida.
      NivelLicencia         (string) - Free | P1 | P2.
      ClientId              (string) - Application (client) ID de la App.
      TenantId              (string) - Directory (tenant) ID.
      CertificateThumbprint (string) - Thumbprint del certificado.

    CONTRATO:
      - Get-LabConfig SIEMPRE devuelve un [hashtable] con las 5 claves.
      - Save-LabConfig acepta [hashtable] o [PSCustomObject].
      - Update-LabConfig solo modifica claves existentes.
.NOTES
    Depende de lib_ui.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# RUTA CANÓNICA
# ============================================================
$script:LabConfigFileName = 'menu_config.json'
$script:LabConfigPath     = Join-Path $PSScriptRoot $script:LabConfigFileName

# ============================================================
# VALORES POR DEFECTO
# ============================================================
function Get-LabConfigDefaults {
    return @{
        Verbose               = $false
        NivelLicencia         = 'Free'
        ClientId              = ''
        TenantId              = ''
        CertificateThumbprint = ''
    }
}

# ============================================================
# NORMALIZACIÓN
# ============================================================
function ConvertTo-LabConfigHash {
    <#
    .SYNOPSIS
        Normaliza un objeto (hashtable o PSCustomObject) a [hashtable]
        con las claves y tipos esperados.
    .DESCRIPTION
        Devuelve SIEMPRE un [hashtable] con las 5 claves exactas. Los
        valores inválidos se sustituyen por el default y se avisa con
        Write-LabWarn.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Origen
    )

    $config = Get-LabConfigDefaults

    if ($null -eq $Origen) { return $config }

    # Convertir a hashtable sin importar el tipo de origen
    $origenHash = @{}
    if ($Origen -is [hashtable]) {
        foreach ($k in $Origen.Keys) { $origenHash["$k".ToLowerInvariant()] = $Origen[$k] }
    } elseif ($Origen -is [pscustomobject]) {
        foreach ($p in $Origen.PSObject.Properties) { $origenHash[$p.Name.ToLowerInvariant()] = $p.Value }
    } else {
        Write-LabWarn "ConvertTo-LabConfigHash: tipo no soportado ($($Origen.GetType().FullName)). Usando defaults."
        return $config
    }

    # --- Verbose ---
    if ($origenHash.ContainsKey('verbose')) {
        $raw = $origenHash['verbose']
        if ($raw -is [bool]) {
            $config.Verbose = $raw
        } elseif ($null -ne $raw) {
            $config.Verbose = ([string]$raw -match '^(?i:true|1|yes|si)$')
        }
    }

    # --- NivelLicencia ---
    if ($origenHash.ContainsKey('nivellicencia')) {
        $valor = "$($origenHash['nivellicencia'])".Trim()
        if ($valor -in @('Free','P1','P2')) {
            $config.NivelLicencia = $valor
        } elseif (-not [string]::IsNullOrWhiteSpace($valor)) {
            Write-LabWarn "NivelLicencia inválido en configuración: '$valor'. Usando '$($config.NivelLicencia)'."
        }
    }

    # --- ClientId ---
    if ($origenHash.ContainsKey('clientid') -and $null -ne $origenHash['clientid']) {
        $config.ClientId = "$($origenHash['clientid'])".Trim()
    }

    # --- TenantId ---
    if ($origenHash.ContainsKey('tenantid') -and $null -ne $origenHash['tenantid']) {
        $config.TenantId = "$($origenHash['tenantid'])".Trim()
    }

    # --- CertificateThumbprint ---
    if ($origenHash.ContainsKey('certificatethumbprint') -and $null -ne $origenHash['certificatethumbprint']) {
        $config.CertificateThumbprint = "$($origenHash['certificatethumbprint'])".Trim()
    }

    return $config
}

# ============================================================
# FUNCIONES PÚBLICAS
# ============================================================

function Get-LabConfigPath {
    return $script:LabConfigPath
}

function Test-LabConfigExists {
    return (Test-Path -Path $script:LabConfigPath)
}

function Get-LabConfig {
    <#
    .SYNOPSIS
        Devuelve la configuración actual como [hashtable].
    .DESCRIPTION
        Siempre devuelve un [hashtable] con las 5 claves esperadas,
        con defaults aplicados si el archivo no existe o es ilegible.
    #>
    if (-not (Test-Path -Path $script:LabConfigPath)) {
        return (Get-LabConfigDefaults)
    }

    try {
        $loaded = Get-Content -Path $script:LabConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-LabWarn 'No se pudo leer menu_config.json. Usando valores por defecto.'
        return (Get-LabConfigDefaults)
    }

    return (ConvertTo-LabConfigHash -Origen $loaded)
}

function Save-LabConfig {
    <#
    .SYNOPSIS
        Guarda la configuración en disco.
    .DESCRIPTION
        Acepta [hashtable] o [PSCustomObject]. Normaliza a [hashtable]
        antes de escribir para que el JSON siempre tenga el mismo formato.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    try {
        $normalizada = ConvertTo-LabConfigHash -Origen $Config
        $normalizada | ConvertTo-Json -Depth 3 | Set-Content -Path $script:LabConfigPath -Encoding UTF8 -Force
        return $true
    } catch {
        Write-LabWarn "No se pudo guardar la configuración: $($_.Exception.Message)"
        return $false
    }
}

function Reset-LabConfig {
    <#
    .SYNOPSIS
        Restaura la configuración a los valores por defecto.
    #>
    $defaults = Get-LabConfigDefaults
    $null = Save-LabConfig -Config $defaults
    return $defaults
}

function Update-LabConfig {
    <#
    .SYNOPSIS
        Actualiza parcialmente la configuración.
    .DESCRIPTION
        Solo se aceptan claves que existan en Get-LabConfigDefaults. Las
        claves desconocidas se rechazan con Write-LabWarn y NO se añaden
        al JSON (evita claves huérfanas).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Cambios
    )

    $config = Get-LabConfig

    $clavesValidas = @((Get-LabConfigDefaults).Keys)
    foreach ($key in $Cambios.Keys) {
        if ($clavesValidas -notcontains $key) {
            Write-LabWarn "Update-LabConfig: clave desconocida '$key' rechazada."
            continue
        }
        $config[$key] = $Cambios[$key]
    }

    $normalizada = ConvertTo-LabConfigHash -Origen $config
    $null = Save-LabConfig -Config $normalizada
    return $normalizada
}

# ============================================================
# HELPERS APP-ONLY
# ============================================================
function Test-LabAppOnlyConfigComplete {
    <#
    .SYNOPSIS
        Devuelve $true si ClientId, TenantId y Thumbprint están completos.
    .DESCRIPTION
        Espera un [hashtable] (el contrato de Get-LabConfig). Si recibe
        otra cosa, avisa y devuelve $false en lugar de intentar
        normalizar en cada llamada.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    if ($Config -isnot [hashtable]) {
        Write-LabWarn "Test-LabAppOnlyConfigComplete: se esperaba [hashtable] pero llegó $($Config.GetType().FullName)."
        return $false
    }

    $clientId   = if ($Config.ContainsKey('ClientId'))              { $Config['ClientId'] }              else { $null }
    $tenantId   = if ($Config.ContainsKey('TenantId'))              { $Config['TenantId'] }              else { $null }
    $thumbprint = if ($Config.ContainsKey('CertificateThumbprint')) { $Config['CertificateThumbprint'] } else { $null }

    if ([string]::IsNullOrWhiteSpace($clientId))   { return $false }
    if ([string]::IsNullOrWhiteSpace($tenantId))   { return $false }
    if ([string]::IsNullOrWhiteSpace($thumbprint)) { return $false }

    return $true
}