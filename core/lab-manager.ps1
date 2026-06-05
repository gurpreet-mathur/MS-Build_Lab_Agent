<#
.SYNOPSIS
    Lab Lifecycle Manager — deploy, manage, and destroy Microsoft Build labs.

.DESCRIPTION
    Core engine for the Lab Lifecycle Skill. Supports actions:
    - doctor:  Validate all prerequisites
    - analyze: Inspect a lab repo and report requirements
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
    [Parameter(Mandatory)][ValidateSet("doctor","analyze","deploy","destroy","list","status")]
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
        return Get-Content $RegistryPath | ConvertFrom-Json
    }
    return @{ deployments = @() }
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

function Get-TeamConfig {
    if (Test-Path $ConfigFile) {
        # Simple YAML parsing for our flat structure
        $content = Get-Content $ConfigFile -Raw
        return $content
    }
    return $null
}

function Get-LabConfig($labCode) {
    $config = Get-TeamConfig
    if (-not $config) { return $null }
    # Extract lab-specific env_overrides from team config
    $envOverrides = @{}
    switch ($labCode) {
        "LAB540" { $envOverrides = @{ ENABLE_CAPABILITY_HOST = "true"; ENABLE_HOSTED_AGENTS = "true" } }
        "LAB520" { $envOverrides = @{} }
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
    
    # Output
    Write-Host "  Lab Code:        $($result.lab_code)"
    Write-Host "  Deployable:      $(if ($result.is_deployable) { '✅ Yes' } else { '❌ No' })"
    Write-Host "  azure.yaml:      $(if ($result.has_azure_yaml) { $result.azure_yaml_path } else { 'Not found' })"
    Write-Host "  Infrastructure:  $(if ($result.has_infra) { '✅ Bicep' } else { '❌ Missing' })"
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
# DEPLOY
# ============================================================================

function Invoke-Deploy {
    if (-not $RepoUrl) { throw "RepoUrl is required for deploy" }
    
    $labCode = Get-LabCode $RepoUrl
    $envName = if ($EnvName) { $EnvName } else { "$($labCode.ToLower())-$(Get-Date -Format 'MMdd')" }
    
    Write-Host "`n🚀 Deploying $labCode as '$envName'`n" -ForegroundColor Cyan
    
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    
    # Clone or find existing clone
    $cloneDir = Join-Path $env:USERPROFILE "Build26-$labCode"
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
    
    # Set base config
    azd env set AZURE_LOCATION $Location -e $envName 2>&1 | Out-Null
    azd env set AZURE_PRINCIPAL_TYPE User -e $envName 2>&1 | Out-Null
    
    # Apply lab-specific overrides
    $overrides = Get-LabConfig $labCode
    if ($overrides) {
        foreach ($kv in $overrides.GetEnumerator()) {
            Write-Host "  Setting $($kv.Key) = $($kv.Value)"
            azd env set $kv.Key $kv.Value -e $envName 2>&1 | Out-Null
        }
    }
    
    # Deploy
    Write-Host "  Running azd up (this may take 5-15 minutes)..."
    $startTime = Get-Date
    $result = azd up -e $envName --no-prompt 2>&1
    $duration = (Get-Date) - $startTime
    
    $success = $LASTEXITCODE -eq 0
    
    # Register deployment
    $registry = Get-Registry
    $deployment = @{
        lab_code = $labCode
        env_name = $envName
        repo_url = $RepoUrl
        location = $Location
        azd_dir = $azdDir
        deployed_at = (Get-Date -Format "o")
        duration_seconds = [int]$duration.TotalSeconds
        status = if ($success) { "deployed" } else { "partial" }
    }
    $registry.deployments += $deployment
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
    
    # Find deployment in registry
    $registry = Get-Registry
    $deployment = $registry.deployments | Where-Object { $_.lab_code -eq $labCode -and $_.status -eq "deployed" } | Select-Object -Last 1
    
    if (-not $deployment) {
        Write-Host "  ❌ No active deployment found for $labCode" -ForegroundColor Red
        return @{ success = $false; error = "No deployment found" } | ConvertTo-Json
    }
    
    $envName = if ($EnvName) { $EnvName } else { $deployment.env_name }
    
    Write-Host "`n🗑️  Destroying $labCode (env: $envName)`n" -ForegroundColor Red
    
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
        $registry.deployments | Where-Object { $_.env_name -eq $envName } | ForEach-Object { $_.status = "destroyed"; $_.destroyed_at = (Get-Date -Format "o") }
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
        $statusIcon = switch ($_.status) { "deployed" { "🟢" }; "destroyed" { "⚫" }; "partial" { "🟡" }; default { "❓" } }
        Write-Host "  $statusIcon $($_.lab_code) | env: $($_.env_name) | $($_.status) | $($_.deployed_at)"
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
    $registry = Get-Registry
    $deployment = $registry.deployments | Where-Object { $_.lab_code -eq $labCode -and $_.status -eq "deployed" } | Select-Object -Last 1
    
    if (-not $deployment) {
        Write-Host "  No active deployment for $labCode" -ForegroundColor Yellow
        return @{ status = "not_deployed"; lab_code = $labCode } | ConvertTo-Json
    }
    
    $env:PATH = "$env:LOCALAPPDATA\Programs\Azure Dev CLI;$env:PATH"
    Set-Location $deployment.azd_dir
    
    Write-Host "`n📊 Status: $labCode (env: $($deployment.env_name))`n" -ForegroundColor Cyan
    Write-Host "  Deployed at: $($deployment.deployed_at)"
    Write-Host "  Location:    $($deployment.location)"
    Write-Host "  azd dir:     $($deployment.azd_dir)"
    
    # Check if resources exist
    $rgExists = az group exists --name "rg-$($deployment.env_name)" 2>$null
    Write-Host "  RG exists:   $rgExists"
    
    return @{ status = "deployed"; lab_code = $labCode; env_name = $deployment.env_name; rg_exists = $rgExists } | ConvertTo-Json
}

# ============================================================================
# MAIN DISPATCH
# ============================================================================

switch ($Action) {
    "doctor"  { Invoke-Doctor }
    "analyze" { Invoke-Analyze }
    "deploy"  { Invoke-Deploy }
    "destroy" { Invoke-Destroy }
    "list"    { Invoke-List }
    "status"  { Invoke-Status }
}
