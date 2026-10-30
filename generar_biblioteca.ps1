<#
.SYNOPSIS
    Generador de biblioteca de datos para escenarios de laboratorio en Entra ID.
.DESCRIPTION
    Genera en escenarios/:
      - escenario/escenarioej1.json, escenarioej2.json, escenarioej3.json
      - vulnerab/escenarioej1_sp_owner.json
      - biblioteca.json en la raíz de OutDir

    Los datos base (nombres, apellidos) se generan a partir de listas embebidas
    para que el script sea autónomo. Si quieres más variedad, sustituye las
    listas por las de https://github.com/jvalhondo/spanish-names-surnames
.PARAMETER Seed
    Semilla para el generador aleatorio. Útil para reproducibilidad.
.PARAMETER OutDir
    Carpeta de salida. Por defecto, escenarios/ en la carpeta del script.
#>
[CmdletBinding()]
param(
    [int]$Seed = 42,
    [string]$OutDir = (Join-Path $PSScriptRoot "escenarios")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
# DATOS BASE (listas embebidas)
# ============================================================
$Nombres = @(
    "Lucia","Javier","Maria","Carlos","Elena","Pablo","Sara","Alberto","Carmen","David",
    "Laura","Sergio","Ana","Jorge","Marta","Raul","Paula","Ivan","Nuria","Adrian"
)
$Apellidos = @(
    "Garcia","Martinez","Lopez","Sanchez","Perez","Gomez","Fernandez","Ruiz","Diaz","Moreno",
    "Alvarez","Romero","Jimenez","Navarro","Torres","Dominguez","Vazquez","Ramos","Gil","Serrano"
)
$Departamentos = @(
    "Ventas","IT","RRHH","Finanzas","Produccion","Almacen","Calidad","Compras","Marketing","Legal"
)
$Puestos = @(
    "Comercial","Administrador de Sistemas","Tecnico de RRHH","Analista Financiero","Operario",
    "Responsable de Almacen","Tecnico de Calidad","Comprador","Especialista Marketing","Asesor Legal"
)
$RolesEntra = @(
    "Global Administrator","Application Administrator","Cloud Application Administrator",
    "User Administrator","Groups Administrator","Helpdesk Administrator",
    "Privileged Role Administrator","Security Administrator","Exchange Administrator",
    "SharePoint Administrator"
)
$RolesAzure = @(
    "Owner","Contributor","Reader","Key Vault Contributor","Storage Account Contributor",
    "Virtual Machine Contributor","Website Contributor","Logic App Contributor",
    "Monitoring Contributor","Network Contributor"
)

# Inicializar generador aleatorio con semilla para reproducibilidad
$rng = [System.Random]::new($Seed)

function Get-RandomItem {
    param([array]$Lista)
    return $Lista[$rng.Next(0, $Lista.Count)]
}

# ============================================================
# GENERACIÓN DE USUARIOS
# ============================================================
$usuarios = @()
$usados = [System.Collections.Generic.HashSet[string]]::new()
$i = 0
while ($usuarios.Count -lt 10) {
    $nombre   = Get-RandomItem $Nombres
    $apellido = Get-RandomItem $Apellidos
    $nick     = ($nombre.ToLower() + "." + $apellido.Substring(0,1).ToLower())
    if (-not $usados.Add($nick)) { continue }
    $deptIdx = $i % $Departamentos.Count
    $usuarios += [ordered]@{
        displayName  = "$nombre $apellido"
        upn          = "$nick@{tenant}"
        mailNickname = $nick
        password     = "Lab!Passw0rd#2025"
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
        mailNickname = ("departamento-" + $d.ToLower())
    }
}

# ============================================================
# GENERACIÓN DE APLICACIONES
# ============================================================
$nombresApps = @(
    "Panel de Analisis Comercial","Portal de RRHH","Gestion de Almacen","ERP Financiero",
    "Herramienta de Calidad","Portal de Compras","CRM Marketing","Gestion Legal",
    "Dashboard Produccion","API Interna"
)
$aplicaciones = @()
foreach ($a in $nombresApps) {
    $aplicaciones += [ordered]@{
        displayName    = $a
        description    = "Aplicacion interna: $a"
        signInAudience = "AzureADMyOrg"
        redirectUris   = @("https://" + ($a -replace '[^a-zA-Z0-9]','').ToLower() + ".empresa.local/callback")
    }
}

# ============================================================
# GENERACIÓN DE ROLES (Entra + Azure RBAC)
# ============================================================
$roles = @()
foreach ($r in $RolesEntra) { $roles += [ordered]@{ tipo = "EntraRole"; nombre = $r } }
foreach ($r in $RolesAzure) { $roles += [ordered]@{ tipo = "AzureRBAC"; nombre = $r } }

# ============================================================
# CONSTRUCCIÓN DE LA BIBLIOTECA
# ============================================================
$biblioteca = [ordered]@{
    generado      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
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
    param(
        [string]$Nombre,
        [string]$Descripcion,
        [int]$NumUsuarios,
        [int]$NumGrupos,
        [int]$NumApps,
        [int]$OffsetUsuarios,
        [int]$OffsetGrupos,
        [int]$OffsetApps
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
            tipo    = "membresia"
            usuario = $us[$k].upn
            grupo   = $gr[$k % $gr.Count].displayName
        }
    }

    return [ordered]@{
        nombre        = $Nombre
        descripcion   = $Descripcion
        usuarios      = $us
        grupos        = $gr
        aplicaciones  = $ap
        relaciones    = $rels
        vulnerabilidad = "$($Nombre)_sp_owner"
    }
}

$esc1 = New-EscenarioEjemplo -Nombre "escenarioej1" -Descripcion "Escenario de ejemplo 1: 3 usuarios, 2 grupos, 1 aplicacion." `
    -NumUsuarios 3 -NumGrupos 2 -NumApps 1 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0

$esc2 = New-EscenarioEjemplo -Nombre "escenarioej2" -Descripcion "Escenario de ejemplo 2: 5 usuarios, 3 grupos, 2 aplicaciones." `
    -NumUsuarios 5 -NumGrupos 3 -NumApps 2 -OffsetUsuarios 3 -OffsetGrupos 2 -OffsetApps 1

$esc3 = New-EscenarioEjemplo -Nombre "escenarioej3" -Descripcion "Escenario de ejemplo 3: 10 usuarios, 10 grupos, 10 aplicaciones (biblioteca completa)." `
    -NumUsuarios 10 -NumGrupos 10 -NumApps 10 -OffsetUsuarios 0 -OffsetGrupos 0 -OffsetApps 0

# ============================================================
# CONSTRUCCIÓN DE VULNERABILIDADES DE EJEMPLO
# ============================================================
function New-VulnerabilidadSpOwner {
    param(
        [string]$Nombre,
        [string]$Usuario,
        [string]$Aplicacion,
        [string]$Descripcion
    )
    return [ordered]@{
        nombre           = $Nombre
        descripcion      = $Descripcion
        tipo             = "ServicePrincipalOwner"
        parametros       = [ordered]@{
            usuario    = $Usuario
            aplicacion = $Aplicacion
        }
        requiereLicencia = "Free"
    }
}

$vuln1 = New-VulnerabilidadSpOwner -Nombre "escenarioej1_sp_owner" `
    -Usuario $esc1.usuarios[0].upn -Aplicacion $esc1.aplicaciones[0].displayName `
    -Descripcion "Owner de SP para el escenario 1."

$vuln2 = New-VulnerabilidadSpOwner -Nombre "escenarioej2_sp_owner" `
    -Usuario $esc2.usuarios[0].upn -Aplicacion $esc2.aplicaciones[0].displayName `
    -Descripcion "Owner de SP para el escenario 2."

$vuln3 = New-VulnerabilidadSpOwner -Nombre "escenarioej3_sp_owner" `
    -Usuario $esc3.usuarios[0].upn -Aplicacion $esc3.aplicaciones[0].displayName `
    -Descripcion "Owner de SP para el escenario 3."

# ============================================================
# ESCRITURA DE FICHEROS
# ============================================================
$escenarioDir = Join-Path $OutDir "escenario"
$vulnerabDir  = Join-Path $OutDir "vulnerab"
$null = New-Item -ItemType Directory -Path $escenarioDir -Force
$null = New-Item -ItemType Directory -Path $vulnerabDir  -Force

$libPath  = Join-Path $OutDir "biblioteca.json"
$esc1Path = Join-Path $escenarioDir "escenarioej1.json"
$esc2Path = Join-Path $escenarioDir "escenarioej2.json"
$esc3Path = Join-Path $escenarioDir "escenarioej3.json"
$vul1Path = Join-Path $vulnerabDir  "escenarioej1_sp_owner.json"
$vul2Path = Join-Path $vulnerabDir  "escenarioej2_sp_owner.json"
$vul3Path = Join-Path $vulnerabDir  "escenarioej3_sp_owner.json"

$biblioteca | ConvertTo-Json -Depth 6 | Set-Content -Path $libPath  -Encoding UTF8
$esc1       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc1Path -Encoding UTF8
$esc2       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc2Path -Encoding UTF8
$esc3       | ConvertTo-Json -Depth 6 | Set-Content -Path $esc3Path -Encoding UTF8
$vuln1      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul1Path -Encoding UTF8
$vuln2      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul2Path -Encoding UTF8
$vuln3      | ConvertTo-Json -Depth 6 | Set-Content -Path $vul3Path -Encoding UTF8

Write-Host "[OK] Biblioteca   : $libPath"
Write-Host "[OK] Escenario 1  : $esc1Path"
Write-Host "[OK] Escenario 2  : $esc2Path"
Write-Host "[OK] Escenario 3  : $esc3Path"
Write-Host "[OK] Vulnerab. 1  : $vul1Path"
Write-Host "[OK] Vulnerab. 2  : $vul2Path"
Write-Host "[OK] Vulnerab. 3  : $vul3Path"
Write-Host ""
Write-Host "Usuarios: $($usuarios.Count) | Grupos: $($grupos.Count) | Apps: $($aplicaciones.Count) | Roles: $($roles.Count)"