<#
.SYNOPSIS
    Generador de biblioteca de datos para escenarios de laboratorio en Entra ID.
.DESCRIPTION
    Genera en escenarios/:
      - escenario/escenarioej1.json, escenarioej2.json, escenarioej3.json
      - vulnerab/escenarioej1_sp_owner.json, escenarioej2_sp_owner.json, escenarioej3_sp_owner.json
      - biblioteca.json en la raíz de OutDir
      - .secrets/<escenario>.seed (semilla local por escenario, fuera de Git)

    Los JSON generados NO contienen contraseñas. Las contraseñas de los
    usuarios se derivan en tiempo de creación (creauto.ps1 / creamanual.ps1)
    a partir de la semilla local de cada escenario, con
    HMAC-SHA256(semilla, UPN).

    La semilla se genera aquí (una por escenario) si no existe. Si ya existe,
    NO se sobrescribe, para no invalidar contraseñas ya mostradas al operador.

    Los datos base (nombres, apellidos) se generan a partir de listas embebidas
    para que el script sea autónomo. Si quieres más variedad, sustituye las
    listas por las de https://github.com/jvalhondo/spanish-names-surnames
.PARAMETER Seed
    Semilla para el generador aleatorio de datos (nombres, apellidos, etc.).
    Útil para reproducibilidad de los JSON. NO es la semilla de contraseñas.
.PARAMETER OutDir
    Carpeta de salida. Por defecto, escenarios/ en la carpeta del script.
.NOTES
    Autocontenido. No depende de lib_*.ps1.
    Las contraseñas NO se generan aquí; solo las semillas locales.
#>
[CmdletBinding()]
param(
    [int]$Seed = 42,
    [string]$OutDir = (Join-Path $PSScriptRoot 'escenarios')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host ''
Write-LabInfoSafe 'Este generador NO crea contrasenas. Solo genera datos y semillas locales.'
Write-LabInfoSafe 'Las contrasenas se derivan en creauto.ps1 / creamanual.ps1 desde la semilla del escenario.'
Write-Host ''

# Helper local para no depender de lib_ui.ps1
function Write-LabInfoSafe {
    param([string]$Msg)
    Write-Host "[INFO]  $Msg" -ForegroundColor Gray
}

function Write-LabWarnSafe {
    param([string]$Msg)
    Write-Host "[WARN]  $Msg" -ForegroundColor Yellow
}

# ============================================================
# GESTIÓN DE SEMILLAS LOCALES
# ============================================================
# La semilla vive en escenarios/.secrets/<escenario>.seed, fuera de Git.
# Se reutiliza la misma derivación que en creauto.ps1 / creamanual.ps1.

function Get-LabSecretsDir {
    <#
    .SYNOPSIS
        Devuelve la ruta de la carpeta de secretos locales (fuera de Git).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir
    )
    return (Join-Path $RootDir '.secrets')
}

function Get-LabSeedPath {
    <#
    .SYNOPSIS
        Devuelve la ruta del fichero de semilla para un escenario concreto.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,

        [Parameter(Mandatory = $true)]
        [string]$NombreEscenario
    )
    return (Join-Path (Get-LabSecretsDir -RootDir $RootDir) "$NombreEscenario.seed")
}

function New-LabSeedIfMissing {
    <#
    .SYNOPSIS
        Crea la semilla local de un escenario si no existe. No sobrescribe.
    .DESCRIPTION
        La semilla es un array de 32 bytes aleatorios criptográficamente
        seguros, almacenado en Base64. Se intentan restringir permisos ACL
        en Windows.
    .OUTPUTS
        Ruta del fichero de semilla (existente o recién creado).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootDir,

        [Parameter(Mandatory = $true)]
        [string]$NombreEscenario
    )

    $seedPath = Get-LabSeedPath -RootDir $RootDir -NombreEscenario $NombreEscenario
    $seedDir  = Split-Path -Path $seedPath -Parent

    if (-not (Test-Path -Path $seedDir)) {
        $null = New-Item -ItemType Directory -Path $seedDir -Force
    }

    if (Test-Path -Path $seedPath) {
        Write-LabInfoSafe "Semilla existente para '$NombreEscenario'; no se sobrescribe."
        return $seedPath
    }

    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }

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
        Write-LabWarnSafe "No se pudieron restringir los permisos de $seedPath : $($_.Exception.Message)"
    }

    Write-LabInfoSafe "Semilla generada para '$NombreEscenario' en $seedPath"
    return $seedPath
}

# ============================================================
# DATOS BASE (listas embebidas)
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

# Inicializar generador aleatorio con semilla para reproducibilidad
$rng = [System.Random]::new($Seed)

function Get-RandomItem {
    <#
    .SYNOPSIS
        Devuelve un elemento aleatorio de una lista usando el RNG con semilla.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Lista
    )
    return $Lista[$rng.Next(0, $Lista.Count)]
}

# ============================================================
# GENERACIÓN DE USUARIOS
# ============================================================
# Sin contraseña: el campo 'password' ya no se incluye en el JSON.
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
# GENERACIÓN DE GRUPOS (uno por departamento)
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
# CONSTRUCCIÓN DE LA BIBLIOTECA
# ============================================================
$biblioteca = [ordered]@{
    generado      = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    seed          = $Seed
    usuarios      = $usuarios
    grupos        = $grupos
    aplicaciones  = $aplicaciones
    roles         = $roles
    departamentos = $Departamentos
    puestos       = $Puestos
}

# ============================================================
# CONSTRUCCIÓN DE ESCENARIOS DE EJEMPLO
# ============================================================
function New-EscenarioEjemplo {
    <#
    .SYNOPSIS
        Construye un escenario de ejemplo a partir de la biblioteca.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Nombre,
        [Parameter(Mandatory = $true)] [string]$Descripcion,
        [Parameter(Mandatory = $true)] [int]$NumUsuarios,
        [Parameter(Mandatory = $true)] [int]$NumGrupos,
        [Parameter(Mandatory = $true)] [int]$NumApps,
        [Parameter(Mandatory = $true)] [int]$OffsetUsuarios,
        [Parameter(Mandatory = $true)] [int]$OffsetGrupos,
        [Parameter(Mandatory = $true)] [int]$OffsetApps
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

    return [ordered]@{
        nombre         = $Nombre
        descripcion    = $Descripcion
        usuarios       = $us
        grupos         = $gr
        aplicaciones   = $ap
        relaciones     = $rels
        vulnerabilidad = "$($Nombre)_sp_owner"
    }
}

$esc1 = New-EscenarioEjemplo -Nombre 'escenarioej1' -Descripcion 'Escenario de ejemplo 1: 3 usuarios, 2 grupos, 1 aplicacion.' `
    -NumUsuarios 3 -NumGrupos 2 -NumApps 1 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0

$esc2 = New-EscenarioEjemplo -Nombre 'escenarioej2' -Descripcion 'Escenario de ejemplo 2: 5 usuarios, 3 grupos, 2 aplicaciones.' `
    -NumUsuarios 5 -NumGrupos 3 -NumApps 2 -OffsetUsuarios 3 -OffsetGrupos 2 -OffsetApps 1

$esc3 = New-EscenarioEjemplo -Nombre 'escenarioej3' -Descripcion 'Escenario de ejemplo 3: 10 usuarios, 10 grupos, 10 aplicaciones (biblioteca completa).' `
    -NumUsuarios 10 -NumGrupos 10 -NumApps 10 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0

# ============================================================
# CONSTRUCCIÓN DE VULNERABILIDADES DE EJEMPLO
# ============================================================
function New-VulnerabilidadSpOwner {
    <#
    .SYNOPSIS
        Construye una vulnerabilidad de tipo ServicePrincipalOwner.
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

$vuln1 = New-VulnerabilidadSpOwner -Nombre 'escenarioej1_sp_owner' `
    -Usuario $esc1.usuarios[0].upn -Aplicacion $esc1.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 1.'

$vuln2 = New-VulnerabilidadSpOwner -Nombre 'escenarioej2_sp_owner' `
    -Usuario $esc2.usuarios[0].upn -Aplicacion $esc2.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 2.'

$vuln3 = New-VulnerabilidadSpOwner -Nombre 'escenarioej3_sp_owner' `
    -Usuario $esc3.usuarios[0].upn -Aplicacion $esc3.aplicaciones[0].displayName `
    -Descripcion 'Owner de SP para el escenario 3.'

# ============================================================
# ESCRITURA DE FICHEROS
# ============================================================
$escenarioDir = Join-Path $OutDir 'escenario'
$vulnerabDir  = Join-Path $OutDir 'vulnerab'
$null = New-Item -ItemType Directory -Path $escenarioDir -Force
$null = New-Item -ItemType Directory -Path $vulnerabDir  -Force

$libPath  = Join-Path $OutDir 'biblioteca.json'
$esc1Path = Join-Path $escenarioDir 'escenarioej1.json'
$esc2Path = Join-Path $escenarioDir 'escenarioej2.json'
$esc3Path = Join-Path $escenarioDir 'escenarioej3.json'
$vul1Path = Join-Path $vulnerabDir  'escenarioej1_sp_owner.json'
$vul2Path = Join-Path $vulnerabDir  'escenarioej2_sp_owner.json'
$vul3Path = Join-Path $vulnerabDir  'escenarioej3_sp_owner.json'

$biblioteca | ConvertTo-Json -Depth 6 | Set-Content -Path $libPath  -Encoding UTF8
$esc1       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc1Path -Encoding UTF8
$esc2       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc2Path -Encoding UTF8
$esc3       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc3Path -Encoding UTF8
$vuln1      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul1Path -Encoding UTF8
$vuln2      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul2Path -Encoding UTF8
$vuln3      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul3Path -Encoding UTF8

# ============================================================
# GENERACIÓN DE SEMILLAS LOCALES POR ESCENARIO
# ============================================================
# Se crean (si no existen) las semillas de los escenarios generados.
# NO se sobrescriben: si ya existían, se conservan las contraseñas
# derivadas previamente mostradas al operador.
$seed1 = New-LabSeedIfMissing -RootDir $OutDir -NombreEscenario 'escenarioej1'
$seed2 = New-LabSeedIfMissing -RootDir $OutDir -NombreEscenario 'escenarioej2'
$seed3 = New-LabSeedIfMissing -RootDir $OutDir -NombreEscenario 'escenarioej3'

# ============================================================
# RESUMEN
# ============================================================
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
Write-Host "Usuarios: $($usuarios.Count) | Grupos: $($grupos.Count) | Apps: $($aplicaciones.Count) | Roles: $($roles.Count)"
Write-Host ''
Write-LabInfoSafe 'Los JSON NO contienen contrasenas. Se derivan en creauto.ps1 / creamanual.ps1 desde la semilla local.'
Write-LabWarnSafe 'Anade escenarios/.secrets/ a .gitignore para no subir las semillas a GitHub.'