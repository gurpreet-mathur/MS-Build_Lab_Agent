<#
.SYNOPSIS
    Lab Lifecycle Manager — deploy, manage, and destroy Microsoft Build & Ignite labs.

.DESCRIPTION
    Core engine for the Lab Lifecycle Skill. Works with any event's lab repos
    (e.g. Build26-LABxxx, Ignite-LABxxx) — the event is auto-detected from the
    repo URL so the same skill serves multiple events. Supports actions:
    - doctor:  Validate all prerequisites
    - analyze: Inspect a lab repo and report requirements
    - outline: Break a lab's instructions into ordered modules/chapters,
               each with its commands and manual verification steps
    - deploy:  Clone, configure, provision, and deploy
    - destroy: Tear down all resources (requires confirmation)
    - list:    Show tracked deployments
    - status:  Check current status of a deployed lab

.PARAMETER Action
    The action to perform: doctor, analyze, deploy, destroy, list, status

.PARAMETER RepoUrl
    GitHub URL of the lab repository

.PARAMETER EnvName
    Optional azd environment name (auto-generated if not provided)

.PARAMETER Location
    Azure region (default: eastus2)

.PARAMETER ConfigFile
    Path to team-config.yaml (default: ./team-config.yaml)

.PARAMETER Force
    Skip confirmation prompts (use with caution)

.EXAMPLE
    .\lab-manager.ps1 -Action doctor
    .\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."
    .\lab-manager.ps1 -Action destroy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."
#>

param(
    [Parameter(Mandatory)][ValidateSet("doctor","analyze","prepare","outline","generate","deploy","destroy","list","status")]
    [string]$Action,
    
    [string]$RepoUrl,
    [string]$EnvName,
    [string]$Location = "eastus2",
    [string]$ConfigFile = (Join-Path $PSScriptRoot "..\team-config.yaml"),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RegistryPath = Join-Path $env:USERPROFILE ".lab-lifecycle" "registry.json"

# ============================================================================
# HELPERS
# ============================================================================

function Write-Status($icon, $message) { Write-Host "  $icon $message" }
function Write-Pass($msg) { Write-Status "✓" $msg -ForegroundColor Green }
function Write-Fail($msg) { Write-Status "✗" $msg -ForegroundColor Red }
function Write-Warn($msg) { Write-Status "⚠" $msg -ForegroundColor Yellow }

function Get-Registry {
    if (Test-Path $RegistryPath) {
        $data = Get-Content $RegistryPath -Raw | ConvertFrom-Json
        # Ensure deployments is an array
        if (-not $data.deployments) {
            $data | Add-Member -NotePropertyName "deployments" -NotePropertyValue @() -Force
        }
        return $data
    }
    return [PSCustomObject]@{ deployments = @() }
}

function Save-Registry($registry) {
    $dir = Split-Path $RegistryPath
    if (-not (Test-Path $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $registry | ConvertTo-Json -Depth 5 | Set-Content $RegistryPath
}

function Get-LabCode($url) {
    if ($url -match "LAB(\d+)") { return "LAB$($Matches[1])" }
    return "UNKNOWN"
}

function Get-EventName($url) {
    # Derive the event (e.g. Build26, Ignite, Ignite25) from the repo name so the
    # same skill can manage labs from any event without hardcoding.
    if (-not $url) { return "Lab" }
    $repoName = (($url -replace '/$', '') -split '/' | Select-Object -Last 1) -replace '\.git$', ''
    if ($repoName -match '^(.*?)[-_]LAB\d+') { return $Matches[1] }
    return "Lab"
}

function Get-TeamConfig {
    if (Test-Path $ConfigFile) {
        # Simple YAML parsing for our flat structure
        $content = Get-Content $ConfigFile -Raw
        return $content
    }
    return $null
}

function Get-LabConfig($labCode) {
    # Data-driven: read env_overrides for a lab code straight from team-config.yaml
    # so adding Build OR Ignite labs never requires editing this script.
    $envOverrides = @{}
    if (-not (Test-Path $ConfigFile)) { return $envOverrides }

    $inLab = $false
    $inOverrides = $false
    $labIndent = -1

    foreach ($line in (Get-Content $ConfigFile)) {
        if ($line -match '^\s*#') { continue }

        # A bare "key:" line (no inline value) — could be a lab code or a nested block.
        if ($line -match '^(\s*)([A-Za-z0-9_]+):\s*$') {
            $indent = $Matches[1].Length
            $key = $Matches[2]
            if ($key -eq $labCode) {
                $inLab = $true; $labIndent = $indent; $inOverrides = $false; continue
            } elseif ($inLab -and $indent -le $labIndent) {
                $inLab = $false; $inOverrides = $false
            }
        }

        if ($inLab) {
            if ($line -match '^\s*env_overrides:\s*\{\s*\}\s*$') { $inOverrides = $false; continue }
            if ($line -match '^\s*env_overrides:\s*$') { $inOverrides = $true; continue }
            if ($inOverrides) {
                if ($line -cmatch '^\s*([A-Z][A-Z0-9_]*):\s*"?([^"]*?)"?\s*$') {
                    $envOverrides[$Matches[1]] = $Matches[2]
                } elseif ($line -match '^\s*\S') {
                    $inOverrides = $false
                }
            }
        }
    }
    return $envOverrides
}

function Find-AzureYaml($repoPath) {
    $rootYaml = Join-Path $repoPath "azure.yaml"
    if (Test-Path $rootYaml) { return $repoPath }
    
    # Search subdirectories (one level deep)
    $subYaml = Get-ChildItem $repoPath -Directory | ForEach-Object {
        $candidate = Join-Path $_.FullName "azure.yaml"
        if (Test-Path $candidate) { $_.FullName }
    } | Select-Object -First 1
    
    return $subYaml
}

# ----------------------------------------------------------------------------
# OUTLINE HELPERS — parse lab instructions into modules/chapters
# ----------------------------------------------------------------------------

function Get-MarkdownFiles($repoPath) {
    # Collect lab instruction markdown, skipping noise dirs.
    $exclude = @('node_modules', '.git', '.github', 'bin', 'obj', 'dist', '.venv', 'venv')
    return Get-ChildItem $repoPath -Recurse -Filter *.md -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($repoPath.Length)
        $hit = $false
        foreach ($e in $exclude) { if ($rel -match "[\\/]$([regex]::Escape($e))[\\/]") { $hit = $true; break } }
        -not $hit
    }
}

function Get-CommandsFromBody($body) {
    # Pull runnable commands out of fenced code blocks.
    $cmds = @()
    $cmdLangs = @('bash','sh','shell','powershell','pwsh','ps1','azurecli','azurepowershell','console','cmd','bat','terminal','dotnetcli')
    $toolRe = '^(az|azd|git|docker|kubectl|helm|terraform|bicep|npm|npx|pnpm|yarn|pip|pip3|python|python3|dotnet|func|gh|curl|wget|cd|mkdir|cp|mv|rm|export|set|\.\\|\./)'
    $inFence = $false; $fenceLang = ''
    foreach ($l in ($body -split "`r?`n")) {
        if ($l -match '^\s*```+\s*([A-Za-z0-9_+#-]*)\s*$') {
            if (-not $inFence) { $inFence = $true; $fenceLang = $Matches[1].ToLower() }
            else { $inFence = $false; $fenceLang = '' }
            continue
        }
        if (-not $inFence) { continue }
        $explicit = $cmdLangs -contains $fenceLang
        if (-not $explicit -and $fenceLang -ne '') { continue }  # skip e.g. json/yaml/python blocks
        $t = $l.Trim()
        if (-not $t) { continue }
        if ($t -match '^(#|//|REM\b|>)') { continue }            # comments / output markers
        $t = $t -replace '^\$\s+', '' -replace '^PS[^>]*>\s*', '' -replace '^C:\\[^>]*>\s*', ''
        if ($explicit) { $cmds += $t }
        elseif ($t -match $toolRe) { $cmds += $t }               # untagged block: keep only command-looking lines
    }
    return ,$cmds
}

function Get-VerificationFromBody($body) {
    # Surface the manual "prove it works" steps a presenter must do by hand.
    $kw = 'verify|confirm|you should (?:see|now|be able|get)|ensure|make sure|validate|check that|expected|navigate to|open .*(?:browser|portal|url)|test (?:the|that|your)|observe|notice that|you will see|response should'
    $hits = @()
    foreach ($line in ($body -split "`r?`n")) {
        $t = ($line -replace '^\s*#{1,6}\s+', '' -replace '^\s*[-*+]\s+', '' -replace '^\s*\d+[.)]\s+', '').Trim()
        if (-not $t) { continue }
        if ($t -match "(?i)$kw") {
            $t = ($t -replace '\*\*', '' -replace '`', '').Trim()
            if ($t.Length -gt 220) { $t = $t.Substring(0,217) + '...' }
            $hits += $t
        }
    }
    return ,($hits | Select-Object -Unique -First 12)
}

function Get-ModuleKind($cmds, $verifications) {
    $joined = ($cmds -join ' ')
    # Deploy wins over cleanup: a deploy module may mention destroy/--purge in a
    # troubleshooting note, but it's still fundamentally a deploy step.
    if ($joined -match '(?i)\b(azd up|azd provision|azd deploy|az deployment|terraform apply|az containerapp|az webapp|az aks|bicep)\b') { return 'deploy' }
    if ($joined -match '(?i)\b(azd down|az group delete|--purge|destroy)\b') { return 'cleanup' }
    if (@($cmds).Count -gt 0) { return 'configure' }
    if (@($verifications).Count -gt 0) { return 'verify' }
    return 'reading'
}

function Get-HeadingTitle($text) {
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*#{1,3}\s+(.+?)\s*#*\s*$') { return ($Matches[1] -replace '[`*]', '').Trim() }
    }
    return $null
}

function Split-BodyIntoModules($text) {
    # Split a single instruction file into modules on chapter-like headings.
    $modulePattern = '^(#{1,4})\s+((?:module|chapter|exercise|task|part|step|lab|section)\b[^\r\n]*)$'
    $lines = $text -split "`r?`n"
    $modules = @(); $current = $null; $buffer = $null
    foreach ($line in $lines) {
        if ($line -match "(?i)$modulePattern") {
            if ($current) { $current.body = ($buffer -join "`n"); $modules += $current }
            $title = ($Matches[2] -replace '[`*]', '').Trim()
            $current = [ordered]@{ title = $title; body = '' }
            $buffer = @()
        } elseif ($current) {
            $buffer += $line
        }
    }
    if ($current) { $current.body = ($buffer -join "`n"); $modules += $current }

    if (@($modules).Count -eq 0) {
        # No chapter keywords — fall back to top-level '##' sections.
        $current = $null; $buffer = $null
        foreach ($line in $lines) {
            if ($line -match '^##\s+(.+?)\s*#*\s*$') {
                if ($current) { $current.body = ($buffer -join "`n"); $modules += $current }
                $current = [ordered]@{ title = ($Matches[1] -replace '[`*]', '').Trim(); body = '' }
                $buffer = @()
            } elseif ($current) {
                $buffer += $line
            }
        }
        if ($current) { $current.body = ($buffer -join "`n"); $modules += $current }
    }
    return ,$modules
}

# ============================================================================
# DOCTOR — Validate Prerequisites
# ============================================================================

function Invoke-Doctor {
    Write-Host "`n🩺 Lab Lifecycle — Environment Check`n" -ForegroundColor Cyan
    Write-Host "  Checking prerequisites for your environment...`n"
    
    $allPassed = $true
    $results = @()
    
    # 1. PowerShell version
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 7) {
        $results += @{ name = "PowerShell 7+"; status = "pass"; detail = "v$psVer" }
    } else {
        $results += @{ name = "PowerShell 7+"; status = "fail"; detail = "Found v$psVer — install with: winget install Microsoft.PowerShell" }
        $allPassed = $false
    }
    
    # 2. Azure CLI
    try {
        $azVer = (az version 2>$null | ConvertFrom-Json).'azure-cli'
        $results += @{ name = "Azure CLI (az)"; status = "pass"; detail = "v$azVer" }
    } catch {
        $results += @{ name = "Azure CLI (az)"; status = "fail"; detail = "Not found — install: winget install Microsoft.AzureCLI" }
        $allPassed = $false
    }
    
    # 3. Azure CLI logged in
    try {
        $account = az account show 2>$null | ConvertFrom-Json
        $results += @{ name = "Azure login"; status = "pass"; detail = "$($account.name) ($($account.id))" }
    } catch {
        $results += @{ name = "Azure login"; status = "fail"; detail = "Not logged in — run: az login" }
        $allPassed = $false
    }
    
    # 4. Azure Developer CLI
    $azdPath = "$env:LOCALAPPDATA\Programs\Azure Dev CLI\azd.exe"
    if (Test-Path $azdPath) {
        $azdVer = & $azdPath version 2>$null | Select-Object -First 1
        $results += @{ name = "Azure Developer CLI (azd)"; status = "pass"; detail = "$azdVer" }
    } elseif (Get-Command azd -ErrorAction SilentlyContinue) {
        $azdVer = azd version 2>$null | Select-Object -First 1
        $results += @{ name = "Azure Developer CLI (azd)"; status = "pass"; detail = "$azdVer" }
    } else {
        $results += @{ name = "Azure Developer CLI (azd)"; status = "fail"; detail = "Not found — install: winget install Microsoft.Azd" }
        $allPassed = $false
    }
    
    # 5. azd AI Agents extension
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    try {
        $extList = azd ext list 2>$null
        if ($extList -match "azure\.ai\.agents") {
            $results += @{ name = "azd AI Agents extension"; status = "pass"; detail = "Installed" }
        } else {
            $results += @{ name = "azd AI Agents extension"; status = "fail"; detail = "Not installed — run: azd ext install azure.ai.agents" }
            $allPassed = $false
        }
    } catch {
        $results += @{ name = "azd AI Agents extension"; status = "warn"; detail = "Could not check — try: azd ext install azure.ai.agents" }
    }
    
    # 6. Git
    try {
        $gitVer = git --version 2>$null
        $results += @{ name = "Git"; status = "pass"; detail = $gitVer }
    } catch {
        $results += @{ name = "Git"; status = "fail"; detail = "Not found — install: winget install Git.Git" }
        $allPassed = $false
    }
    
    # 7. Node.js
    try {
        $nodeVer = node --version 2>$null
        $nodeMajor = [int]($nodeVer -replace 'v(\d+)\..*', '$1')
        if ($nodeMajor -ge 18) {
            $results += @{ name = "Node.js 18+"; status = "pass"; detail = $nodeVer }
        } else {
            $results += @{ name = "Node.js 18+"; status = "fail"; detail = "Found $nodeVer — need 18+: winget install OpenJS.NodeJS.LTS" }
            $allPassed = $false
        }
    } catch {
        $results += @{ name = "Node.js 18+ (for MCP)"; status = "warn"; detail = "Not found — optional, needed for MCP server" }
    }
    
    # 8. GitHub CLI
    try {
        $ghVer = gh --version 2>$null | Select-Object -First 1
        $results += @{ name = "GitHub CLI (gh)"; status = "pass"; detail = $ghVer }
    } catch {
        $results += @{ name = "GitHub CLI (gh)"; status = "warn"; detail = "Not found — optional, needed for repo operations" }
    }
    
    # 9. Team config
    if (Test-Path $ConfigFile) {
        $results += @{ name = "Team config"; status = "pass"; detail = $ConfigFile }
    } else {
        $results += @{ name = "Team config"; status = "warn"; detail = "Not found at $ConfigFile — using defaults" }
    }
    
    # 10. RBAC check
    try {
        $roles = az role assignment list --assignee (az ad signed-in-user show --query id -o tsv 2>$null) --query "[].roleDefinitionName" -o tsv 2>$null
        $hasContributor = $roles -contains "Contributor" -or $roles -contains "Owner"
        if ($hasContributor) {
            $results += @{ name = "Azure RBAC (Contributor)"; status = "pass"; detail = "Has required role" }
        } else {
            $results += @{ name = "Azure RBAC (Contributor)"; status = "warn"; detail = "Could not verify — ensure you have Contributor on target subscription" }
        }
    } catch {
        $results += @{ name = "Azure RBAC"; status = "warn"; detail = "Could not verify — ensure Contributor role on subscription" }
    }
    
    # Print results
    foreach ($r in $results) {
        switch ($r.status) {
            "pass" { Write-Host "  ✓ $($r.name)" -ForegroundColor Green -NoNewline; Write-Host " — $($r.detail)" }
            "fail" { Write-Host "  ✗ $($r.name)" -ForegroundColor Red -NoNewline; Write-Host " — $($r.detail)" }
            "warn" { Write-Host "  ⚠ $($r.name)" -ForegroundColor Yellow -NoNewline; Write-Host " — $($r.detail)" }
        }
    }
    
    $passed = ($results | Where-Object { $_.status -eq "pass" }).Count
    $failed = ($results | Where-Object { $_.status -eq "fail" }).Count
    $warned = ($results | Where-Object { $_.status -eq "warn" }).Count
    
    Write-Host "`n  ─────────────────────────────────" 
    Write-Host "  $passed passed, $failed failed, $warned warnings" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
    
    if ($failed -eq 0) {
        Write-Host "`n  ✅ Environment is ready! You can deploy labs.`n" -ForegroundColor Green
    } else {
        Write-Host "`n  ❌ Fix the failures above before deploying.`n" -ForegroundColor Red
    }
    
    return @{ passed = $passed; failed = $failed; warnings = $warned; results = $results } | ConvertTo-Json -Depth 3
}

# ============================================================================
# ANALYZE — Inspect a lab repo
# ============================================================================

function Invoke-Analyze {
    if (-not $RepoUrl) { throw "RepoUrl is required for analyze" }
    
    Write-Host "`n🔍 Analyzing lab: $(Get-LabCode $RepoUrl)`n" -ForegroundColor Cyan
    
    $labCode = Get-LabCode $RepoUrl
    $tempDir = Join-Path $env:TEMP "lab-analyze-$labCode"
    
    if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
    
    Write-Host "  Cloning repository..."
    git clone --depth 1 $RepoUrl $tempDir 2>&1 | Out-Null
    
    # Find azure.yaml
    $azdPath = Find-AzureYaml $tempDir
    
    $result = @{
        lab_code = $labCode
        repo_url = $RepoUrl
        has_azure_yaml = $null -ne $azdPath
        azure_yaml_path = if ($azdPath) { (Resolve-Path $azdPath -Relative) } else { $null }
        has_infra = Test-Path (Join-Path $tempDir "infra")
        has_terraform = (Get-ChildItem $tempDir -Recurse -Filter "*.tf" -File -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0
        has_dockerfile = (Get-ChildItem $tempDir -Recurse -Filter "Dockerfile" | Measure-Object).Count -gt 0
        is_deployable = $null -ne $azdPath
        env_overrides = Get-LabConfig $labCode
    }
    
    if ($azdPath) {
        $yamlContent = Get-Content (Join-Path $azdPath "azure.yaml") -Raw
        $result.azure_yaml_content = $yamlContent
        $result.uses_docker = $yamlContent -match "docker|container"
        $result.uses_hosted_agents = $yamlContent -match "azure\.ai\.agent|host:\s*azure"
    }
    
    # Determine infra type
    $infraType = if ($result.has_azure_yaml -and $result.has_infra) { '✅ Bicep (azd)' }
                 elseif ($result.has_terraform) { '✅ Terraform (not azd)' }
                 elseif ($result.has_infra) { '✅ Bicep' }
                 else { '❌ Missing' }
    
    # Output
    Write-Host "  Lab Code:        $($result.lab_code)"
    Write-Host "  Deployable:      $(if ($result.is_deployable) { '✅ Yes (azd)' } elseif ($result.has_terraform) { '⚠️ Terraform only' } else { '❌ No' })"
    Write-Host "  azure.yaml:      $(if ($result.has_azure_yaml) { $result.azure_yaml_path } else { 'Not found' })"
    Write-Host "  Infrastructure:  $infraType"
    Write-Host "  Docker:          $(if ($result.has_dockerfile) { '✅ Yes' } else { 'No' })"
    Write-Host "  Hosted Agents:   $(if ($result.uses_hosted_agents) { '✅ Yes (needs ENABLE_CAPABILITY_HOST=true)' } else { 'No' })"
    
    if ($result.env_overrides -and $result.env_overrides.Count -gt 0) {
        Write-Host "  Env Overrides:"
        $result.env_overrides.GetEnumerator() | ForEach-Object { Write-Host "    $($_.Key) = $($_.Value)" }
    }
    
    # Cleanup
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    
    return $result | ConvertTo-Json -Depth 3
}

# ============================================================================
# PREPARE — Guide user to make a lab repo deployment-ready
# ============================================================================

function Invoke-Prepare {
    if (-not $RepoUrl) { throw "RepoUrl is required for prepare" }
    
    $labCode = Get-LabCode $RepoUrl
    Write-Host "`n🔧 Preparing $labCode for deployment`n" -ForegroundColor Cyan
    
    $tempDir = Join-Path $env:TEMP "lab-prepare-$labCode"
    if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
    
    Write-Host "  Cloning repository..."
    git clone --depth 1 $RepoUrl $tempDir 2>&1 | Out-Null
    
    $issues = @()
    $fixes = @()
    
    # Check 1: azure.yaml
    $azdPath = Find-AzureYaml $tempDir
    if (-not $azdPath) {
        $issues += @{ id = "no-azure-yaml"; severity = "critical"; message = "No azure.yaml found — required for azd deployment" }
        $fixes += @{
            id = "no-azure-yaml"
            action = "Create azure.yaml in the repo root"
            guidance = @"
  Run this command in the repo root:
    azd init
  
  Or create azure.yaml manually based on your app type:
  - Python Flask/FastAPI on Container Apps:
      services:
        web:
          project: ./src
          host: containerapp
          language: python
  - Node.js on App Service:
      services:
        web:
          project: ./src  
          host: appservice
          language: js
  - Hosted AI Agent (Foundry):
      services:
        agent:
          project: ./src
          host: azure.ai.agent
          language: docker
"@
        }
    }
    
    # Check 2: infra/ directory
    $hasInfra = Test-Path (Join-Path $tempDir "infra")
    if ($azdPath) { $hasInfra = $hasInfra -or (Test-Path (Join-Path $azdPath "infra")) }
    if (-not $hasInfra) {
        $issues += @{ id = "no-infra"; severity = "critical"; message = "No infra/ directory found — Bicep/Terraform templates needed" }
        $fixes += @{
            id = "no-infra"
            action = "Create infra/ with Bicep templates"
            guidance = @"
  Create infra/main.bicep with required resources. Common patterns:
  - AI Agent labs: Foundry Account + Project + Model Deployment + ACR
  - Web App labs: Container Apps + Cosmos DB / SQL
  - Data labs: Fabric + Foundry + Storage
  
  Quick start: azd init --template <similar-template>
  Browse templates: azd template list
"@
        }
    }
    
    # Check 3: Docker
    $hasDockerfile = (Get-ChildItem $tempDir -Recurse -Filter "Dockerfile" | Measure-Object).Count -gt 0
    if ($hasDockerfile) {
        # Check if remoteBuild is configured (no local Docker needed)
        $azureYamlContent = Get-Content (Join-Path $tempDir "azure.yaml") -Raw -ErrorAction SilentlyContinue
        $hasRemoteBuild = $azureYamlContent -match "remoteBuild:\s*true"
        
        if (-not $hasRemoteBuild) {
            # Check if Docker is running
            $dockerRunning = $false
            try {
                $dockerVer = docker version --format '{{.Server.Version}}' 2>$null
                if ($dockerVer) { $dockerRunning = $true }
            } catch {}
            
            if (-not $dockerRunning) {
                $issues += @{ id = "docker-not-running"; severity = "warning"; message = "Dockerfile found but Docker Desktop is not running" }
            $fixes += @{
                id = "docker-not-running"
                action = "Start Docker Desktop or install it"
                guidance = @"
  This lab uses Docker containers. You need Docker Desktop running:
  
  Install:  winget install Docker.DockerDesktop
  Start:    Start Docker Desktop from Start Menu
  Verify:   docker version
  
  Alternative: Use azd's remote build (no local Docker):
    In azure.yaml, set:
      services:
        web:
          docker:
            remoteBuild: true
"@
            }
        } else {
            Write-Host "  ✓ Docker is running" -ForegroundColor Green
        }
        } else {
            Write-Host "  ✓ remoteBuild enabled — no local Docker needed" -ForegroundColor Green
        }
    }
    
    # Check 4: Environment variables
    $envSample = Get-ChildItem $tempDir -Recurse -Filter ".env.sample" | Select-Object -First 1
    if (-not $envSample) { $envSample = Get-ChildItem $tempDir -Recurse -Filter ".env.example" | Select-Object -First 1 }
    if ($envSample) {
        $envVars = Get-Content $envSample.FullName | Where-Object { $_ -match "^[A-Z_]+=.*" } | ForEach-Object { ($_ -split "=")[0] }
        Write-Host "  ℹ️  Required environment variables: $($envVars -join ', ')" -ForegroundColor Yellow
    }
    
    # Check 5: Requirements/Dependencies
    $hasReqs = Test-Path (Join-Path $tempDir "src" "requirements.txt")
    $hasPackageJson = (Get-ChildItem $tempDir -Recurse -Filter "package.json" -Depth 2 | Measure-Object).Count -gt 0
    $hasCsproj = (Get-ChildItem $tempDir -Recurse -Filter "*.csproj" -Depth 2 | Measure-Object).Count -gt 0
    
    $language = if ($hasReqs) { "Python" } elseif ($hasPackageJson) { "Node.js" } elseif ($hasCsproj) { ".NET" } else { "Unknown" }
    Write-Host "  ℹ️  Detected language: $language"
    
    # Check 6: Hosted agents (needs ENABLE_CAPABILITY_HOST)
    $azdContent = ""
    if ($azdPath) { $azdContent = Get-Content (Join-Path $azdPath "azure.yaml") -Raw -ErrorAction SilentlyContinue }
    if ($azdContent -match "azure\.ai\.agent|host:\s*azure") {
        Write-Host "  ℹ️  This lab uses Hosted Agents — requires:" -ForegroundColor Yellow
        Write-Host "        ENABLE_CAPABILITY_HOST=true"
        Write-Host "        ENABLE_HOSTED_AGENTS=true"
    }
    
    # Print results
    Write-Host ""
    if ($issues.Count -eq 0) {
        Write-Host "  ✅ Lab is deployment-ready! Run:" -ForegroundColor Green
        Write-Host "     .\core\lab-manager.ps1 -Action deploy -RepoUrl '$RepoUrl'"
    } else {
        Write-Host "  ⚠️  $($issues.Count) issue(s) found:" -ForegroundColor Yellow
        Write-Host ""
        foreach ($fix in $fixes) {
            $sev = ($issues | Where-Object { $_.id -eq $fix.id }).severity
            $icon = if ($sev -eq "critical") { "❌" } else { "⚠️" }
            Write-Host "  $icon $($fix.action)" -ForegroundColor $(if ($sev -eq "critical") { "Red" } else { "Yellow" })
            Write-Host "$($fix.guidance)" -ForegroundColor Gray
            Write-Host ""
        }
    }
    
    # Cleanup
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    
    return @{ 
        lab_code = $labCode
        issues_count = $issues.Count
        issues = $issues
        fixes = $fixes
        language = $language
        has_azure_yaml = $null -ne $azdPath
        has_infra = $hasInfra
        has_dockerfile = $hasDockerfile
    } | ConvertTo-Json -Depth 4
}

# ============================================================================
# DEPLOY
# ============================================================================

function Invoke-Deploy {
    if (-not $RepoUrl) { throw "RepoUrl is required for deploy" }
    
    $labCode = Get-LabCode $RepoUrl
    $eventName = Get-EventName $RepoUrl
    $envName = if ($EnvName) { $EnvName } else { "$($labCode.ToLower())-$(Get-Date -Format 'MMdd')" }
    
    Write-Host "`n🚀 Deploying $eventName $labCode as '$envName'`n" -ForegroundColor Cyan
    
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    
    # Clone or find existing clone (event-prefixed so Build & Ignite labs never collide)
    $cloneDir = Join-Path $env:USERPROFILE "$eventName-$labCode"
    if (-not (Test-Path $cloneDir)) {
        Write-Host "  Cloning repository..."
        git clone $RepoUrl $cloneDir 2>&1 | Out-Null
    }
    
    # Find azure.yaml directory
    $azdDir = Find-AzureYaml $cloneDir
    if (-not $azdDir) { throw "No azure.yaml found in $cloneDir" }
    
    Set-Location $azdDir
    
    # Initialize environment
    Write-Host "  Initializing azd environment '$envName'..."
    azd init -e $envName --no-prompt 2>&1 | Out-Null
    
    # Get current subscription from az CLI
    $subId = az account show --query id -o tsv 2>$null
    if (-not $subId) { throw "Not logged in to Azure. Run 'az login' first." }
    Write-Host "  Using subscription: $subId"
    
    # Set base config
    azd env set AZURE_SUBSCRIPTION_ID $subId -e $envName 2>&1 | Out-Null
    azd env set AZURE_LOCATION $Location -e $envName 2>&1 | Out-Null
    azd env set AZURE_PRINCIPAL_TYPE User -e $envName 2>&1 | Out-Null
    
    # Apply lab-specific overrides (from team-config.yaml)
    $overrides = Get-LabConfig $labCode
    if (-not $overrides) { $overrides = @{} }

    # Auto-enable hosted-agent capability when the lab uses Foundry hosted agents,
    # so any event's agent labs work without explicit config.
    $azureYaml = Get-Content (Join-Path $azdDir "azure.yaml") -Raw -ErrorAction SilentlyContinue
    if ($azureYaml -match "azure\.ai\.agent|host:\s*azure") {
        if (-not $overrides.ContainsKey("ENABLE_CAPABILITY_HOST")) { $overrides["ENABLE_CAPABILITY_HOST"] = "true" }
        if (-not $overrides.ContainsKey("ENABLE_HOSTED_AGENTS")) { $overrides["ENABLE_HOSTED_AGENTS"] = "true" }
    }

    if ($overrides.Count -gt 0) {
        foreach ($kv in $overrides.GetEnumerator()) {
            Write-Host "  Setting $($kv.Key) = $($kv.Value)"
            azd env set $kv.Key $kv.Value -e $envName 2>&1 | Out-Null
        }
    }
    
    # Deploy in two phases: provision then deploy (allows fixing env between)
    Write-Host "  Provisioning infrastructure..."
    $startTime = Get-Date
    $provResult = azd provision -e $envName --no-prompt 2>&1
    $provSuccess = $LASTEXITCODE -eq 0
    
    if (-not $provSuccess) {
        $errorText = $provResult -join "`n"
        
        # --- SELF-MITIGATION: Region-restricted resources ---
        $regionRetried = $false
        if ($errorText -match "LocationNotAvailableForResourceType.*?'([^']+)'.*?available.*?regions.*?is\s+'([^']+)'") {
            $blockedResource = $Matches[1]
            $availableRegions = $Matches[2] -split ',\s*'
            
            Write-Host "`n  ⚠️  Region conflict detected!" -ForegroundColor Yellow
            Write-Host "     Resource: $blockedResource" -ForegroundColor Yellow
            Write-Host "     Current region: $Location" -ForegroundColor Yellow
            Write-Host "     Available regions: $($availableRegions -join ', ')" -ForegroundColor Yellow
            
            # Pick best alternate region (prefer common ones)
            $preferredOrder = @('eastus2','swedencentral','westus2','centralus','westus3','australiaeast','northcentralus')
            $alternateRegion = $null
            foreach ($pref in $preferredOrder) {
                if ($availableRegions -contains $pref -and $pref -ne $Location) {
                    $alternateRegion = $pref; break
                }
            }
            if (-not $alternateRegion) { $alternateRegion = $availableRegions | Where-Object { $_ -ne $Location } | Select-Object -First 1 }
            
            if ($alternateRegion) {
                Write-Host "`n  🔄 Self-mitigating: Retrying with region '$alternateRegion'..." -ForegroundColor Cyan
                
                # Delete the RG if it was created in wrong region
                $rgName = "rg-$envName"
                $rgExists = az group exists --name $rgName 2>$null
                if ($rgExists -eq 'true') {
                    Write-Host "  🗑️  Deleting resource group '$rgName' (wrong region)..."
                    az group delete --name $rgName --yes --no-wait 2>&1 | Out-Null
                    Start-Sleep -Seconds 15
                }
                
                # Update location and retry
                azd env set AZURE_LOCATION $alternateRegion -e $envName 2>&1 | Out-Null
                $Location = $alternateRegion
                
                Write-Host "  Provisioning in $alternateRegion..."
                $provResult = azd provision -e $envName --no-prompt 2>&1
                $provSuccess = $LASTEXITCODE -eq 0
                $regionRetried = $true
            }
        }
        
        # --- SELF-MITIGATION: Name conflict (soft-deleted resource) ---
        if (-not $provSuccess -and $errorText -match "(?i)(already exists|conflict|soft.?deleted)") {
            if ($errorText -match "--purge") {
                Write-Host "`n  🔄 Self-mitigating: Resource name conflict (soft-deleted). Purging..." -ForegroundColor Cyan
                # Extract resource name if possible
                if ($errorText -match "(?i)name\s+'([^']+)'.*?soft.?deleted") {
                    $staleResource = $Matches[1]
                    Write-Host "     Stale resource: $staleResource"
                }
                # Retry with purge hint — azd handles purge on retry
                $provResult = azd provision -e $envName --no-prompt 2>&1
                $provSuccess = $LASTEXITCODE -eq 0
            }
        }
        
        if (-not $provSuccess) {
            $duration = (Get-Date) - $startTime
            Write-Host "`n  ❌ Provisioning failed:`n" -ForegroundColor Red
            $provResult | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" }
            
            # Register failed attempt so status/destroy can still find it
            $registry = Get-Registry
            $failedDeployment = @{
                lab_code = $labCode
                event = $eventName
                env_name = $envName
                repo_url = $RepoUrl
                location = $Location
                azd_dir = $azdDir
                failed_at = (Get-Date -Format "o")
                duration_seconds = [int]$duration.TotalSeconds
                status = "failed"
                error_summary = ($provResult | Select-Object -Last 2) -join " "
                mitigation_attempted = $regionRetried
            }
            $registry.deployments = @($registry.deployments) + @($failedDeployment)
            Save-Registry $registry
            
            return @{ success = $false; lab_code = $labCode; env_name = $envName; duration = [int]$duration.TotalSeconds; error = "provision_failed"; mitigation_attempted = $regionRetried; location = $Location } | ConvertTo-Json
        } else {
            Write-Host "  ✅ Self-mitigation successful! Provisioned in $Location" -ForegroundColor Green
        }
    }
    
    # Register immediately after provision so destroy always works (even if deploy times out)
    $registry = Get-Registry
    $deployment = @{
        lab_code = $labCode
        event = $eventName
        env_name = $envName
        repo_url = $RepoUrl
        location = $Location
        azd_dir = $azdDir
        provisioned_at = (Get-Date -Format "o")
        deployed_at = ""
        duration_seconds = 0
        status = "provisioned"
    }
    $registry.deployments = @($registry.deployments) + @($deployment)
    Save-Registry $registry
    
    # Fix common env var issues after provision
    $projectEndpoint = azd env get-value AZURE_AI_PROJECT_ENDPOINT -e $envName 2>$null
    if ($projectEndpoint) {
        $existingFoundry = azd env get-value FOUNDRY_PROJECT_ENDPOINT -e $envName 2>$null
        if (-not $existingFoundry) {
            Write-Host "  Setting FOUNDRY_PROJECT_ENDPOINT..."
            azd env set FOUNDRY_PROJECT_ENDPOINT $projectEndpoint -e $envName 2>&1 | Out-Null
        }
    }
    
    # Now deploy
    Write-Host "  Deploying application..."
    $result = azd deploy -e $envName --no-prompt 2>&1
    $duration = (Get-Date) - $startTime
    
    $success = $LASTEXITCODE -eq 0
    
    # Update registry entry (already registered after provision)
    $registry = Get-Registry
    $registry.deployments | Where-Object { $_.env_name -eq $envName -and $_.status -eq "provisioned" } | ForEach-Object {
        $_.status = if ($success) { "deployed" } else { "partial" }
        $_.deployed_at = (Get-Date -Format "o")
        $_.duration_seconds = [int]$duration.TotalSeconds
    }
    Save-Registry $registry
    
    if ($success) {
        Write-Host "`n  ✅ $labCode deployed in $([int]$duration.TotalMinutes)m $($duration.Seconds)s`n" -ForegroundColor Green
    } else {
        Write-Host "`n  ⚠️ Deploy may have timed out. Agent might still be starting.`n" -ForegroundColor Yellow
        Write-Host "  Try: azd deploy -e $envName --no-prompt" 
        Write-Host "  Or:  azd ai agent show -e $envName"
    }
    
    return @{ success = $success; lab_code = $labCode; env_name = $envName; duration = [int]$duration.TotalSeconds } | ConvertTo-Json
}

# ============================================================================
# DESTROY
# ============================================================================

function Invoke-Destroy {
    if (-not $RepoUrl) { throw "RepoUrl is required for destroy" }
    
    $labCode = Get-LabCode $RepoUrl
    $eventName = Get-EventName $RepoUrl
    
    # Find deployment in registry
    $registry = Get-Registry
    $deployment = $registry.deployments | Where-Object {
        $_.lab_code -eq $labCode -and $_.status -in @("deployed", "partial", "provisioned", "failed") -and
        ((-not $_.event) -or ($_.event -eq $eventName))
    } | Select-Object -Last 1
    
    if (-not $deployment) {
        Write-Host "  ❌ No active deployment found for $eventName $labCode" -ForegroundColor Red
        return @{ success = $false; error = "No deployment found" } | ConvertTo-Json
    }
    
    $envName = if ($EnvName) { $EnvName } else { $deployment.env_name }
    
    Write-Host "`n🗑️  Destroying $eventName $labCode (env: $envName)`n" -ForegroundColor Red
    
    if (-not $Force) {
        Write-Host "  ⚠️  This will PERMANENTLY DELETE all resources for $labCode!" -ForegroundColor Yellow
        Write-Host "  Resource group: rg-$envName"
        Write-Host ""
        $confirm = Read-Host "  Type 'yes' to confirm destruction"
        if ($confirm -ne "yes") {
            Write-Host "  Cancelled." -ForegroundColor Yellow
            return @{ success = $false; error = "Cancelled by user" } | ConvertTo-Json
        }
    }
    
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    Set-Location $deployment.azd_dir
    
    Write-Host "  Running azd down --force --purge..."
    $startTime = Get-Date
    azd down -e $envName --force --purge 2>&1
    $duration = (Get-Date) - $startTime
    $success = $LASTEXITCODE -eq 0
    
    if ($success) {
        # Update registry
        $registry.deployments | Where-Object { $_.env_name -eq $envName } | ForEach-Object {
            $_.status = "destroyed"
            if ($_ | Get-Member -Name destroyed_at -MemberType NoteProperty) {
                $_.destroyed_at = (Get-Date -Format "o")
            } else {
                $_ | Add-Member -NotePropertyName "destroyed_at" -NotePropertyValue (Get-Date -Format "o") -Force
            }
        }
        Save-Registry $registry
        Write-Host "`n  ✅ $labCode destroyed in $([int]$duration.TotalMinutes)m $($duration.Seconds)s`n" -ForegroundColor Green
    } else {
        Write-Host "`n  ❌ Destroy failed. Check Azure portal for orphaned resources.`n" -ForegroundColor Red
    }
    
    return @{ success = $success; lab_code = $labCode; env_name = $envName; duration = [int]$duration.TotalSeconds } | ConvertTo-Json
}

# ============================================================================
# LIST
# ============================================================================

function Invoke-List {
    $registry = Get-Registry
    
    Write-Host "`n📋 Lab Deployments`n" -ForegroundColor Cyan
    
    if (-not $registry.deployments -or $registry.deployments.Count -eq 0) {
        Write-Host "  No deployments tracked yet.`n"
        return "[]"
    }
    
    $registry.deployments | ForEach-Object {
        $statusIcon = switch ($_.status) { "deployed" { "🟢" }; "destroyed" { "⚫" }; "partial" { "🟡" }; "failed" { "🔴" }; default { "❓" } }
        $evt = if ($_.event) { "$($_.event) " } else { "" }
        Write-Host "  $statusIcon $evt$($_.lab_code) | env: $($_.env_name) | $($_.status) | $($_.deployed_at)"
    }
    
    Write-Host ""
    return $registry.deployments | ConvertTo-Json -Depth 3
}

# ============================================================================
# STATUS
# ============================================================================

function Invoke-Status {
    if (-not $RepoUrl) { throw "RepoUrl is required for status" }
    
    $labCode = Get-LabCode $RepoUrl
    $eventName = Get-EventName $RepoUrl
    $registry = Get-Registry
    $deployment = $registry.deployments | Where-Object {
        $_.lab_code -eq $labCode -and $_.status -in @("deployed", "partial", "provisioned", "failed") -and
        ((-not $_.event) -or ($_.event -eq $eventName))
    } | Select-Object -Last 1
    
    if (-not $deployment) {
        Write-Host "  No active deployment for $eventName $labCode" -ForegroundColor Yellow
        return @{ status = "not_deployed"; lab_code = $labCode } | ConvertTo-Json
    }
    
    # Show failed deployments with mitigation info
    if ($deployment.status -eq "failed") {
        Write-Host "`n📊 Status: $eventName $labCode — ❌ FAILED`n" -ForegroundColor Red
        Write-Host "  Failed at:   $($deployment.failed_at)"
        Write-Host "  Location:    $($deployment.location)"
        Write-Host "  Error:       $($deployment.error_summary)"
        Write-Host "  Mitigation:  $(if ($deployment.mitigation_attempted) { 'Attempted (region retry)' } else { 'Not attempted' })"
        Write-Host ""
        return @{ status = "failed"; lab_code = $labCode; env_name = $deployment.env_name; error = $deployment.error_summary; mitigation_attempted = $deployment.mitigation_attempted } | ConvertTo-Json
    }
    
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    Set-Location $deployment.azd_dir
    
    Write-Host "`n📊 Status: $eventName $labCode (env: $($deployment.env_name))`n" -ForegroundColor Cyan
    Write-Host "  Deployed at: $($deployment.deployed_at)"
    Write-Host "  Location:    $($deployment.location)"
    Write-Host "  azd dir:     $($deployment.azd_dir)"
    
    # Check if resources exist
    $rgExists = az group exists --name "rg-$($deployment.env_name)" 2>$null
    Write-Host "  RG exists:   $rgExists"
    
    return @{ status = "deployed"; lab_code = $labCode; env_name = $deployment.env_name; rg_exists = $rgExists } | ConvertTo-Json
}

# ============================================================================
# OUTLINE — Break a lab into ordered modules with commands + verification
# ============================================================================

function Invoke-Outline {
    if (-not $RepoUrl) { throw "RepoUrl is required for outline" }

    $labCode = Get-LabCode $RepoUrl
    Write-Host "`n🧭 Outlining $labCode into modules`n" -ForegroundColor Cyan

    $tempDir = Join-Path $env:TEMP "lab-outline-$labCode"
    if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }

    Write-Host "  Cloning repository..."
    git clone --depth 1 $RepoUrl $tempDir 2>&1 | Out-Null

    $mdFiles = Get-MarkdownFiles $tempDir
    if (-not $mdFiles -or @($mdFiles).Count -eq 0) {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        Write-Host "  ❌ No markdown instructions found in this repo." -ForegroundColor Red
        return @{ lab_code = $labCode; module_count = 0; modules = @() } | ConvertTo-Json -Depth 6
    }

    # Detect a multi-file lab: a folder holding >=2 numbered/keyworded instruction files.
    $source = ''
    $sourceFiles = @()
    $rawModules = @()

    $byDir = $mdFiles | Group-Object DirectoryName | Sort-Object { @($_.Group).Count } -Descending
    $seqFiles = $null
    foreach ($g in $byDir) {
        $numbered = $g.Group | Where-Object {
            $_.Name -match '(?i)^(?:\d+|module|exercise|chapter|part|lab|step)[-_. ]*\d*' -and $_.Name -match '\d'
        }
        if (@($numbered).Count -ge 2) { $seqFiles = $numbered; break }
    }

    if ($seqFiles) {
        $source = 'multi-file'
        $ordered = $seqFiles | Sort-Object @(
            @{ Expression = { if ($_.Name -match '(\d+)') { [int]$Matches[1] } else { 9999 } } },
            @{ Expression = { $_.Name } }
        )
        foreach ($f in $ordered) {
            $txt = Get-Content $f.FullName -Raw
            $title = (Get-HeadingTitle $txt)
            if (-not $title) { $title = [System.IO.Path]::GetFileNameWithoutExtension($f.Name) }
            $rel = $f.FullName.Substring($tempDir.Length).TrimStart('\','/')
            $sourceFiles += $rel
            $rawModules += [ordered]@{ title = $title; body = $txt; file = $rel }
        }
    } else {
        # Single instruction file: pick the most chapter-structured one.
        $scored = $mdFiles | ForEach-Object {
            $txt = Get-Content $_.FullName -Raw
            $count = ([regex]::Matches($txt, '(?im)^#{1,4}\s+(?:module|chapter|exercise|task|part|step|lab)\s*#?\s*\d+')).Count
            [PSCustomObject]@{ File = $_; Text = $txt; Score = $count; IsReadme = ($_.Name -ieq 'README.md'); Size = $_.Length }
        }
        $best = $scored | Sort-Object `
            @{ Expression = 'Score'; Descending = $true }, `
            @{ Expression = 'IsReadme'; Descending = $true }, `
            @{ Expression = 'Size'; Descending = $true } | Select-Object -First 1
        $source = if ($best.IsReadme) { 'readme' } else { 'single-file' }
        $rel = $best.File.FullName.Substring($tempDir.Length).TrimStart('\','/')
        $sourceFiles += $rel
        foreach ($m in (Split-BodyIntoModules $best.Text)) {
            $m.file = $rel
            $rawModules += $m
        }
        if (@($rawModules).Count -eq 0) {
            $rawModules += [ordered]@{ title = 'Lab'; body = $best.Text; file = $rel }
        }
    }

    # Enrich each module with commands + verification steps.
    $modules = @()
    $i = 0
    foreach ($m in $rawModules) {
        $i++
        $cmds = Get-CommandsFromBody $m.body
        $veris = Get-VerificationFromBody $m.body
        $modules += [ordered]@{
            index              = $i
            title              = $m.title
            file               = $m.file
            kind               = (Get-ModuleKind $cmds $veris)
            command_count      = @($cmds).Count
            commands           = @($cmds)
            verification_count = @($veris).Count
            verification       = @($veris)
        }
    }

    # Human-readable summary
    Write-Host "  Source: $source ($(@($sourceFiles).Count) file(s))"
    Write-Host "  Modules detected: $(@($modules).Count)`n"
    foreach ($m in $modules) {
        $icon = switch ($m.kind) { 'deploy' { '🚀' }; 'configure' { '🔧' }; 'verify' { '✅' }; 'cleanup' { '🗑️' }; default { '📖' } }
        Write-Host "  $icon Module $($m.index): $($m.title)" -ForegroundColor Cyan
        Write-Host "      kind: $($m.kind) | commands: $($m.command_count) | manual checks: $($m.verification_count)"
        if ($m.verification_count -gt 0) {
            Write-Host "      Manual verification:" -ForegroundColor Yellow
            foreach ($v in $m.verification) { Write-Host "        • $v" }
        }
    }
    Write-Host ""
    Write-Host "  Run this lab module-by-module with manual verification gates between modules." -ForegroundColor Green
    Write-Host ""

    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue

    return @{
        lab_code     = $labCode
        repo_url     = $RepoUrl
        source       = $source
        source_files = @($sourceFiles)
        module_count = @($modules).Count
        modules      = @($modules)
    } | ConvertTo-Json -Depth 6
}

# ============================================================================
# MAIN DISPATCH
# ============================================================================

switch ($Action) {
    "doctor"   { Invoke-Doctor }
    "analyze"  { Invoke-Analyze }
    "prepare"  { Invoke-Prepare }
    "outline"  { Invoke-Outline }
    "generate" {
        # Dot-source the AVM composer module
        . (Join-Path $PSScriptRoot "avm-composer.ps1")
        Invoke-Generate -RepoUrl $RepoUrl -Force:$Force
    }
    "deploy"   { Invoke-Deploy }
    "destroy"  { Invoke-Destroy }
    "list"     { Invoke-List }
    "status"   { Invoke-Status }
}
