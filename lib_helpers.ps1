<#
.SYNOPSIS
    Helpers compartidos por creauto.ps1 y creamanual.ps1.
.DESCRIPTION
    Centraliza lo que antes cada script redefinía por su cuenta (y se pisaban
    entre sí al ejecutarse desde menu.ps1):
      - acceso seguro a propiedades (Get-LabPropSegura)
      - dominio del tenant con fallback (Get-LabTenantDomainSafe)
      - semilla por escenario (Get-LabSeed) y derivación de contraseñas
    Requiere PowerShell 7 y lib_ui.ps1 cargada.
#>
#Requires -Version 7.0

function Get-LabSecretsDir {
    return (Join-Path $PSScriptRoot 'escenarios/.secrets')
}


function Get-LabPropSegura {
    <#
    .SYNOPSIS
        Devuelve el valor de una propiedad de un objeto, o $null si no existe.
    .DESCRIPTION
        Evita errores de StrictMode cuando se accede a propiedades que
        pueden no existir. Acepta objetos PSCustomObject y Hashtable.
    #>
    param(
        [Parameter(Mandatory = $true)] $Objeto,
        [Parameter(Mandatory = $true)] [string]$Nombre,
        $PorDefecto = $null
    )

    if ($null -eq $Objeto) { return $PorDefecto }

    if ($Objeto -is [hashtable]) {
        if ($Objeto.ContainsKey($Nombre)) {
            $v = $Objeto[$Nombre]
            if ($null -ne $v) { return $v }
            return $PorDefecto
        }
        return $PorDefecto
    }

    if ($Objeto.PSObject.Properties[$Nombre]) {
        $v = $Objeto.$Nombre
        if ($null -ne $v) { return $v }
        return $PorDefecto
    }

    return $PorDefecto
}

function Get-LabTenantDomainSafe {
    <#
    .SYNOPSIS
        Devuelve el dominio verificado del tenant con fallback a TenantId.
    #>
    $dominio = $null
    try {
        $dominio = Get-LabTenantDomain
    } catch {
        $dominio = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($dominio)) {
        return $dominio
    }
    try {
        $ctx = Get-MgContext
        if ($ctx -and -not [string]::IsNullOrWhiteSpace($ctx.TenantId)) {
            return $ctx.TenantId
        }
    } catch { }
    return $null
}

function Get-LabSeed {
    param([Parameter(Mandatory = $true)][string]$NombreEscenario)

    $seedPath = Join-Path (Get-LabSecretsDir) "$NombreEscenario.seed"
    $seedDir = Split-Path -Path $seedPath -Parent

    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }

    if (Test-Path -Path $seedPath) {
        $b64 = (Get-Content -Path $seedPath -Raw -Encoding UTF8).Trim()
        return [Convert]::FromBase64String($b64)
    }

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    $b64 = [Convert]::ToBase64String($bytes)
    Set-Content -Path $seedPath -Value $b64 -Encoding UTF8 -Force

    Write-LabInfo "Semilla generada para '$NombreEscenario' en $seedPath"
    return $bytes
}

function New-LabPasswordFromSeed {
    param(
        [Parameter(Mandatory = $true)] [byte[]]$Semilla,
        [Parameter(Mandatory = $true)] [string]$Upn
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $Semilla
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Upn.ToLowerInvariant()))
    } finally {
        $hmac.Dispose()
    }

    $b64 = [Convert]::ToBase64String($hash)
    $core = ($b64 -replace '[^A-Za-z0-9]', '').Substring(0, 16)
    return "$core!Aa1"
}
