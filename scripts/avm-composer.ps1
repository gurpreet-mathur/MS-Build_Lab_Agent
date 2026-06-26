<#
.SYNOPSIS
    AVM Composer — generates Azure Verified Module-based IaC for labs that lack infrastructure code.

.DESCRIPTION
    Part of the Lab Lifecycle Skill. Invoked by the `generate` action when a lab repo
    has no azure.yaml or infra/ directory. Performs multi-source resource inference,
    maps to AVM modules, and generates deployment-ready Bicep + azure.yaml.

    Flow: INFER → MAP → COMPOSE → VALIDATE → REPORT
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$script:TemplatesDir = Join-Path (Split-Path $PSScriptRoot -Parent) "assets\templates"

# AVM Module Registry (Bicep public registry references)
$script:AvmPatternModules = @{
    'ai-foundry' = @{
        ref = 'br/public:avm/ptn/ai-ml/ai-foundry:0.1.0'
        description = 'AI Foundry account + project + capability host + model deployments'
        provisions = @('AI Services', 'AI Hub', 'AI Project', 'Model Deployments', 'Storage', 'Key Vault')
        signals = @('Azure OpenAI', 'AI Services', 'Foundry', 'GPT', 'AI Hub', 'AI Project', 'hosted agent', 'model deployment')
        minSignals = 2
    }
    'container-apps' = @{
        ref = 'br/public:avm/ptn/azd/container-apps-stack:0.1.0'
        description = 'Container Apps + ACR + managed environment'
        provisions = @('Container Apps', 'Container Registry', 'Managed Environment')
        signals = @('Container App', 'ACA', 'containerapp', 'docker compose', 'managed environment')
        minSignals = 2
    }
    'monitoring' = @{
        ref = 'br/public:avm/ptn/azd/monitoring:0.1.0'
        description = 'Log Analytics + Application Insights'
        provisions = @('Log Analytics', 'Application Insights')
        signals = @('monitoring', 'observability', 'Application Insights', 'Log Analytics', 'diagnostics')
        minSignals = 1
    }
}

$script:AvmResourceModules = @{
    'sql-server' = @{
        ref = 'br/public:avm/res/sql/server:0.12.0'
        description = 'Azure SQL Server + databases'
        signals = @('Azure SQL', 'SQL Server', 'SQL Database', 'Hyperscale', 'sqlcmd', 'T-SQL')
    }
    'cognitive-services' = @{
        ref = 'br/public:avm/res/cognitive-services/account:0.10.0'
        description = 'Cognitive Services (OpenAI, Vision, Speech, etc.)'
        signals = @('Azure OpenAI', 'Cognitive Services', 'GPT', 'embedding', 'text-embedding', 'gpt-4')
    }
    'cosmos-db' = @{
        ref = 'br/public:avm/res/document-db/database-account:0.11.0'
        description = 'Cosmos DB database account'
        signals = @('Cosmos DB', 'CosmosDB', 'MongoDB', 'NoSQL database', 'document database')
    }
    'storage-account' = @{
        ref = 'br/public:avm/res/storage/storage-account:0.15.0'
        description = 'Storage Account (Blob, Files, Queue, Table)'
        signals = @('Storage Account', 'Blob', 'Data Lake', 'ADLS', 'file share', 'blob storage')
    }
    'search-service' = @{
        ref = 'br/public:avm/res/search/search-service:0.8.0'
        description = 'Azure AI Search'
        signals = @('AI Search', 'Cognitive Search', 'search service', 'search index', 'vector search')
    }
    'key-vault' = @{
        ref = 'br/public:avm/res/key-vault/vault:0.11.0'
        description = 'Azure Key Vault'
        signals = @('Key Vault', 'secrets', 'certificates', 'managed identity')
    }
    'container-registry' = @{
        ref = 'br/public:avm/res/container-registry/registry:0.7.0'
        description = 'Azure Container Registry'
        signals = @('Container Registry', 'ACR', 'docker push', 'container image')
    }
    'aks-cluster' = @{
        ref = 'br/public:avm/res/container-service/managed-cluster:0.8.0'
        description = 'Azure Kubernetes Service (AKS) cluster'
        signals = @('AKS', 'Kubernetes', 'kubectl', 'helm', 'k8s', 'managed cluster', 'node pool', 'KAITO')
    }
    'app-service' = @{
        ref = 'br/public:avm/res/web/site:0.15.0'
        description = 'App Service / Web App'
        signals = @('App Service', 'Web App', 'webapp', 'app service plan')
    }
    'postgresql' = @{
        ref = 'br/public:avm/res/db-for-postgre-sql/flexible-server:0.5.0'
        description = 'PostgreSQL Flexible Server'
        signals = @('PostgreSQL', 'Postgres', 'psql', 'pgvector')
    }
    'event-hub' = @{
        ref = 'br/public:avm/res/event-hub/namespace:0.8.0'
        description = 'Event Hub namespace'
        signals = @('Event Hub', 'EventHub', 'event streaming', 'Kafka')
    }
}

# ============================================================================
# RESOURCE INFERENCE
# ============================================================================

function Get-InferredResources {
    param([string]$RepoPath)

    $manifest = @()

    # --- Source 1: Markdown files ---
    $mdFiles = Get-ChildItem $RepoPath -Recurse -Filter *.md -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|\.github|bin|obj|dist|\.venv|venv)[\\/]' }

    $mdContent = ($mdFiles | ForEach-Object { Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue }) -join "`n"

    # --- Source 2: Dependency files ---
    $depFiles = @('requirements.txt', 'pyproject.toml', 'package.json', '*.csproj')
    $depContent = ""
    foreach ($pat in $depFiles) {
        $found = Get-ChildItem $RepoPath -Recurse -Filter $pat -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git|\.venv|venv)[\\/]' }
        foreach ($f in $found) {
            $depContent += "`n" + (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
        }
    }

    # --- Source 3: Config/env files ---
    $envFiles = @('.env.example', '.env.sample', 'sample.env', 'appsettings.json', 'local.settings.json')
    $envContent = ""
    foreach ($name in $envFiles) {
        $found = Get-ChildItem $RepoPath -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' } | Select-Object -First 3
        foreach ($f in $found) {
            $envContent += "`n" + (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
        }
    }

    # --- Source 4: Dockerfiles ---
    $dockerContent = ""
    $dockerFiles = Get-ChildItem $RepoPath -Recurse -Filter "Dockerfile*" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](node_modules|\.git)[\\/]' }
    foreach ($f in $dockerFiles) {
        $dockerContent += "`n" + (Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue)
    }

    # Combine all content for searching
    $allContent = "$mdContent`n$depContent`n$envContent`n$dockerContent"

    # --- Check each resource module ---
    $allModules = @{}
    $script:AvmResourceModules.GetEnumerator() | ForEach-Object { $allModules[$_.Key] = $_.Value }

    foreach ($entry in $allModules.GetEnumerator()) {
        $moduleName = $entry.Key
        $module = $entry.Value
        $evidence = @()
        $matchCount = 0

        foreach ($signal in $module.signals) {
            $pattern = [regex]::Escape($signal)
            # Check markdown (highest confidence source)
            $mdMatches = [regex]::Matches($mdContent, "(?i)$pattern")
            if ($mdMatches.Count -gt 0) {
                $matchCount++
                # Find which file contains it
                foreach ($f in $mdFiles) {
                    $fc = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
                    if ($fc -match "(?i)$pattern") {
                        $relPath = $f.FullName.Substring($RepoPath.Length + 1)
                        $evidence += "$relPath (signal: '$signal')"
                        break
                    }
                }
            }
            # Check deps/config (medium confidence)
            if ("$depContent$envContent" -match "(?i)$pattern") {
                $matchCount++
                $evidence += "dependency/config (signal: '$signal')"
            }
        }

        if ($matchCount -gt 0) {
            $confidence = if ($matchCount -ge 3) { 'high' }
                         elseif ($matchCount -ge 2) { 'medium' }
                         else { 'low' }

            $manifest += [ordered]@{
                type = $moduleName
                avmRef = $module.ref
                description = $module.description
                confidence = $confidence
                matchCount = $matchCount
                evidence = $evidence
            }
        }
    }

    return $manifest
}

function Get-PatternModuleMatches {
    param([array]$InferredResources)

    $patterns = @()

    foreach ($entry in $script:AvmPatternModules.GetEnumerator()) {
        $patternName = $entry.Key
        $pattern = $entry.Value
        $signalHits = 0

        foreach ($signal in $pattern.signals) {
            # Check if any inferred resource evidence mentions this signal
            $hit = $InferredResources | Where-Object {
                $_.evidence -join ' ' -match "(?i)$([regex]::Escape($signal))"
            }
            if ($hit) { $signalHits++ }
        }

        # Also check: do inferred resources overlap with what this pattern provisions?
        foreach ($res in $InferredResources) {
            foreach ($prov in $pattern.provisions) {
                if ($res.description -match "(?i)$([regex]::Escape($prov))") { $signalHits++ }
            }
        }

        if ($signalHits -ge $pattern.minSignals) {
            $patterns += [ordered]@{
                name = $patternName
                ref = $pattern.ref
                description = $pattern.description
                signalHits = $signalHits
                covers = $pattern.provisions
            }
        }
    }

    return $patterns
}

# ============================================================================
# BICEP GENERATION
# ============================================================================

function New-GeneratedBicep {
    param(
        [array]$InferredResources,
        [array]$PatternModules,
        [string]$OutputDir,
        [string]$LabCode
    )

    $infraDir = Join-Path $OutputDir "infra"
    $modulesDir = Join-Path $infraDir "modules"
    New-Item -Path $modulesDir -ItemType Directory -Force | Out-Null

    # Determine which resources are covered by pattern modules
    $coveredTypes = @()
    foreach ($pm in $PatternModules) {
        $coveredTypes += $pm.covers
    }

    # Also suppress cognitive-services when ai-foundry pattern is selected (it includes AI Services)
    $patternNames = @($PatternModules | ForEach-Object { $_.name })
    $suppressedTypes = @()
    if ($patternNames -contains 'ai-foundry') {
        $suppressedTypes += 'cognitive-services'
    }

    # Filter to resources NOT covered by patterns (to avoid duplication)
    $standaloneResources = $InferredResources | Where-Object {
        $dominated = $false
        # Check if suppressed explicitly
        if ($suppressedTypes -contains $_.type) { $dominated = $true }
        # Check if covered by pattern provisions
        foreach ($ct in $coveredTypes) {
            if ($_.description -match "(?i)$([regex]::Escape($ct))") { $dominated = $true; break }
        }
        -not $dominated
    }

    # --- Generate main.bicep ---
    $mainBicep = Get-Content (Join-Path $script:TemplatesDir "base-main.bicep") -Raw
    $mainBicep = $mainBicep -replace '\{\{LAB_CODE\}\}', $LabCode

    # Build module references
    $moduleRefs = ""

    # Pattern modules first
    foreach ($pm in $PatternModules) {
        $templateFile = Join-Path $script:TemplatesDir "avm-$($pm.name).bicep"
        if (Test-Path $templateFile) {
            $content = Get-Content $templateFile -Raw
            Copy-Item $templateFile (Join-Path $modulesDir "$($pm.name).bicep") -Force
            $moduleRefs += @"

// Pattern: $($pm.description)
module $($pm.name -replace '-','') './modules/$($pm.name).bicep' = {
  scope: rg
  name: '$($pm.name)-deploy'
  params: {
    location: location
    environmentName: environmentName
    principalId: principalId
  }
}
"@
        }
    }

    # Standalone resource modules
    foreach ($res in $standaloneResources) {
        if ($res.confidence -eq 'low') { continue } # Skip low-confidence
        $templateFile = Join-Path $script:TemplatesDir "avm-$($res.type).bicep"
        if (Test-Path $templateFile) {
            Copy-Item $templateFile (Join-Path $modulesDir "$($res.type).bicep") -Force
            $safeName = $res.type -replace '-',''
            $moduleRefs += @"

// Resource: $($res.description)
module $safeName './modules/$($res.type).bicep' = {
  scope: rg
  name: '$($res.type)-deploy'
  params: {
    location: location
    environmentName: environmentName
  }
}
"@
        }
    }

    # Insert module references into main.bicep
    $mainBicep = $mainBicep -replace '// \{\{MODULE_REFERENCES\}\}', $moduleRefs.TrimStart()
    Set-Content (Join-Path $infraDir "main.bicep") -Value $mainBicep -Encoding UTF8

    # --- Generate main.parameters.json ---
    $params = Get-Content (Join-Path $script:TemplatesDir "base-main.parameters.json") -Raw
    Set-Content (Join-Path $infraDir "main.parameters.json") -Value $params -Encoding UTF8

    return $infraDir
}

function New-GeneratedAzureYaml {
    param(
        [string]$OutputDir,
        [string]$LabCode,
        [array]$PatternModules
    )

    $usesHostedAgents = ($PatternModules | Where-Object { $_.name -eq 'ai-foundry' }) -ne $null

    $yaml = @"
# yaml-language-server: `$schema=https://raw.githubusercontent.com/Azure/azure-dev/main/schemas/v1.0/azure.yaml.json

name: $($LabCode.ToLower())-lab
metadata:
  template: lab-lifecycle-skill@generate
infra:
  provider: bicep
  path: ./infra
"@

    if ($usesHostedAgents) {
        $yaml += @"

# Note: If this lab uses Foundry Hosted Agents, uncomment and configure:
# services:
#   agent:
#     project: src/<agent-folder>
#     host: azure.ai.agent
#     language: docker
"@
    }

    Set-Content (Join-Path $OutputDir "azure.yaml") -Value $yaml -Encoding UTF8
}

# ============================================================================
# VALIDATION
# ============================================================================

function Test-GeneratedBicep {
    param([string]$InfraDir)

    $mainBicep = Join-Path $InfraDir "main.bicep"
    if (-not (Test-Path $mainBicep)) { return @{ valid = $false; error = "main.bicep not found" } }

    try {
        $output = & az bicep build --file $mainBicep 2>&1
        if ($LASTEXITCODE -eq 0) {
            # Clean up compiled ARM
            $armFile = $mainBicep -replace '\.bicep$', '.json'
            if (Test-Path $armFile) { Remove-Item $armFile -Force }
            return @{ valid = $true; error = $null }
        } else {
            return @{ valid = $false; error = ($output -join "`n") }
        }
    } catch {
        return @{ valid = $false; error = $_.Exception.Message }
    }
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

function Invoke-Generate {
    param(
        [Parameter(Mandatory)][string]$RepoUrl,
        [string]$OutputDir,
        [switch]$Force
    )

    $labCode = if ($RepoUrl -match 'LAB(\d+)') { "LAB$($Matches[1])" } else { "UNKNOWN" }

    Write-Host "`n🔧 Generate IaC for: $labCode`n" -ForegroundColor Cyan

    # Step 1: Use shared local clone
    $tempDir = Get-LocalRepo $RepoUrl

    # Step 2: Check if IaC already exists
    $existingAzureYaml = Get-ChildItem $tempDir -Filter "azure.yaml" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    $existingInfra = Test-Path (Join-Path $tempDir "infra")
    $existingTerraform = Get-ChildItem $tempDir -Recurse -Filter "*.tf" -File -ErrorAction SilentlyContinue | Select-Object -First 1

    if (($existingAzureYaml -or $existingTerraform) -and -not $Force) {
        $existingType = if ($existingAzureYaml) { "azure.yaml at: $($existingAzureYaml.FullName)" } else { "Terraform at: $($existingTerraform.DirectoryName)" }
        Write-Host "  ⚠️  IaC already exists: $existingType" -ForegroundColor Yellow
        Write-Host "     Use -Force to regenerate. Skipping generation." -ForegroundColor Yellow
        return @{
            status = 'skipped'
            reason = 'IaC already exists'
            existing_iac = $existingType
        } | ConvertTo-Json -Depth 3
    }

    # Step 3: Infer resources
    Write-Host "  🔍 Inferring required Azure resources..."
    $inferred = Get-InferredResources -RepoPath $tempDir

    if (@($inferred).Count -eq 0) {
        Write-Host "  ❌ No Azure resources detected in lab content." -ForegroundColor Red
        return @{
            status = 'failed'
            reason = 'No resources inferred from lab content'
        } | ConvertTo-Json -Depth 3
    }

    Write-Host "  📋 Detected $(@($inferred).Count) resource type(s):" -ForegroundColor Green
    foreach ($r in $inferred) {
        $icon = switch ($r.confidence) { 'high' { '🟢' } 'medium' { '🟡' } 'low' { '⚪' } }
        Write-Host "     $icon $($r.type) ($($r.confidence) confidence, $($r.matchCount) signals)"
    }

    # Step 4: Map to AVM pattern modules
    Write-Host "`n  🧩 Mapping to AVM modules..."
    $patterns = Get-PatternModuleMatches -InferredResources $inferred

    if (@($patterns).Count -gt 0) {
        Write-Host "  📦 Pattern modules selected:" -ForegroundColor Green
        foreach ($p in $patterns) {
            Write-Host "     ✓ $($p.name): $($p.description)"
            Write-Host "       Covers: $($p.covers -join ', ')"
        }
    }

    # Step 5: Generate Bicep
    $targetDir = if ($OutputDir) { $OutputDir } else { $tempDir }
    Write-Host "`n  📝 Generating Bicep infrastructure..."
    $infraDir = New-GeneratedBicep -InferredResources $inferred -PatternModules $patterns -OutputDir $targetDir -LabCode $labCode

    # Step 6: Generate azure.yaml
    New-GeneratedAzureYaml -OutputDir $targetDir -LabCode $labCode -PatternModules $patterns

    # Step 7: Validate
    Write-Host "  ✅ Validating generated Bicep..."
    $validation = Test-GeneratedBicep -InfraDir $infraDir

    if ($validation.valid) {
        Write-Host "  ✓ Bicep compiles successfully!" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  Bicep validation warning: $($validation.error)" -ForegroundColor Yellow
    }

    # Build result manifest
    $generatedFiles = Get-ChildItem $targetDir -Recurse -File |
        Where-Object { $_.FullName -match '(infra[\\/]|azure\.yaml)' } |
        ForEach-Object { $_.FullName.Substring($targetDir.Length + 1) }

    $result = [ordered]@{
        status = 'generated'
        lab_code = $labCode
        output_dir = $targetDir
        bicep_valid = $validation.valid
        validation_error = $validation.error
        generated_files = @($generatedFiles)
        resource_manifest = @($inferred)
        pattern_modules = @($patterns)
        standalone_resources = @($inferred | Where-Object { $_.confidence -ne 'low' })
        next_steps = @(
            "Review generated files in: $targetDir"
            "Run: cd $targetDir && azd init -e <env-name>"
            "Run: azd up"
        )
    }

    Write-Host "`n  🎉 Generation complete!" -ForegroundColor Green
    Write-Host "     Output: $targetDir"
    Write-Host "     Files: $(@($generatedFiles).Count) generated"
    Write-Host ""

    # Don't clean up — leave files for deploy action
    return $result | ConvertTo-Json -Depth 5
}
