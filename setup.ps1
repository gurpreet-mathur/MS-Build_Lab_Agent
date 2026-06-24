<#
.SYNOPSIS
    One-command bootstrap for the Lab Lifecycle Agent Skill.
    Run this if you're a first-time user with no prior setup.

.DESCRIPTION
    This script:
    1. Checks and installs missing prerequisites (with user confirmation)
    2. Clones the skill repo (if not already present)
    3. Configures MCP server for VS Code (optional)
    4. Runs doctor to validate everything
    5. Shows you how to use the skill

.EXAMPLE
    # Run from anywhere:
    irm https://raw.githubusercontent.com/msbl26/lab-lifecycle-skill/main/setup.ps1 | iex

    # Or if you already cloned:
    .\setup.ps1
#>

param(
    [string]$InstallDir = (Join-Path $env:USERPROFILE "lab-lifecycle-skill"),
    [switch]$SkipMcp,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
Write-Host "`n🧪 Lab Lifecycle Agent Skill — First-Time Setup`n" -ForegroundColor Cyan
Write-Host "  This will set up everything you need to deploy Build/Ignite labs.`n"

# ============================================================================
# STEP 1: Check prerequisites
# ============================================================================

Write-Host "📋 Step 1: Checking prerequisites...`n" -ForegroundColor Yellow

$missing = @()

# PowerShell 7+
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $missing += @{ name = "PowerShell 7+"; install = "winget install Microsoft.PowerShell" }
} else {
    Write-Host "  ✓ PowerShell $($PSVersionTable.PSVersion)" -ForegroundColor Green
}

# Azure CLI
$azVersion = az version --query '\"azure-cli\"' -o tsv 2>$null
if (-not $azVersion) {
    $missing += @{ name = "Azure CLI"; install = "winget install Microsoft.AzureCLI" }
} else {
    Write-Host "  ✓ Azure CLI $azVersion" -ForegroundColor Green
}

# azd
$azdVersion = azd version 2>$null | Select-Object -First 1
if (-not $azdVersion) {
    $missing += @{ name = "Azure Developer CLI (azd)"; install = "winget install Microsoft.Azd" }
} else {
    Write-Host "  ✓ azd $($azdVersion -replace 'azd version ','')" -ForegroundColor Green
}

# Git
$gitVersion = git --version 2>$null
if (-not $gitVersion) {
    $missing += @{ name = "Git"; install = "winget install Git.Git" }
} else {
    Write-Host "  ✓ $gitVersion" -ForegroundColor Green
}

# Node.js
$nodeVersion = node --version 2>$null
if (-not $nodeVersion) {
    $missing += @{ name = "Node.js 18+"; install = "winget install OpenJS.NodeJS.LTS" }
} else {
    Write-Host "  ✓ Node.js $nodeVersion" -ForegroundColor Green
}

if ($missing.Count -gt 0) {
    Write-Host "`n  ⚠️  Missing prerequisites:" -ForegroundColor Yellow
    foreach ($m in $missing) {
        Write-Host "     • $($m.name): $($m.install)" -ForegroundColor Red
    }
    Write-Host ""
    $installChoice = Read-Host "  Install missing tools now? (y/n)"
    if ($installChoice -eq 'y') {
        foreach ($m in $missing) {
            Write-Host "  Installing $($m.name)..."
            Invoke-Expression $m.install
        }
        Write-Host "`n  ✅ Prerequisites installed. You may need to restart your terminal.`n" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Please install the missing tools and re-run this script.`n" -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================================
# STEP 2: Clone skill repo
# ============================================================================

Write-Host "`n📥 Step 2: Getting the skill...`n" -ForegroundColor Yellow

if (Test-Path $InstallDir) {
    Write-Host "  ✓ Skill already present at: $InstallDir" -ForegroundColor Green
    Set-Location $InstallDir
    git pull --quiet 2>$null
} else {
    Write-Host "  Cloning to: $InstallDir"
    git clone https://github.com/msbl26/lab-lifecycle-skill.git $InstallDir 2>&1 | Out-Null
    Set-Location $InstallDir
    Write-Host "  ✓ Cloned successfully" -ForegroundColor Green
}

# ============================================================================
# STEP 3: Install azd AI Agents extension
# ============================================================================

Write-Host "`n🔌 Step 3: Installing azd extensions...`n" -ForegroundColor Yellow

$extInstalled = azd extension list 2>$null | Select-String "azure.ai.agents"
if (-not $extInstalled) {
    azd extension install azure.ai.agents 2>&1 | Out-Null
    Write-Host "  ✓ azd AI Agents extension installed" -ForegroundColor Green
} else {
    Write-Host "  ✓ azd AI Agents extension already installed" -ForegroundColor Green
}

# ============================================================================
# STEP 4: Azure login check
# ============================================================================

Write-Host "`n🔐 Step 4: Azure authentication...`n" -ForegroundColor Yellow

$account = az account show --query "{name:name, id:id}" -o tsv 2>$null
if (-not $account) {
    Write-Host "  Not logged in. Opening Azure login..."
    az login 2>&1 | Out-Null
    $account = az account show --query "{name:name, id:id}" -o tsv 2>$null
}
Write-Host "  ✓ Logged in: $account" -ForegroundColor Green

# ============================================================================
# STEP 5: Configure MCP (optional)
# ============================================================================

if (-not $SkipMcp) {
    Write-Host "`n🔧 Step 5: VS Code MCP configuration...`n" -ForegroundColor Yellow
    
    $mcpPath = Join-Path $env:USERPROFILE ".vscode" "mcp.json"
    $mcpServerPath = (Join-Path $InstallDir "mcp-server" "src" "index.js") -replace '\\', '/'
    
    if (Test-Path $mcpPath) {
        $existing = Get-Content $mcpPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($existing.servers.'lab-lifecycle') {
            Write-Host "  ✓ MCP already configured" -ForegroundColor Green
        } else {
            Write-Host "  ⚠️  Existing mcp.json found. Add manually:" -ForegroundColor Yellow
            Write-Host "     ""lab-lifecycle"": { ""command"": ""node"", ""args"": [""$mcpServerPath""], ""transport"": ""stdio"" }"
        }
    } else {
        $mcpConfig = @{
            servers = @{
                'lab-lifecycle' = @{
                    command = 'node'
                    args = @($mcpServerPath)
                    transport = 'stdio'
                }
            }
        }
        $mcpDir = Split-Path $mcpPath
        if (-not (Test-Path $mcpDir)) { New-Item -Path $mcpDir -ItemType Directory -Force | Out-Null }
        $mcpConfig | ConvertTo-Json -Depth 4 | Set-Content $mcpPath -Encoding UTF8
        Write-Host "  ✓ MCP configured at: $mcpPath" -ForegroundColor Green
    }
}

# ============================================================================
# STEP 6: Run doctor
# ============================================================================

Write-Host "`n🩺 Step 6: Final validation...`n" -ForegroundColor Yellow

& (Join-Path $InstallDir "core" "lab-manager.ps1") -Action doctor

# ============================================================================
# DONE
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host "  ✅ Setup complete! You're ready to use the Lab Lifecycle Skill." -ForegroundColor Green
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
Write-Host ""
Write-Host "  📖 Usage:" -ForegroundColor White
Write-Host "     cd $InstallDir"
Write-Host "     .\core\lab-manager.ps1 -Action deploy -RepoUrl ""<lab-url>"""
Write-Host ""
Write-Host "  🔥 Try it now:" -ForegroundColor White
Write-Host "     .\core\lab-manager.ps1 -Action analyze -RepoUrl ""https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps.git"""
Write-Host ""
Write-Host "  🤖 With Copilot CLI (from this directory):" -ForegroundColor White
Write-Host "     Just ask: ""Deploy LAB520 for my demo"""
Write-Host ""
Write-Host "  📋 Full guide: ONBOARDING.md" -ForegroundColor White
Write-Host ""
