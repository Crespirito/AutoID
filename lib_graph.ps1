<#
.SYNOPSIS
    Librería de gestión de sesión de Microsoft Graph (Exclusivo App-Only).
.DESCRIPTION
    Proporciona:
      - Instalación del módulo Microsoft.Graph si no está presente.
      - Conexión App-Only con certificado (ClientId + TenantId + Thumbprint).
      - Verificación de sesión activa.
      - Estado de la sesión actual.
      - Desconexión limpia.
      - Listado y carga de certificados desde Cert:\CurrentUser\My.
      - Reintento automático de operaciones con backoff para 429/503.
      - Caché de SKUs del tenant (Get-LabSubscribedSku).
      - Dominio verificado del tenant (Get-LabTenantDomain).
      - Nivel real del tenant con distinción entre "sin licencia" y
        "sin permisos" (Get-LabGraphNivelRealStatus).

    Para PowerShell 7 (pwsh):
      - Desactiva WAM (Web Account Manager) para evitar que use la cuenta
        de Windows en lugar del certificado.
      - Forza el flujo estricto App-Only.

    NOTA: La conexión delegada (az login o login interactivo) ha sido
    eliminada de esta versión. Todo el laboratorio funciona con App-Only.
.NOTES
    Depende de lib_ui.ps1 y lib_config.ps1.
    Se carga por dot-sourcing desde menu.ps1.
    Requiere PowerShell 7.
#>
#Requires -Version 7.0

# Set-StrictMode -Version Latest

# ============================================================
# ESTADO INTERNO
# ============================================================
$script:LabGraphRetryMaxIntentos = 5
$script:LabGraphRetryDelayBaseSeg = 1

# Caché de SKUs del tenant
$script:LabSkuCache              = $null
$script:LabSkuCacheTimestamp     = $null
$script:LabSkuCacheTTLSegundos   = 300   # 5 minutos

# Caché del dominio verificado del tenant
$script:LabTenantDomainCache     = $null
$script:LabTenantDomainTimestamp = $null
$script:LabTenantDomainTTLSeg    = 3600  # 1 hora

# ============================================================
# UTILIDADES INTERNAS
# ============================================================

function Test-LabGuid {
    <#
    .SYNOPSIS
        Devuelve $true si la cadena es un GUID válido (con o sin llaves).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Valor
    )

    if ([string]::IsNullOrWhiteSpace($Valor)) { return $false }
    $g = [guid]::Empty
    return [guid]::TryParse($Valor.Trim(), [ref]$g)
}

# ============================================================
# SESIÓN
# ============================================================

function Test-LabGraphSession {
    <#
    .SYNOPSIS
        Devuelve $true si hay una sesión de Graph activa (App-Only).
    #>
    try {
        $ctx = Get-MgContext -ErrorAction Stop
        if ($null -eq $ctx) { return $false }
        if ([string]::IsNullOrWhiteSpace($ctx.TenantId)) { return $false }
        if ($ctx.AuthType -ne 'AppOnly') { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-LabGraphStatus {
    <#
    .SYNOPSIS
        Devuelve un objeto con el estado de la sesión, o $null si no hay.
    #>
    if (-not (Test-LabGraphSession)) { return $null }

    $ctx = Get-MgContext
    return [pscustomobject]@{
        AuthType = $ctx.AuthType
        TenantId = $ctx.TenantId
        ClientId = $ctx.ClientId
        Scopes   = if ($ctx.Scopes) { ($ctx.Scopes -join ', ') } else { '' }
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
        Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
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
        Usa el flujo client credentials con CertificateThumbprint.
        Fuerza la desactivación de WAM (Web Account Manager) para evitar que
        PowerShell 7 use la cuenta de Windows.

        Valida el formato GUID de ClientId y TenantId antes de llamar a
        Connect-MgGraph, para dar un mensaje de error claro en lugar del
        error genérico del SDK.
    .PARAMETER ClientId
        Application (client) ID del registro de la App. Debe ser GUID.
    .PARAMETER TenantId
        Directory (tenant) ID del tenant. Debe ser GUID.
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

    # Validación GUID (N22): ClientId y TenantId
    if (-not (Test-LabGuid -Valor $ClientId)) {
        Write-LabError "ClientId inválido: '$ClientId'. Debe ser un GUID (Application (client) ID)."
        Write-LabInfo 'Usa [S] Gestionar sesión de Graph para corregir la configuración.'
        return $false
    }
    if (-not (Test-LabGuid -Valor $TenantId)) {
        Write-LabError "TenantId inválido: '$TenantId'. Debe ser un GUID (Directory (tenant) ID)."
        Write-LabInfo 'Usa [S] Gestionar sesión de Graph para corregir la configuración.'
        return $false
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

    # Forzar la desactivación de WAM en PowerShell 7
    try {
        $env:AZURE_IDENTITY_DISABLE_WAM = "1"
        if (Get-Command Set-MgGraphOption -ErrorAction SilentlyContinue) {
            Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction SilentlyContinue
        }
    } catch {
        # Si falla, lo ignoramos silenciosamente
    }

    # Verificar que el certificado existe y tiene clave privada
    $certPath = "Cert:\CurrentUser\My\$CertificateThumbprint"
    if (-not (Test-Path -Path $certPath)) {
        Write-LabError "No se encuentra el certificado con Thumbprint '$CertificateThumbprint' en Cert:\CurrentUser\My."
        Write-LabInfo 'Usa [S] Gestionar sesión de Graph para seleccionar o importar un certificado .pfx.'
        return $false
    }

    $cert = Get-Item -Path $certPath -ErrorAction SilentlyContinue
    if ($null -eq $cert -or -not $cert.HasPrivateKey) {
        Write-LabError 'El certificado no tiene clave privada. No sirve para App-Only.'
        Write-LabInfo 'Asegúrate de haber importado el archivo .pfx (no el .cer) con la clave privada.'
        return $false
    }

    try {
        $params = @{
            ClientId              = $ClientId.Trim()
            TenantId              = $TenantId.Trim()
            CertificateThumbprint = $CertificateThumbprint
        }
        if ($NoWelcome) { $params.NoWelcome = $true }

        $null = Connect-MgGraph @params -ErrorAction Stop
    } catch {
        Write-LabError "Fallo al conectar con Microsoft Graph (App-Only): $($_.Exception.Message)"

        if ($_.Exception.Message -match 'Invalid client|unauthorized|401') {
            Write-LabInfo 'Comprueba que el ClientId y el TenantId son correctos y que el certificado está subido en Azure.'
        }
        return $false
    }

    if (-not (Test-LabGraphSession)) {
        Write-LabError 'La conexión se ejecutó pero no hay sesión App-Only válida.'
        Write-LabInfo 'Verifica que el registro de la App tiene los permisos de aplicación correctos y consentimiento de administrador.'
        return $false
    }

    # Al conectar, invalidamos las cachés por si cambia el tenant
    Clear-LabSkuCache
    Clear-LabTenantDomainCache

    $status = Get-LabGraphStatus
    Write-LabOk "Sesión App-Only establecida. Tenant: $($status.TenantId) | ClientId: $($status.ClientId)."
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
    } finally {
        # Limpiar cachés al desconectar
        Clear-LabSkuCache
        Clear-LabTenantDomainCache
    }
}

# ============================================================
# CACHÉ DE SKUs Y DOMINIO DEL TENANT
# ============================================================

function Clear-LabSkuCache {
    <#
    .SYNOPSIS
        Invalida la caché de SKUs del tenant.
    #>
    $script:LabSkuCache          = $null
    $script:LabSkuCacheTimestamp = $null
}

function Clear-LabTenantDomainCache {
    <#
    .SYNOPSIS
        Invalida la caché del dominio verificado del tenant.
    #>
    $script:LabTenantDomainCache     = $null
    $script:LabTenantDomainTimestamp = $null
}

function Get-LabSubscribedSku {
    <#
    .SYNOPSIS
        Devuelve los SKUs suscritos del tenant, con caché en memoria.
    .DESCRIPTION
        Cachea el resultado de Get-MgSubscribedSku durante LabSkuCacheTTLSegundos
        (5 min por defecto) para evitar llamadas repetidas a Graph en cada
        refresco de pantalla.

        IMPORTANTE: no usar -All. En algunas versiones del módulo Graph,
        Get-MgSubscribedSku -All se queda colgado (paginación sin retorno).
        Un tenant tiene pocos SKUs (decenas como mucho), así que la primera
        página contiene todo lo relevante para el laboratorio.
    .PARAMETER Forzar
        Si se especifica, ignora la caché y vuelve a consultar Graph.
    .OUTPUTS
        Array de SKUs (puede estar vacío). Nunca $null.
    #>
    param(
        [switch]$Forzar
    )

    $ahora = Get-Date

    if (-not $Forzar -and
        $null -ne $script:LabSkuCache -and
        $null -ne $script:LabSkuCacheTimestamp -and
        ($ahora - $script:LabSkuCacheTimestamp).TotalSeconds -lt $script:LabSkuCacheTTLSegundos) {
        return $script:LabSkuCache
    }

    try {
        # No usar -All: ver nota en el docstring
        $skus = @(Get-MgSubscribedSku -ErrorAction Stop)
        $script:LabSkuCache          = $skus
        $script:LabSkuCacheTimestamp = $ahora
        return $skus
    } catch {
        # No cacheamos errores: la próxima llamada reintenta
        Clear-LabSkuCache
        throw
    }
}

function Get-LabTenantDomain {
    <#
    .SYNOPSIS
        Devuelve el dominio verificado del tenant (por ejemplo contoso.onmicrosoft.com).
    .DESCRIPTION
        Consulta Get-MgOrganization una sola vez y cachea el resultado.
        Prefiere el dominio marcado como IsDefault entre los VerifiedDomains.
        Si no hay sesión o no se puede consultar, devuelve $null.
    .PARAMETER Forzar
        Si se especifica, ignora la caché y vuelve a consultar Graph.
    .OUTPUTS
        String con el dominio, o $null si no se pudo resolver.
    #>
    param(
        [switch]$Forzar
    )

    if (-not (Test-LabGraphSession)) { return $null }

    $ahora = Get-Date

    if (-not $Forzar -and
        -not [string]::IsNullOrWhiteSpace($script:LabTenantDomainCache) -and
        $null -ne $script:LabTenantDomainTimestamp -and
        ($ahora - $script:LabTenantDomainTimestamp).TotalSeconds -lt $script:LabTenantDomainTTLSeg) {
        return $script:LabTenantDomainCache
    }

    try {
        $orgs = @(Get-MgOrganization -ErrorAction Stop)
        if ($orgs.Count -eq 0) { return $null }
        $org = $orgs[0]

        $dominio = $null
        if ($org.PSObject.Properties['VerifiedDomains'] -and $null -ne $org.VerifiedDomains) {
            foreach ($vd in @($org.VerifiedDomains)) {
                if ($vd.PSObject.Properties['IsDefault'] -and $vd.IsDefault -and
                    $vd.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($vd.Name)) {
                    $dominio = $vd.Name
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($dominio)) {
                foreach ($vd in @($org.VerifiedDomains)) {
                    if ($vd.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($vd.Name) -and
                        ($vd.Name -match '\.onmicrosoft\.com$')) {
                        $dominio = $vd.Name
                        break
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($dominio)) {
                foreach ($vd in @($org.VerifiedDomains)) {
                    if ($vd.PSObject.Properties['Name'] -and -not [string]::IsNullOrWhiteSpace($vd.Name)) {
                        $dominio = $vd.Name
                        break
                    }
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($dominio)) {
            $script:LabTenantDomainCache     = $dominio
            $script:LabTenantDomainTimestamp = $ahora
        }
        return $dominio
    } catch {
        Clear-LabTenantDomainCache
        return $null
    }
}

function Get-LabGraphNivelRealStatus {
    <#
    .SYNOPSIS
        Devuelve el nivel real del tenant con estado detallado.
    .DESCRIPTION
        Esta es la función de lib_graph. No debe colisionar con
        Get-LabNivelRealDelTenantStatus de lib_niveles (que la orquesta).
    .OUTPUTS
        PSCustomObject con Estado, Nivel y Mensaje.
    #>
    if (-not (Test-LabGraphSession)) {
        return [pscustomobject]@{ Estado = 'SinSesion'; Nivel = 'Free'; Mensaje = 'No hay sesión de Graph activa.' }
    }

    try {
        $skus = @(Get-LabSubscribedSku)
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match '403|Forbidden|Authorization_RequestDenied|Insufficient privileges') {
            return [pscustomobject]@{
                Estado  = 'SinPermisos'
                Nivel   = 'Free'
                Mensaje = 'La aplicación no tiene permisos para leer SKUs (Organization.Read.All / Directory.Read.All).'
            }
        }
        return [pscustomobject]@{
            Estado  = 'Error'
            Nivel   = 'Free'
            Mensaje = "No se pudieron consultar los SKUs del tenant: $msg"
        }
    }

    $tieneP1 = $false
    $tieneP2 = $false
    foreach ($sku in $skus) {
        if (-not $sku.PSObject.Properties['ServicePlans'] -or $null -eq $sku.ServicePlans) { continue }
        foreach ($plan in @($sku.ServicePlans)) {
            if ($plan.ProvisioningStatus -ne 'Success') { continue }
            if ($plan.ServicePlanName -eq 'AAD_PREMIUM')    { $tieneP1 = $true }
            if ($plan.ServicePlanName -eq 'AAD_PREMIUM_P2') { $tieneP2 = $true }
        }
    }

    if ($tieneP2) {
        return [pscustomobject]@{ Estado = 'Ok'; Nivel = 'P2'; Mensaje = $null }
    }
    if ($tieneP1) {
        return [pscustomobject]@{ Estado = 'Ok'; Nivel = 'P1'; Mensaje = $null }
    }
    return [pscustomobject]@{ Estado = 'SinLicencia'; Nivel = 'Free'; Mensaje = 'El tenant no tiene licencias P1 ni P2 provisionadas.' }
}

# ============================================================
# CERTIFICADOS
# ============================================================

function Get-LabAvailableCertificates {
    <#
    .SYNOPSIS
        Devuelve los certificados con clave privada de Cert:\CurrentUser\My.
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

            if ($msg -match 'Authorization_RequestDenied|Insufficient privileges|Forbidden') {
                Write-LabError 'Fallo de permisos: La aplicación no tiene los permisos necesarios en Azure o falta el consentimiento de administrador.'
                throw
            }

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