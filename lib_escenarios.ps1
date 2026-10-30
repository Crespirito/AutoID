<#
.SYNOPSIS
    Librería de gestión de escenarios y vulnerabilidades del laboratorio.
.DESCRIPTION
    Proporciona:
      - Rutas canónicas a escenarios/escenario/ y escenarios/vulnerab/
      - Listado de escenarios disponibles
      - Carga y validación de un escenario
      - Carga y validación de una vulnerabilidad
      - Aplicación de una vulnerabilidad según su tipo
.NOTES
    Depende de lib_ui.ps1 (funciones Write-Lab*).
    Se carga por dot-sourcing desde creacion_automatica.ps1.

    ESTRUCTURA DE CARPETAS:
      escenarios/
        escenario/   <- un .json por escenario
        vulnerab/    <- un .json por vulnerabilidad
#>

# ============================================================
# RUTAS CANÓNICAS
# ============================================================
$script:LabEscenariosRoot          = Join-Path $PSScriptRoot "escenarios"
$script:LabEscenariosPath          = Join-Path $script:LabEscenariosRoot "escenario"
$script:LabVulnerabilidadesPath    = Join-Path $script:LabEscenariosRoot "vulnerab"

# ============================================================
# FUNCIONES PÚBLICAS: RUTAS
# ============================================================

function Get-LabEscenariosPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de escenarios.
    #>
    return $script:LabEscenariosPath
}

function Get-LabVulnerabilidadesPath {
    <#
    .SYNOPSIS
        Devuelve la ruta absoluta de la carpeta de vulnerabilidades.
    #>
    return $script:LabVulnerabilidadesPath
}

# ============================================================
# FUNCIONES PÚBLICAS: LISTADO Y CARGA
# ============================================================

function Get-LabEscenariosDisponibles {
    <#
    .SYNOPSIS
        Devuelve los nombres (sin extensión) de los escenarios disponibles.
    .OUTPUTS
        Array de strings, ordenado alfabéticamente. Vacío si no hay carpeta o ficheros.
    #>
    if (-not (Test-Path $script:LabEscenariosPath)) {
        return @()
    }
    $files = Get-ChildItem -Path $script:LabEscenariosPath -Filter "*.json" -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabVulnerabilidadesDisponibles {
    <#
    .SYNOPSIS
        Devuelve los nombres (sin extensión) de las vulnerabilidades disponibles.
    .OUTPUTS
        Array de strings, ordenado alfabéticamente. Vacío si no hay carpeta o ficheros.
    #>
    if (-not (Test-Path $script:LabVulnerabilidadesPath)) {
        return @()
    }
    $files = Get-ChildItem -Path $script:LabVulnerabilidadesPath -Filter "*.json" -File -ErrorAction SilentlyContinue
    return @($files | ForEach-Object { $_.BaseName } | Sort-Object)
}

function Get-LabEscenario {
    <#
    .SYNOPSIS
        Carga y valida un escenario por nombre.
    .PARAMETER Nombre
        Nombre del escenario (sin extensión).
    .OUTPUTS
        PSCustomObject normalizado con Usuarios, Grupos, Aplicaciones, Relaciones y Vulnerabilidad.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Nombre
    )

    $path = Join-Path $script:LabEscenariosPath "$Nombre.json"
    if (-not (Test-Path $path)) {
        throw "No existe el escenario '$Nombre' en $($script:LabEscenariosPath)."
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "El escenario '$Nombre' no es un JSON válido: $($_.Exception.Message)"
    }

    # Validación mínima
    if (-not $raw.PSObject.Properties['usuarios'] -and -not $raw.PSObject.Properties['Usuarios']) {
        throw "El escenario '$Nombre' no declara 'usuarios'."
    }
    if (-not $raw.PSObject.Properties['grupos'] -and -not $raw.PSObject.Properties['Grupos']) {
        throw "El escenario '$Nombre' no declara 'grupos'."
    }
    if (-not $raw.PSObject.Properties['aplicaciones'] -and -not $raw.PSObject.Properties['Aplicaciones']) {
        throw "El escenario '$Nombre' no declara 'aplicaciones'."
    }
    if (-not $raw.PSObject.Properties['relaciones'] -and -not $raw.PSObject.Properties['Relaciones']) {
        throw "El escenario '$Nombre' no declara 'relaciones'."
    }

    # Normalizar a arrays y claves en minúscula (compatibilidad con JSON en español o inglés)
    $usuarios     = @(if ($raw.PSObject.Properties['usuarios'])     { $raw.usuarios }     elseif ($raw.PSObject.Properties['Usuarios'])     { $raw.Usuarios }     else { @() })
    $grupos       = @(if ($raw.PSObject.Properties['grupos'])       { $raw.grupos }       elseif ($raw.PSObject.Properties['Grupos'])       { $raw.Grupos }       else { @() })
    $aplicaciones = @(if ($raw.PSObject.Properties['aplicaciones']) { $raw.aplicaciones } elseif ($raw.PSObject.Properties['Aplicaciones']) { $raw.Aplicaciones } else { @() })
    $relaciones   = @(if ($raw.PSObject.Properties['relaciones'])   { $raw.relaciones }   elseif ($raw.PSObject.Properties['Relaciones'])   { $raw.Relaciones }   else { @() })

    $vulnerabilidad = $null
    if ($raw.PSObject.Properties['vulnerabilidad'])     { $vulnerabilidad = $raw.vulnerabilidad }
    elseif ($raw.PSObject.Properties['Vulnerabilidad']) { $vulnerabilidad = $raw.Vulnerabilidad }

    $descripcion = $null
    if ($raw.PSObject.Properties['descripcion'])        { $descripcion = $raw.descripcion }
    elseif ($raw.PSObject.Properties['Descripcion'])    { $descripcion = $raw.Descripcion }

    return [pscustomobject]@{
        Nombre          = $Nombre
        Descripcion     = $descripcion
        Usuarios        = $usuarios
        Grupos          = $grupos
        Aplicaciones    = $aplicaciones
        Relaciones      = $relaciones
        Vulnerabilidad  = $vulnerabilidad
    }
}

function Get-LabVulnerabilidad {
    <#
    .SYNOPSIS
        Carga y valida una vulnerabilidad por nombre.
    .PARAMETER Nombre
        Nombre de la vulnerabilidad (sin extensión).
    .OUTPUTS
        PSCustomObject con nombre, tipo, parametros y requiereLicencia.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Nombre
    )

    $path = Join-Path $script:LabVulnerabilidadesPath "$Nombre.json"
    if (-not (Test-Path $path)) {
        throw "No existe la vulnerabilidad '$Nombre' en $($script:LabVulnerabilidadesPath)."
    }

    try {
        $raw = Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "La vulnerabilidad '$Nombre' no es un JSON válido: $($_.Exception.Message)"
    }

    if (-not $raw.PSObject.Properties['tipo']) {
        throw "La vulnerabilidad '$Nombre' no declara 'tipo'."
    }
    if (-not $raw.PSObject.Properties['parametros']) {
        throw "La vulnerabilidad '$Nombre' no declara 'parametros'."
    }

    $requiereLicencia = $null
    if ($raw.PSObject.Properties['requiereLicencia']) { $requiereLicencia = $raw.requiereLicencia }

    $descripcion = $null
    if ($raw.PSObject.Properties['descripcion']) { $descripcion = $raw.descripcion }

    return [pscustomobject]@{
        Nombre           = $Nombre
        Descripcion      = $descripcion
        Tipo             = $raw.tipo
        Parametros       = $raw.parametros
        RequiereLicencia = $requiereLicencia
    }
}

# ============================================================
# APLICADORES DE VULNERABILIDAD
# ============================================================
# Cada tipo de vulnerabilidad tiene su aplicador. Para añadir un
# tipo nuevo, añade una función y una entrada en el switch de
# Invoke-LabVulnerabilidad. Los escenarios y las vulnerabilidades
# solo referencian el tipo por nombre.

function Invoke-VulnerabilidadServicePrincipalOwner {
    param($Parametros, $Contexto)

    $uKey = $Parametros.usuario
    $aKey = $Parametros.aplicacion

    if (-not $Contexto.Usuarios.ContainsKey($uKey)) {
        throw "Usuario '$uKey' no encontrado en el contexto del escenario."
    }
    if (-not $Contexto.Aplicaciones.ContainsKey($aKey)) {
        throw "Aplicación '$aKey' no encontrada en el contexto del escenario."
    }

    $user = $Contexto.Usuarios[$uKey]
    $app  = $Contexto.Aplicaciones[$aKey]

    $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    New-MgServicePrincipalOwnerByRef -ServicePrincipalId $app.ServicePrincipal.Id -BodyParameter $body -ErrorAction Stop

    return @(
        [pscustomobject]@{
            tipo               = "ServicePrincipalOwner"
            servicePrincipalId = $app.ServicePrincipal.Id
            directoryObjectId  = $user.Id
        }
    )
}

function Invoke-VulnerabilidadApplicationSecret {
    param($Parametros, $Contexto)

    $aKey = $Parametros.aplicacion
    if (-not $Contexto.Aplicaciones.ContainsKey($aKey)) {
        throw "Aplicación '$aKey' no encontrada en el contexto del escenario."
    }
    $app = $Contexto.Aplicaciones[$aKey]

    $cred = @{
        displayName = if ($Parametros.displayName) { $Parametros.displayName } else { "Lab credential" }
        endDateTime = (Get-Date).AddYears(1)
    }
    $result = Add-MgApplicationPassword -ApplicationId $app.Application.Id -PasswordCredential $cred -ErrorAction Stop

    return @(
        [pscustomobject]@{
            tipo          = "ApplicationSecret"
            applicationId = $app.Application.Id
            keyId         = $result.KeyId
        }
    )
}

function Invoke-VulnerabilidadGroupOwner {
    param($Parametros, $Contexto)

    $uKey = $Parametros.usuario
    $gKey = $Parametros.grupo

    if (-not $Contexto.Usuarios.ContainsKey($uKey)) {
        throw "Usuario '$uKey' no encontrado en el contexto del escenario."
    }
    if (-not $Contexto.Grupos.ContainsKey($gKey)) {
        throw "Grupo '$gKey' no encontrado en el contexto del escenario."
    }

    $user  = $Contexto.Usuarios[$uKey]
    $group = $Contexto.Grupos[$gKey]

    $body = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($user.Id)" }
    New-MgGroupOwnerByRef -GroupId $group.Id -BodyParameter $body -ErrorAction Stop

    return @(
        [pscustomobject]@{
            tipo              = "GroupOwner"
            groupId           = $group.Id
            directoryObjectId = $user.Id
        }
    )
}

function Invoke-VulnerabilidadPimEligibleRole {
    param($Parametros, $Contexto)

    # NOTA: requiere licencia P2 y el módulo Microsoft.Graph.Identity.Governance.
    # Se deja como aplicador de ejemplo; si el tenant no lo soporta, lanzará error.
    $uKey = $Parametros.usuario
    $rol  = $Parametros.rol

    if (-not $Contexto.Usuarios.ContainsKey($uKey)) {
        throw "Usuario '$uKey' no encontrado en el contexto del escenario."
    }
    $user = $Contexto.Usuarios[$uKey]

    # Buscar el rol de directorio por nombre
    $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq '$rol'" -ErrorAction Stop
    if (-not $roleDef) { throw "Rol '$rol' no encontrado." }
    if ($roleDef -is [array]) { $roleDef = $roleDef[0] }

    $body = @{
        action           = "adminAssign"
        justification    = "Lab scenario"
        roleDefinitionId = $roleDef.Id
        directoryScopeId = "/"
        principalId      = $user.Id
        scheduleInfo     = @{
            startDateTime = (Get-Date).ToString("o")
            expiration    = @{
                type     = "afterDuration"
                duration = if ($Parametros.duracion) { $Parametros.duracion } else { "PT8H" }
            }
        }
    }
    New-MgRoleManagementDirectoryRoleEligibilityScheduleRequest -BodyParameter $body -ErrorAction Stop | Out-Null

    return @(
        [pscustomobject]@{
            tipo        = "PimEligibleRole"
            principalId = $user.Id
            rol         = $rol
        }
    )
}

function Invoke-LabVulnerabilidad {
    <#
    .SYNOPSIS
        Aplica una vulnerabilidad cargada según su tipo.
    .PARAMETER Vulnerabilidad
        Objeto devuelto por Get-LabVulnerabilidad.
    .PARAMETER Contexto
        Hashtable con TenantDomain, Usuarios, Grupos, Aplicaciones y Manifiesto.
    .OUTPUTS
        Array de objetos afectados (para registrar en el manifiesto).
    #>
    param(
        [Parameter(Mandatory=$true)] [object]$Vulnerabilidad,
        [Parameter(Mandatory=$true)] [hashtable]$Contexto
    )

    switch ($Vulnerabilidad.Tipo) {
        "ServicePrincipalOwner" { return (Invoke-VulnerabilidadServicePrincipalOwner -Parametros $Vulnerabilidad.Parametros -Contexto $Contexto) }
        "ApplicationSecret"     { return (Invoke-VulnerabilidadApplicationSecret     -Parametros $Vulnerabilidad.Parametros -Contexto $Contexto) }
        "GroupOwner"            { return (Invoke-VulnerabilidadGroupOwner            -Parametros $Vulnerabilidad.Parametros -Contexto $Contexto) }
        "PimEligibleRole"       { return (Invoke-VulnerabilidadPimEligibleRole       -Parametros $Vulnerabilidad.Parametros -Contexto $Contexto) }
        default {
            throw "Tipo de vulnerabilidad no soportado: $($Vulnerabilidad.Tipo)"
        }
    }
}