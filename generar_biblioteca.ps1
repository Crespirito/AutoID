<#
.SYNOPSIS
    Generador de biblioteca de datos y escenarios de ejemplo para Entra ID.
.DESCRIPTION
    Genera directamente en las rutas que el programa lee:
      - escenarios/escenario/*.json    -> escenarios de ejemplo
      - escenarios/vulnerab/*.json     -> catalogo de vulnerabilidades por nombre
      - escenarios/plantillas/*.json   -> plantillas para el flujo nivel -> tipo
      - escenarios/.secrets/*.seed     -> semillas locales (no sobrescribe)
      - biblioteca.json                -> biblioteca de datos para inspeccion

    IMPORTANTE SOBRE VULNERABILIDADES:
    Los escenarios generados NO contienen seccion 'vulnerabilidades' ni
    'vulnerabilidad'. Las vulnerabilidades no son parte del escenario: son
    modificaciones maliciosas que se aplican sobre objetos existentes y se
    crean desde menu.ps1 [5] Crear vulnerabilidad.

    El catalogo escenarios/vulnerab/*.json se mantiene como referencia: cada
    archivo declara una vulnerabilidad por nombre (tipo + parametros). Si en
    el futuro se quiere cargar una vulnerabilidad por nombre desde [5], ahi
    esta la fuente.

    FILTRADO POR NIVEL:
    El parametro -Nivel controla que secciones se generan en los escenarios:
      - Free: usuarios, grupos, aplicaciones, appRoles, credencialesApp,
              permisosApi, invitados, relaciones.
      - P1:   anade administrativeUnits, gruposDinamicos,
              gruposRoleAssignable, licencias, accesoCondicional, metodosAuth.
      - P2:   anade pim.
      - Auto: detecta el nivel consultando Get-MgSubscribedSku si hay sesion.
              Si no hay sesion, cae a 'Free' con aviso.

    SEGURIDAD:
    - Los JSON NO contienen contrasenas ni secretos. Las contrasenas se
      derivan de la semilla en creauto.ps1 / creamanual.ps1. Los secretos
      de app se generan en la creacion y se muestran una sola vez.
    - Las politicas de Acceso Condicional se generan en estado 'disabled'.
    - Las semillas existentes NO se sobrescriben.
.PARAMETER Seed
    Semilla para el generador aleatorio de datos (nombres, apellidos).
    NO es la semilla de contrasenas.
.PARAMETER Nivel
    Nivel de licencia: 'Auto', 'Free', 'P1' o 'P2'. Por defecto 'Auto'.
.PARAMETER OutDir
    Carpeta raiz de salida. Por defecto, escenarios/ junto al script.
.NOTES
    Autocontenido. No depende de lib_*.ps1.
#>
[CmdletBinding()]
param(
    [int]$Seed = 42,
    [ValidateSet('Auto','Free','P1','P2')]
    [string]$Nivel = 'Auto',
    [string]$OutDir = (Join-Path $PSScriptRoot 'escenarios')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# HELPERS LOCALES (no dependen de lib_ui.ps1)
# ============================================================
function Write-InfoLocal { param([string]$Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Gray }
function Write-OkLocal   { param([string]$Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-WarnLocal { param([string]$Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }

# ============================================================
# DETECCIÓN DE NIVEL
# ============================================================
function Get-LabNivelDetectado {
    <#
    .SYNOPSIS
        Detecta el nivel del tenant consultando los SKUs suscritos.
        Si no hay sesion o falla, devuelve 'Free'.
    #>
    try {
        if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
            Write-WarnLocal 'Sin sesion de Graph. No se puede detectar el nivel; se usa Free.'
            return 'Free'
        }
        $skus = Get-MgSubscribedSku -ErrorAction Stop
        $tieneP1 = $false
        $tieneP2 = $false
        foreach ($sku in @($skus)) {
            foreach ($plan in @($sku.ServicePlans)) {
                if ($plan.ProvisioningStatus -ne 'Success') { continue }
                if ($plan.ServicePlanName -eq 'AAD_PREMIUM')    { $tieneP1 = $true }
                if ($plan.ServicePlanName -eq 'AAD_PREMIUM_P2') { $tieneP2 = $true }
            }
        }
        if ($tieneP2) { return 'P2' }
        if ($tieneP1) { return 'P1' }
        return 'Free'
    } catch {
        Write-WarnLocal "No se pudo detectar el nivel: $($_.Exception.Message). Se usa Free."
        return 'Free'
    }
}

if ($Nivel -eq 'Auto') {
    $Nivel = Get-LabNivelDetectado
}
Write-InfoLocal "Nivel de generacion: $Nivel"

# ============================================================
# SEMILLAS LOCALES
# ============================================================
function Get-LabSecretsDir {
    param([string]$Root)
    return (Join-Path $Root '.secrets')
}

function New-LabSeedIfMissing {
    <#
    .SYNOPSIS
        Crea la semilla local de un escenario si no existe. No sobrescribe.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] [string]$NombreEscenario
    )

    $seedDir = Get-LabSecretsDir -Root $Root
    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }
    $seedPath = Join-Path $seedDir "$NombreEscenario.seed"

    if (Test-Path -Path $seedPath) {
        Write-InfoLocal "Semilla existente para '$NombreEscenario'; no se sobrescribe."
        return $seedPath
    }

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($bytes)
    Set-Content -Path $seedPath -Value $b64 -Encoding UTF8 -Force

    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
            $acl = Get-Acl -Path $seedPath
            $acl.SetAccessRuleProtection($true, $false)
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
                'FullControl',
                'Allow'
            )
            $acl.SetAccessRule($rule)
            Set-Acl -Path $seedPath -AclObject $acl
        }
    } catch {
        Write-WarnLocal "No se pudieron restringir los permisos de $seedPath : $($_.Exception.Message)"
    }

    Write-InfoLocal "Semilla generada para '$NombreEscenario'."
    return $seedPath
}

# ============================================================
# DATOS BASE
# ============================================================
$Nombres = @(
    'Lucia','Javier','Maria','Carlos','Elena','Pablo','Sara','Alberto','Carmen','David',
    'Laura','Sergio','Ana','Jorge','Marta','Raul','Paula','Ivan','Nuria','Adrian'
)
$Apellidos = @(
    'Garcia','Martinez','Lopez','Sanchez','Perez','Gomez','Fernandez','Ruiz','Diaz','Moreno',
    'Alvarez','Romero','Jimenez','Navarro','Torres','Dominguez','Vazquez','Ramos','Gil','Serrano'
)
$Departamentos = @(
    'Ventas','IT','RRHH','Finanzas','Produccion','Almacen','Calidad','Compras','Marketing','Legal'
)
$Puestos = @(
    'Comercial','Administrador de Sistemas','Tecnico de RRHH','Analista Financiero','Operario',
    'Responsable de Almacen','Tecnico de Calidad','Comprador','Especialista Marketing','Asesor Legal'
)
$RolesEntra = @(
    'Global Administrator','Application Administrator','Cloud Application Administrator',
    'User Administrator','Groups Administrator','Helpdesk Administrator',
    'Privileged Role Administrator','Security Administrator','Exchange Administrator',
    'SharePoint Administrator'
)
$RolesAzure = @(
    'Owner','Contributor','Reader','Key Vault Contributor','Storage Account Contributor',
    'Virtual Machine Contributor','Website Contributor','Logic App Contributor',
    'Monitoring Contributor','Network Contributor'
)

$rng = [System.Random]::new($Seed)
function Get-RandomItem { param([array]$Lista) return $Lista[$rng.Next(0, $Lista.Count)] }

# ============================================================
# GENERACIÓN DE USUARIOS (sin contrasenas)
# ============================================================
$usuarios = @()
$usados = [System.Collections.Generic.HashSet[string]]::new()
$i = 0
while ($usuarios.Count -lt 10) {
    $nombre   = Get-RandomItem -Lista $Nombres
    $apellido = Get-RandomItem -Lista $Apellidos
    $nick     = ($nombre.ToLower() + '.' + $apellido.Substring(0, 1).ToLower())
    if (-not $usados.Add($nick)) { continue }
    $deptIdx = $i % $Departamentos.Count
    $usuarios += [ordered]@{
        displayName  = "$nombre $apellido"
        upn          = "$nick@{tenant}"
        mailNickname = $nick
        department   = $Departamentos[$deptIdx]
        jobTitle     = $Puestos[$deptIdx]
    }
    $i++
}

# ============================================================
# GENERACIÓN DE GRUPOS
# ============================================================
$grupos = @()
foreach ($d in $Departamentos) {
    $grupos += [ordered]@{
        displayName  = "Departamento de $d"
        description  = "Usuarios del departamento de $d"
        mailNickname = ('departamento-' + $d.ToLower())
    }
}

# ============================================================
# GENERACIÓN DE APLICACIONES
# ============================================================
$nombresApps = @(
    'Panel de Analisis Comercial','Portal de RRHH','Gestion de Almacen','ERP Financiero',
    'Herramienta de Calidad','Portal de Compras','CRM Marketing','Gestion Legal',
    'Dashboard Produccion','API Interna'
)
$aplicaciones = @()
foreach ($a in $nombresApps) {
    $aplicaciones += [ordered]@{
        displayName    = $a
        description    = "Aplicacion interna: $a"
        signInAudience = 'AzureADMyOrg'
        redirectUris   = @('https://' + ($a -replace '[^a-zA-Z0-9]', '').ToLower() + '.empresa.local/callback')
    }
}

# ============================================================
# GENERACIÓN DE ROLES (Entra + Azure RBAC)
# ============================================================
$roles = @()
foreach ($r in $RolesEntra) { $roles += [ordered]@{ tipo = 'EntraRole'; nombre = $r } }
foreach ($r in $RolesAzure) { $roles += [ordered]@{ tipo = 'AzureRBAC'; nombre = $r } }

# ============================================================
# BIBLIOTECA (inspeccion)
# ============================================================
$biblioteca = [ordered]@{
    generado      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    seed          = $Seed
    nivel         = $Nivel
    usuarios      = $usuarios
    grupos        = $grupos
    aplicaciones  = $aplicaciones
    roles         = $roles
    departamentos = $Departamentos
    puestos       = $Puestos
}

# ============================================================
# CONSTRUCCIÓN DE ESCENARIOS
# ============================================================
function New-EscenarioBase {
    <#
    .SYNOPSIS
        Construye un escenario de ejemplo con secciones Free y, si el
        nivel lo permite, secciones P1 y P2.

        IMPORTANTE: los escenarios NO incluyen vulnerabilidades. No son
        parte del escenario. Se aplican desde menu.ps1 [5].
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Nombre,
        [Parameter(Mandatory = $true)] [string]$Descripcion,
        [Parameter(Mandatory = $true)] [int]$NumUsuarios,
        [Parameter(Mandatory = $true)] [int]$NumGrupos,
        [Parameter(Mandatory = $true)] [int]$NumApps,
        [Parameter(Mandatory = $true)] [int]$OffsetUsuarios,
        [Parameter(Mandatory = $true)] [int]$OffsetGrupos,
        [Parameter(Mandatory = $true)] [int]$OffsetApps,
        [Parameter(Mandatory = $true)] [string]$NivelActual
    )

    $us = @()
    for ($k = 0; $k -lt $NumUsuarios; $k++) { $us += $usuarios[($OffsetUsuarios + $k) % $usuarios.Count] }

    $gr = @()
    for ($k = 0; $k -lt $NumGrupos; $k++) { $gr += $grupos[($OffsetGrupos + $k) % $grupos.Count] }

    $ap = @()
    for ($k = 0; $k -lt $NumApps; $k++) { $ap += $aplicaciones[($OffsetApps + $k) % $aplicaciones.Count] }

    $rels = @()
    for ($k = 0; $k -lt $us.Count; $k++) {
        $rels += [ordered]@{
            tipo    = 'membresia'
            usuario = $us[$k].upn
            grupo   = $gr[$k % $gr.Count].displayName
        }
    }

    $esc = [ordered]@{
        nombre         = $Nombre
        descripcion    = $Descripcion
        usuarios       = $us
        grupos         = $gr
        aplicaciones   = $ap
        relaciones     = $rels
    }

    if ($ap.Count -gt 0 -and $us.Count -gt 0) {
        $esc['appRoles'] = @(
            [ordered]@{
                aplicacion         = $ap[0].displayName
                displayName        = 'Administrador'
                value              = 'Admin'
                allowedMemberTypes = @('User')
            },
            [ordered]@{
                aplicacion = $ap[0].displayName
                value      = 'Admin'
                principal  = $us[0].upn
            }
        )
    }

    if ($ap.Count -gt 0) {
        $esc['credencialesApp'] = @(
            [ordered]@{
                aplicacion  = $ap[0].displayName
                displayName = 'Lab secret'
                endDateTime = (Get-Date).AddYears(1).ToString('o')
            }
        )
    }

    if ($ap.Count -gt 0) {
        $esc['permisosApi'] = @(
            [ordered]@{
                aplicacion = $ap[0].displayName
                recurso    = 'Microsoft Graph'
                permiso    = 'User.Read.All'
                tipo       = 'application'
            },
            [ordered]@{
                aplicacion = $ap[0].displayName
                recurso    = 'Microsoft Graph'
                permiso    = 'Group.Read.All'
                tipo       = 'delegated'
            }
        )
    }

    $esc['invitados'] = @(
        [ordered]@{
            email       = "invitado.$($Nombre)@contoso.com"
            displayName = "Invitado $($Nombre)"
        }
    )

    if ($NivelActual -in @('P1','P2')) {
        if ($us.Count -gt 0 -and $gr.Count -gt 0) {
            $esc['administrativeUnits'] = @(
                [ordered]@{
                    displayName = "AU $($Nombre)"
                    description = "Unidad administrativa de $($Nombre)"
                    members     = @($us[0].upn, $gr[0].displayName)
                    roles       = @()
                }
            )
        }

        $esc['gruposDinamicos'] = @(
            [ordered]@{
                displayName     = "Dinamico $($Nombre) - Guests"
                description     = 'Grupo dinamico de invitados'
                membershipRule  = '(user.userType -eq "Guest")'
                processingState = 'On'
            }
        )

        $esc['gruposRoleAssignable'] = @(
            [ordered]@{
                displayName = "RoleAssignable $($Nombre)"
                description = 'Grupo con asignacion de roles'
            }
        )

        if ($us.Count -gt 0) {
            $esc['licencias'] = @(
                [ordered]@{
                    usuario       = $us[0].upn
                    skuPartNumber = 'ENTERPRISEPACK'
                }
            )
        }

        $esc['accesoCondicional'] = @(
            [ordered]@{
                displayName = "CA $($Nombre) - MFA para admins"
                state       = 'disabled'
                conditions  = [ordered]@{
                    users        = @{ includeRoles = @('62e90394-69f5-4237-9190-012177145e10') }
                    applications = @{ includeApplications = @('All') }
                }
                grantControls = [ordered]@{
                    operator        = 'OR'
                    builtInControls = @('mfa')
                }
            }
        )

        if ($us.Count -gt 0) {
            $esc['metodosAuth'] = @(
                [ordered]@{
                    usuario           = $us[0].upn
                    lifetimeInMinutes = 60
                    isUsableOnce      = $true
                }
            )
        }
    }

    if ($NivelActual -eq 'P2') {
        if ($us.Count -gt 0) {
            $esc['pim'] = @(
                [ordered]@{
                    usuario  = $us[0].upn
                    rol      = 'User Administrator'
                    duracion = 'PT8H'
                }
            )
        }
    }

    return $esc
}

# ============================================================
# CONSTRUCCIÓN DEL CATÁLOGO DE VULNERABILIDADES
# ============================================================
function New-VulnerabilidadSpOwner {
    <#
    .SYNOPSIS
        Construye la definicion de una vulnerabilidad ServicePrincipalOwner
        para el catalogo escenarios/vulnerab/*.json.

        IMPORTANTE: estas definiciones NO se incluyen en los escenarios.
        Son un catalogo de referencia: cada archivo declara una vulnerabilidad
        por nombre (tipo + parametros). Si en el futuro se quiere cargar una
        vulnerabilidad por nombre desde menu.ps1 [5], aqui esta la fuente.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Nombre,
        [Parameter(Mandatory = $true)] [string]$Usuario,
        [Parameter(Mandatory = $true)] [string]$Aplicacion,
        [Parameter(Mandatory = $true)] [string]$Descripcion
    )
    return [ordered]@{
        nombre           = $Nombre
        descripcion      = $Descripcion
        tipo             = 'ServicePrincipalOwner'
        parametros       = [ordered]@{
            usuario    = $Usuario
            aplicacion = $Aplicacion
        }
        requiereLicencia = 'Free'
    }
}

# ============================================================
# CONSTRUCCIÓN DE PLANTILLAS
# ============================================================
function New-Plantilla {
    param(
        [Parameter(Mandatory = $true)] [string]$Nombre,
        [Parameter(Mandatory = $true)] [string]$Descripcion,
        [Parameter(Mandatory = $true)] [string[]]$Secciones
    )

    $obj = [ordered]@{
        nombre      = $Nombre
        descripcion = $Descripcion
    }
    foreach ($s in $Secciones) {
        $obj[$s] = @()
    }
    return $obj
}

# ============================================================
# ESCRITURA DE FICHEROS
# ============================================================
$escenarioDir  = Join-Path $OutDir 'escenario'
$vulnerabDir   = Join-Path $OutDir 'vulnerab'
$plantillasDir = Join-Path $OutDir 'plantillas'
$null = New-Item -ItemType Directory -Path $escenarioDir -Force
$null = New-Item -ItemType Directory -Path $vulnerabDir -Force
$null = New-Item -ItemType Directory -Path $plantillasDir -Force

$esc1 = New-EscenarioBase -Nombre 'escenarioej1' -Descripcion 'Escenario de ejemplo 1: 3 usuarios, 2 grupos, 1 aplicacion.' `
    -NumUsuarios 3 -NumGrupos 2 -NumApps 1 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0 -NivelActual $Nivel

$esc2 = New-EscenarioBase -Nombre 'escenarioej2' -Descripcion 'Escenario de ejemplo 2: 5 usuarios, 3 grupos, 2 aplicaciones.' `
    -NumUsuarios 5 -NumGrupos 3 -NumApps 2 -OffsetUsuarios 3 -OffsetGrupos 2 -OffsetApps 1 -NivelActual $Nivel

$esc3 = New-EscenarioBase -Nombre 'escenarioej3' -Descripcion 'Escenario de ejemplo 3: 10 usuarios, 10 grupos, 10 aplicaciones.' `
    -NumUsuarios 10 -NumGrupos 10 -NumApps 10 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0 -NivelActual $Nivel

# Catalogo de vulnerabilidades (no forma parte de los escenarios)
$vuln1 = New-VulnerabilidadSpOwner -Nombre 'escenarioej1_sp_owner' `
    -Usuario $esc1.usuarios[0].upn -Aplicacion $esc1.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 1.'
$vuln2 = New-VulnerabilidadSpOwner -Nombre 'escenarioej2_sp_owner' `
    -Usuario $esc2.usuarios[0].upn -Aplicacion $esc2.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 2.'
$vuln3 = New-VulnerabilidadSpOwner -Nombre 'escenarioej3_sp_owner' `
    -Usuario $esc3.usuarios[0].upn -Aplicacion $esc3.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 3.'

$plantillaBasico = New-Plantilla -Nombre 'basico' -Descripcion 'Usuarios, grupos, aplicaciones y relaciones.' `
    -Secciones @('usuarios','grupos','aplicaciones','relaciones')
$plantillaApps = New-Plantilla -Nombre 'aplicaciones' -Descripcion 'Aplicaciones, appRoles, credenciales y permisos de API.' `
    -Secciones @('usuarios','aplicaciones','appRoles','credencialesApp','permisosApi')
$plantillaInvitados = New-Plantilla -Nombre 'invitados' -Descripcion 'Usuarios invitados (B2B).' `
    -Secciones @('invitados')
$plantillaMixto = New-Plantilla -Nombre 'mixto' -Descripcion 'Todas las secciones disponibles para el nivel actual.' `
    -Secciones @('usuarios','grupos','aplicaciones','relaciones','appRoles','credencialesApp','permisosApi','invitados')

$plantillas = [ordered]@{
    'basico'       = $plantillaBasico
    'aplicaciones' = $plantillaApps
    'invitados'    = $plantillaInvitados
    'mixto'        = $plantillaMixto
}

if ($Nivel -in @('P1','P2')) {
    $plantillas['administracion'] = New-Plantilla -Nombre 'administracion' -Descripcion 'Administrative Units, grupos dinamicos y role-assignable.' `
        -Secciones @('usuarios','grupos','administrativeUnits','gruposDinamicos','gruposRoleAssignable')
    $plantillas['acceso'] = New-Plantilla -Nombre 'acceso' -Descripcion 'Acceso Condicional y metodos de autenticacion.' `
        -Secciones @('accesoCondicional','metodosAuth')
}

if ($Nivel -eq 'P2') {
    $plantillas['pim'] = New-Plantilla -Nombre 'pim' -Descripcion 'Roles elegibles PIM.' `
        -Secciones @('usuarios','pim')
}

$esc1Path = Join-Path $escenarioDir 'escenarioej1.json'
$esc2Path = Join-Path $escenarioDir 'escenarioej2.json'
$esc3Path = Join-Path $escenarioDir 'escenarioej3.json'
$esc1 | ConvertTo-Json -Depth 15 | Set-Content -Path $esc1Path -Encoding UTF8
$esc2 | ConvertTo-Json -Depth 15 | Set-Content -Path $esc2Path -Encoding UTF8
$esc3 | ConvertTo-Json -Depth 15 | Set-Content -Path $esc3Path -Encoding UTF8

$vul1Path = Join-Path $vulnerabDir 'escenarioej1_sp_owner.json'
$vul2Path = Join-Path $vulnerabDir 'escenarioej2_sp_owner.json'
$vul3Path = Join-Path $vulnerabDir 'escenarioej3_sp_owner.json'
$vuln1 | ConvertTo-Json -Depth 15 | Set-Content -Path $vul1Path -Encoding UTF8
$vuln2 | ConvertTo-Json -Depth 15 | Set-Content -Path $vul2Path -Encoding UTF8
$vuln3 | ConvertTo-Json -Depth 15 | Set-Content -Path $vul3Path -Encoding UTF8

foreach ($nombrePlantilla in $plantillas.Keys) {
    $path = Join-Path $plantillasDir "$nombrePlantilla.json"
    $plantillas[$nombrePlantilla] | ConvertTo-Json -Depth 15 | Set-Content -Path $path -Encoding UTF8
}

$libPath = Join-Path $OutDir 'biblioteca.json'
$biblioteca | ConvertTo-Json -Depth 15 | Set-Content -Path $libPath -Encoding UTF8

$seed1 = New-LabSeedIfMissing -Root $OutDir -NombreEscenario 'escenarioej1'
$seed2 = New-LabSeedIfMissing -Root $OutDir -NombreEscenario 'escenarioej2'
$seed3 = New-LabSeedIfMissing -Root $OutDir -NombreEscenario 'escenarioej3'

# ============================================================
# RESUMEN
# ============================================================
Write-Host ''
Write-OkLocal "Nivel de generacion: $Nivel"
Write-Host ''
Write-Host "[OK] Biblioteca   : $libPath"
Write-Host "[OK] Escenario 1  : $esc1Path"
Write-Host "[OK] Escenario 2  : $esc2Path"
Write-Host "[OK] Escenario 3  : $esc3Path"
Write-Host "[OK] Vulnerab. 1  : $vul1Path"
Write-Host "[OK] Vulnerab. 2  : $vul2Path"
Write-Host "[OK] Vulnerab. 3  : $vul3Path"
Write-Host ''
Write-Host "[OK] Semilla 1    : $seed1"
Write-Host "[OK] Semilla 2    : $seed2"
Write-Host "[OK] Semilla 3    : $seed3"
Write-Host ''
Write-Host "[OK] Plantillas   : $($plantillas.Keys -join ', ')"
Write-Host ''
Write-Host "Usuarios: $($usuarios.Count) | Grupos: $($grupos.Count) | Apps: $($aplicaciones.Count) | Roles: $($roles.Count)"
Write-Host ''
Write-InfoLocal 'Los escenarios NO incluyen vulnerabilidades. Se aplican desde menu.ps1 [5] Crear vulnerabilidad.'
Write-InfoLocal 'Los JSON NO contienen contrasenas. Se derivan en creauto.ps1 / creamanual.ps1 desde la semilla local.'
Write-WarnLocal 'Anade escenarios/.secrets/ a .gitignore para no subir las semillas a GitHub.'