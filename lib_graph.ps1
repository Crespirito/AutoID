<#
.SYNOPSIS
    Librería de gestión de sesión de Microsoft Graph.
.DESCRIPTION
    Proporciona:
      - Instalación del módulo Microsoft.Graph si no está presente.
      - Conexión App-Only con certificado (ClientId + TenantId + Thumbprint).
      - Conexión delegada vía az login (token de Azure CLI).
      - Verificación de sesión activa (App-Only o Delegated).
      - Estado de la sesión actual.
      - Desconexión limpia.
      - Listado y carga de certificados desde Cert:\CurrentUser\My.
      - Reintento automático de operaciones con backoff para 429/503.
.NOTES
    Depende de lib_ui.ps1 y lib_config.ps1.
    Se carga por dot-sourcing desde menu.ps1.

    MODOS DE CONEXIÓN:
    1. App-Only con certificado (por defecto):
       Connect-MgGraph -ClientId ... -TenantId ... -CertificateThumbprint ...
       El certificado debe estar en Cert:\CurrentUser\My con clave privada.

    2. Delegado vía az login (opcional):
       Obtiene un token de Graph con az account get-access-token y lo pasa
       a Connect-MgGraph -AccessToken. Requiere Azure CLI instalado y una
       sesión de az login activa. Los permisos son los del usuario, no los
       de la App registrada.
#>

# ============================================================
# ESTADO INTERNO
# ============================================================
$script:LabGraphRetryMaxIntentos = 5
$script:LabGraphRetryDelayBaseSeg = 1

# ============================================================
# SESIÓN
# ============================================================

function Test-LabGraphSession {
    <#
    .SYNOPSIS
        Devuelve $true si hay una sesión de Graph activa (App-Only o Delegated).
    .DESCRIPTION
        Verifica que Get-MgContext devuelve un contexto con TenantId y
        AuthType 'AppOnly' o 'Delegated'. En versiones anteriores solo se
        aceptaba AppOnly; ahora también se acepta Delegated para permitir
        la conexión vía az login.
    #>
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if ($null -eq $ctx) { return $false }
        if ([string]::IsNullOrWhiteSpace($ctx.TenantId)) { return $false }
        if ($ctx.AuthType -notin @('AppOnly','Delegated')) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-LabGraphStatus {
    <#
    .SYNOPSIS
        Devuelve un objeto con el estado de la sesión, o $null si no hay.
    .OUTPUTS
        PSCustomObject con AuthType, TenantId, ClientId y Scopes, o $null.
    #>
    if (-not (Test-LabGraphSession)) { return $null }

    $ctx = Get-MgContext
    return [pscustomobject]@{
        AuthType = $ctx.AuthType
        TenantId = $ctx.TenantId
        ClientId = $ctx.ClientId
        Scopes   = ($ctx.Scopes -join ', ')
    }
}

function Install-LabGraphModule {
    <#
    .SYNOPSIS
        Instala el módulo Microsoft.Graph si no está disponible.
    #>
    if (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue) {
        return $true
    }

    Write-LabWarn 'Módulo Microsoft.Graph no encontrado. Instalando desde PSGallery (puede tardar)...'

    try {
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
        Write-LabOk 'Módulo Microsoft.Graph instalado.'
        return $true
    } catch {
        Write-LabError "No se pudo instalar Microsoft.Graph: $($_.Exception.Message)"
        return $false
    }
}

function Connect-LabGraph {
    <#
    .SYNOPSIS
        Conecta a Microsoft Graph en modo App-Only con certificado.
    .DESCRIPTION
        Usa el flujo client credentials con CertificateThumbprint. El
        certificado debe estar en Cert:\CurrentUser\My con clave privada.
        No se pasan scopes: los permisos se configuran en el registro
        de la App en Entra ID y se conceden con consentimiento de admin.
    .PARAMETER ClientId
        Application (client) ID del registro de la App.
    .PARAMETER TenantId
        Directory (tenant) ID del tenant.
    .PARAMETER CertificateThumbprint
        Thumbprint del certificado en Cert:\CurrentUser\My.
    .PARAMETER NoWelcome
        Si se especifica, no muestra el mensaje de bienvenida de Graph.
    .OUTPUTS
        $true si la conexión se estableció correctamente, $false si falló.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$CertificateThumbprint,

        [switch]$NoWelcome
    )

    if (Test-LabGraphSession) {
        Write-LabInfo 'Ya hay una sesión de Graph activa. Reutilizándola.'
        return $true
    }

    if (-not (Install-LabGraphModule)) {
        return $false
    }

    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    } catch {
        Write-LabError "No se pudo importar Microsoft.Graph.Authentication: $($_.Exception.Message)"
        return $false
    }

    # Verificar que el certificado existe y tiene clave privada
    $certPath = "Cert:\CurrentUser\My\$CertificateThumbprint"
    if (-not (Test-Path -Path $certPath)) {
        Write-LabError "No se encuentra el certificado con Thumbprint '$CertificateThumbprint' en Cert:\CurrentUser\My."
        Write-LabInfo 'Usa [C] Gestionar sesión de Graph para seleccionar o importar un certificado.'
        return $false
    }

    $cert = Get-Item -Path $certPath -ErrorAction SilentlyContinue
    if ($null -eq $cert -or -not $cert.HasPrivateKey) {
        Write-LabError 'El certificado no tiene clave privada. No sirve para App-Only.'
        return $false
    }

    try {
        $params = @{
            ClientId              = $ClientId
            TenantId              = $TenantId
            CertificateThumbprint = $CertificateThumbprint
        }
        if ($NoWelcome) { $params.NoWelcome = $true }

        $null = Connect-MgGraph @params -ErrorAction Stop
    } catch {
        Write-LabError "Fallo al conectar con Microsoft Graph (App-Only): $($_.Exception.Message)"
        return $false
    }

    if (-not (Test-LabGraphSession)) {
        Write-LabError 'La conexión se ejecutó pero no hay sesión App-Only válida.'
        Write-LabInfo 'Verifica que el registro de la App tiene los permisos de aplicación correctos y consentimiento de administrador.'
        return $false
    }

    $status = Get-LabGraphStatus
    Write-LabOk "Sesión App-Only establecida. Tenant: $($status.TenantId) | ClientId: $($status.ClientId)."
    return $true
}

function Connect-LabGraphConAzLogin {
    <#
    .SYNOPSIS
        Conecta a Graph usando un token obtenido con az login.
    .DESCRIPTION
        Obtiene un token de Graph con az account get-access-token y lo pasa
        a Connect-MgGraph -AccessToken. Requiere Azure CLI instalado y que
        el operador haya ejecutado az login previamente. La sesión resultante
        es delegada (AuthType = 'Delegated') y usa los permisos del usuario.
    .OUTPUTS
        $true si la conexión se estableció correctamente, $false si falló.
    #>
    # 1. Comprobar que az está disponible
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-LabError 'Azure CLI (az) no está instalado o no está en el PATH.'
        Write-LabInfo 'Instala Azure CLI y ejecuta "az login" antes de usar esta opción.'
        return $false
    }

    # 2. Comprobar que hay una sesión de az activa
    try {
        $azAccount = az account show --output json 2>$null | ConvertFrom-Json
    } catch {
        $azAccount = $null
    }
    if ($null -eq $azAccount) {
        Write-LabWarn 'No hay sesión de Azure CLI activa. Ejecuta "az login" primero.'
        return $false
    }

    Write-LabInfo "Usuario de Azure CLI: $($azAccount.user.name) | Tenant: $($azAccount.tenantId)"

    # 3. Obtener el token de Graph
    try {
        $tokenJson = az account get-access-token --resource-type ms-graph --output json 2>$null | ConvertFrom-Json
        $token = $tokenJson.accessToken
    } catch {
        Write-LabError "No se pudo obtener el token de Graph con az: $($_.Exception.Message)"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-LabError 'az devolvió un token vacío.'
        return $false
    }

    # 4. Conectar con el token
    try {
        $secureToken = ConvertTo-SecureString -String $token -AsPlainText -Force
        $null = Connect-MgGraph -AccessToken $secureToken -NoWelcome -ErrorAction Stop
    } catch {
        Write-LabError "No se pudo conectar a Graph con el token de az: $($_.Exception.Message)"
        return $false
    }

    # 5. Verificar que la sesión es válida
    if (-not (Test-LabGraphSession)) {
        Write-LabError 'La conexión se ejecutó pero no hay sesión válida.'
        return $false
    }

    $status = Get-LabGraphStatus
    Write-LabOk "Sesión establecida vía az login. Usuario: $($azAccount.user.name) | Tenant: $($status.TenantId)"
    Write-LabInfo 'Nota: esta sesión es delegada. Los permisos son los del usuario, no los de la App registrada.'
    return $true
}

function Disconnect-LabGraph {
    <#
    .SYNOPSIS
        Cierra la sesión de Graph si existe. No falla si no hay sesión.
    #>
    if (-not (Test-LabGraphSession)) {
        return
    }

    try {
        $null = Disconnect-MgGraph -ErrorAction Stop
        Write-LabInfo 'Sesión de Microsoft Graph cerrada.'
    } catch {
        Write-LabWarn "No se pudo cerrar la sesión limpiamente: $($_.Exception.Message)"
    }
}

# ============================================================
# CERTIFICADOS
# ============================================================

function Get-LabAvailableCertificates {
    <#
    .SYNOPSIS
        Devuelve los certificados con clave privada de Cert:\CurrentUser\My.
    .OUTPUTS
        Array de X509Certificate2, ordenado por NotAfter.
    #>
    $store = 'Cert:\CurrentUser\My'
    if (-not (Test-Path -Path $store)) { return @() }

    return @(
        Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey } |
        Sort-Object -Property NotAfter
    )
}

function Import-LabPfxCertificate {
    <#
    .SYNOPSIS
        Pide una ruta .pfx, la importa a Cert:\CurrentUser\My y devuelve el certificado.
    .DESCRIPTION
        Si el .pfx tiene contraseña, se pide con Read-Host -AsSecureString.
        Se importa con Import-PfxCertificate, que deja el certificado en el
        store del usuario actual con su clave privada.
    .OUTPUTS
        El objeto X509Certificate2 importado, o $null si falla.
    #>
    param(
        [string]$Ruta = $null,
        [System.Security.SecureString]$Password = $null
    )

    if ([string]::IsNullOrWhiteSpace($Ruta)) {
        $Ruta = Read-Host '  Ruta del fichero .pfx'
    }
    if ([string]::IsNullOrWhiteSpace($Ruta)) {
        Write-LabWarn 'Ruta vacía. Cancelando.'
        return $null
    }
    if (-not (Test-Path -Path $Ruta)) {
        Write-LabError "No existe el fichero: $Ruta"
        return $null
    }

    if ($null -eq $Password) {
        $Password = Read-Host '  Contraseña del .pfx (Enter si no tiene)' -AsSecureString
    }
    if ($null -eq $Password) {
        $Password = [System.Security.SecureString]::new()
    }

    try {
        $imported = Import-PfxCertificate -FilePath $Ruta -CertStoreLocation 'Cert:\CurrentUser\My' -Password $Password -ErrorAction Stop
    } catch {
        Write-LabError "No se pudo importar el .pfx: $($_.Exception.Message)"
        return $null
    }

    if ($imported -is [array]) { $imported = $imported[0] }
    if (-not $imported.HasPrivateKey) {
        Write-LabError 'El certificado importado no tiene clave privada. No sirve para App-Only.'
        return $null
    }

    Write-LabOk "Certificado importado: $($imported.Thumbprint)"
    return $imported
}

# ============================================================
# REINTENTOS CON BACKOFF
# ============================================================

function Invoke-LabGraphWithRetry {
    <#
    .SYNOPSIS
        Ejecuta un bloque de código con reintentos y backoff para 429/503.
    .DESCRIPTION
        Si la sesión no está activa, reconecta con los datos App-Only.
        Si la llamada falla con 429 (Too Many Requests) o 503 (Service
        Unavailable), espera con backoff exponencial y reintenta hasta
        LabGraphRetryMaxIntentos.
    .PARAMETER ScriptBlock
        Bloque de código a ejecutar.
    .PARAMETER ClientId
        ClientId para la reconexión.
    .PARAMETER TenantId
        TenantId para la reconexión.
    .PARAMETER CertificateThumbprint
        Thumbprint del certificado para la reconexión.
    .OUTPUTS
        Resultado del scriptblock, o $null si falla tras los reintentos.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$CertificateThumbprint
    )

    if (-not (Test-LabGraphSession)) {
        Write-LabWarn 'Sesión expirada o inexistente. Reconectando con App-Only...'
        $ok = Connect-LabGraph `
            -ClientId              $ClientId `
            -TenantId              $TenantId `
            -CertificateThumbprint $CertificateThumbprint `
            -NoWelcome
        if (-not $ok) {
            Write-LabError 'No se pudo reconectar. Operación cancelada.'
            return $null
        }
    }

    $intento = 0
    while ($true) {
        $intento++
        try {
            return (& $ScriptBlock)
        } catch {
            $msg = $_.Exception.Message
            $esTransitorio = ($msg -match '429|503|504|Too Many Requests|Service Unavailable|throttl')

            if (-not $esTransitorio -or $intento -ge $script:LabGraphRetryMaxIntentos) {
                throw
            }

            $delay = [math]::Pow(2, $intento - 1) * $script:LabGraphRetryDelayBaseSeg
            Write-LabWarn "Error transitorio (intento $intento/$($script:LabGraphRetryMaxIntentos)). Reintentando en $delay s: $msg"
            Start-Sleep -Seconds $delay
        }
    }
}