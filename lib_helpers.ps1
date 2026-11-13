# ============================================================
# LIB_HELPERS - Semilla y derivación de contraseñas
# ============================================================
# Funciones compartidas por creauto.ps1, creamanual.ps1 y
# generar_biblioteca.ps1. Antes estaban duplicadas en cada script, lo que
# permitía que la creación y la subida usaran semillas distintas para el
# mismo escenario (contraseñas irreproducibles en el manifiesto).
#
# Depende de: lib_ui.ps1 (Write-LabInfo, Write-LabWarn).
# ============================================================

function Get-LabSecretsDir {
    <#
    .SYNOPSIS
        Devuelve la ruta de la carpeta de secretos locales.
    .DESCRIPTION
        Por defecto es <raíz del proyecto>/escenarios/.secrets. Con -Root se
        usa <Root>/.secrets, que es lo que necesita generar_biblioteca.ps1.
    .PARAMETER Root
        Raíz alternativa del proyecto. Si se omite, se usa la carpeta de este
        script (la raíz del proyecto).
    #>
    param(
        [string]$Root = $null
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = $PSScriptRoot
    }
    return (Join-Path $Root 'escenarios/.secrets')
}

function Protect-LabSeedFile {
    <#
    .SYNOPSIS
        Restringe los permisos de un archivo de semilla al usuario actual.
    .DESCRIPTION
        Solo actúa en Windows. Cualquier fallo se degrada a un aviso: un error
        de ACL no debe abortar la creación del escenario.
    .PARAMETER Path
        Ruta del archivo .seed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            $acl = Get-Acl -LiteralPath $Path
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -LiteralPath $Path -AclObject $acl
        }
    } catch {
        Write-LabWarn "No se pudieron restringir los permisos de $Path : $($_.Exception.Message)"
    }
}

function Get-LabSeed {
    <#
    .SYNOPSIS
        Obtiene o genera la semilla de un escenario.
    .DESCRIPTION
        Si la semilla ya existe la reutiliza tal cual (no se sobrescribe nunca);
        si no, genera 32 bytes aleatorios y los guarda en base64.
    .PARAMETER NombreEscenario
        Nombre del escenario; da nombre al archivo .seed.
    .PARAMETER Root
        Raíz alternativa del proyecto.
    .OUTPUTS
        Byte[] con la semilla.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$NombreEscenario,

        [string]$Root = $null
    )

    $seedDir = Get-LabSecretsDir -Root $Root
    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }

    $seedPath = Join-Path $seedDir "$NombreEscenario.seed"

    if (Test-Path -Path $seedPath) {
        $b64 = (Get-Content -LiteralPath $seedPath -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($b64)) {
            try {
                return ,[Convert]::FromBase64String($b64)
            } catch {
                Write-LabWarn "Semilla corrupta en $seedPath ; se regenera."
            }
        }
    }

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }

    Set-Content -LiteralPath $seedPath -Value ([Convert]::ToBase64String($bytes)) -Encoding UTF8 -Force
    Protect-LabSeedFile -Path $seedPath

    Write-LabInfo "Semilla generada para '$NombreEscenario' en $seedPath"
    return ,$bytes
}

function New-LabPasswordFromSeed {
    <#
    .SYNOPSIS
        Deriva una contraseña determinista a partir de la semilla y el UPN.
    .DESCRIPTION
        HMAC-SHA256(semilla, upn en minúsculas) -> base64 -> 16 caracteres
        alfanuméricos + sufijo '!Aa1' que cumple los requisitos de complejidad.
        Misma semilla + mismo UPN = misma contraseña, siempre.
    .PARAMETER Semilla
        Byte[] devuelto por Get-LabSeed.
    .PARAMETER Upn
        UPN del usuario.
    .OUTPUTS
        String con la contraseña.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Semilla,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Upn
    )

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $Semilla
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Upn.ToLowerInvariant()))
    } finally {
        $hmac.Dispose()
    }

    $b64 = [Convert]::ToBase64String($hash)
    $limpio = ($b64 -replace '[^A-Za-z0-9]', '')
    if ($limpio.Length -lt 16) {
        # No debería ocurrir con SHA-256 (43 caracteres útiles), pero StrictMode
        # no perdona un Substring fuera de rango.
        throw "Derivación de contraseña imposible para '$Upn'."
    }
    $core = $limpio.Substring(0, 16)
    return "$core!Aa1"
}
