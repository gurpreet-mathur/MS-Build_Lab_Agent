<#
.SYNOPSIS
    Lab Registry Builder — harvest Microsoft event labs, probe each repo, and
    classify how well the Lab Lifecycle agent supports it.

.DESCRIPTION
    Dot-sourced by lab-manager.ps1 (the `registry` action) and also runnable
    standalone. Three stages:

      1. HARVEST  — discover labs from sources/event-sources.json
                    (Build = local markdown catalog with direct URLs;
                     Ignite / AI Tour = event next-steps README with aka.ms
                     shortlinks that are resolved to canonical repo URLs).
      2. PROBE    — for each lab repo, inspect structure via the GitHub git-tree
                    + languages + metadata APIs (NO cloning, low cost) and scan
                    the README for Azure services.
      3. CLASSIFY — compute a support_status per lab and merge any real
                    deploy-validation evidence from the deployment registry.

    Output: registry/labs-registry.json (machine) + references/lab-support-matrix.md
    (human). Static build performs NO Azure deployment and costs nothing.

.NOTES
    Security: every repo slug is validated against SAFE_SLUG before it is passed
    to `gh api`, so harvested/redirected values cannot inject shell/args
    (OWASP A03). Network failures degrade to support_status = "unknown".
#>

Set-StrictMode -Version Latest

# Slug guard — owner/name only. Anything else is rejected before reaching gh.
$script:SAFE_SLUG = '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'

# Owner guard — a single org/user segment (for github_search sources).
$script:SAFE_OWNER = '^[A-Za-z0-9._-]+$'

# GitHub orgs that count as first-party Microsoft (high source confidence).
$script:OFFICIAL_ORG = '^(microsoft|Azure|Azure-Samples|MicrosoftLearning|dotnet|microsoftgraph|OfficeDev)/'

# Azure / Microsoft services we recognize from README text → services_used.
$script:ServiceSignatures = [ordered]@{
    'Azure OpenAI'             = 'azure openai|aoai'
    'Microsoft Foundry'        = 'microsoft foundry|azure ai foundry|ai foundry|foundry project'
    'Azure AI Services'        = 'azure ai services|cognitive services'
    'Azure AI Search'          = 'azure ai search|azure cognitive search|ai search'
    'Azure Cosmos DB'          = 'cosmos db|cosmosdb'
    'Azure SQL'                = 'azure sql|sql hyperscale|sql database'
    'Azure PostgreSQL'         = 'postgres|postgresql|horizondb'
    'Azure Kubernetes Service' = '\baks\b|kubernetes service'
    'Azure Container Apps'     = 'container apps|aca\b'
    'Azure Container Registry' = 'container registry|\bacr\b'
    'Azure Functions'         = 'azure functions|function app'
    'Azure Storage'            = 'azure storage|blob storage|storage account'
    'Azure Key Vault'          = 'key vault|keyvault'
    'Azure App Service'        = 'app service'
    'Azure API Management'     = 'api management|\bapim\b'
    'Application Insights'     = 'application insights|app insights|azure monitor'
    'Microsoft Fabric'         = 'microsoft fabric|onelake|rayfin'
    'Agent Framework'          = 'agent framework'
    'Model Context Protocol'   = 'model context protocol|\bmcp\b'
}

function Test-SafeSlug([string]$slug) {
    return ($slug -and $slug -match $script:SAFE_SLUG)
}

function Resolve-ShortLink([string]$url) {
    # Follow redirects (aka.ms → github.com). Returns final absolute URL, or the
    # original on failure. Used for Ignite / AI Tour repo shortlinks.
    if (-not $url) { return $null }
    if ($url -notmatch 'aka\.ms') { return $url }
    try {
        $resp = Invoke-WebRequest -Uri $url -MaximumRedirection 10 -Method Head `
            -SkipHttpErrorCheck -TimeoutSec 20 -ErrorAction Stop
        $final = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
        if ($final) { return $final }
    } catch {
        Write-Host "    ! shortlink resolve failed: $url ($($_.Exception.Message))"
    }
    return $url
}

function Get-RepoSlug([string]$url) {
    if (-not $url) { return $null }
    if ($url -match 'github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$') {
        return "$($Matches[1])/$($Matches[2])"
    }
    return $null
}

# ----------------------------------------------------------------------------
# HARVEST
# ----------------------------------------------------------------------------

function Get-LabsFromMarkdownCatalog($evt, $repoRoot) {
    # Parse a local catalog with direct repo URLs already resolved.
    # Table rows look like: | LAB500 | Title | [Repo](https://github.com/...) | ... | ... |
    $path = Join-Path $repoRoot $evt.harvest.path
    $labs = @()
    if (-not (Test-Path $path)) {
        Write-Host "  ! catalog not found: $path"
        return $labs
    }
    $pattern = "^\|\s*($($evt.harvest.session_code_pattern))\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|"
    foreach ($line in (Get-Content $path)) {
        if ($line -match $pattern) {
            $code = $Matches[1].Trim()
            $title = $Matches[2].Trim()
            $repoCell = $Matches[3].Trim()
            $repoUrl = $null
            if ($repoCell -match '\((https://github\.com/[^)]+)\)') { $repoUrl = $Matches[1] }
            $labs += [ordered]@{
                session_code = $code
                title        = $title
                source_url   = $repoUrl
                presenters   = @()
            }
        }
    }
    return $labs
}

function Get-LabsFromGitHubReadme($evt) {
    # Fetch the event next-steps README via gh api and extract lab links.
    # Rows / bullets look like: [LAB514 - Title](https://aka.ms/ignite25-LAB514GHRepo)
    $repo = $evt.harvest.repo
    $labs = @()
    if (-not (Test-SafeSlug $repo)) {
        Write-Host "  ! unsafe source repo slug: $repo"
        return $labs
    }
    try {
        $b64 = (gh api "repos/$repo/readme" --jq .content 2>$null) -join ''
        $md = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($b64))
    } catch {
        Write-Host "  ! failed to fetch README for $repo ($($_.Exception.Message))"
        return $labs
    }
    $linkPattern = "\[\s*($($evt.harvest.session_code_pattern))\s*[-–]\s*(.+?)\]\((https?://[^)]+)\)"
    $seen = @{}
    foreach ($m in [regex]::Matches($md, $linkPattern)) {
        $code = $m.Groups[1].Value.Trim()
        if ($seen.ContainsKey($code)) { continue }
        $seen[$code] = $true
        $labs += [ordered]@{
            session_code = $code
            title        = $m.Groups[2].Value.Trim()
            source_url   = $m.Groups[3].Value.Trim()
            presenters   = @()
        }
    }
    return $labs
}

function Test-SafeOwner([string]$owner) {
    return ($owner -and $owner -match $script:SAFE_OWNER)
}

function Get-LabsFromGitHubSearch($evt) {
    # Discover repos via `gh search repos` across declared org queries. Used for
    # the Microsoft Learn / workshops source that has no event next-steps page.
    # Each query is { owner, q }; results are deduped, archived/test repos are
    # filtered, sorted by recency, and capped at max_results.
    $h = $evt.harvest
    $limit          = if ($h.PSObject.Properties.Name -contains 'limit') { [int]$h.limit } else { 40 }
    $maxResults     = if ($h.PSObject.Properties.Name -contains 'max_results') { [int]$h.max_results } else { 0 }
    $includeArchived = ($h.PSObject.Properties.Name -contains 'include_archived' -and $h.include_archived)
    $skipPattern    = if ($h.PSObject.Properties.Name -contains 'skip_name_pattern') { $h.skip_name_pattern } else { $null }

    $seen = @{}
    $collected = @()
    foreach ($query in $h.queries) {
        $owner = $query.owner
        $q = $query.q
        if (-not (Test-SafeOwner $owner)) { Write-Host "  ! unsafe owner skipped: $owner"; continue }
        $json = $null
        try {
            $json = gh search repos $q --owner $owner --limit $limit --json 'fullName,description,url,isArchived,updatedAt' 2>$null
        } catch {
            Write-Host "  ! search failed ($owner :: $q): $($_.Exception.Message)"; continue
        }
        if (-not $json) { continue }
        $rows = $json | ConvertFrom-Json
        foreach ($r in $rows) {
            $full = $r.fullName
            if (-not $full -or $seen.ContainsKey($full)) { continue }
            if (-not $includeArchived -and $r.isArchived) { continue }
            $short = ($full -split '/')[-1]
            if ($skipPattern -and $short -match $skipPattern) { continue }
            $seen[$full] = $true
            $collected += $r
        }
    }

    # Most recently updated first, then apply the cap.
    $collected = @($collected | Sort-Object { [datetime]$_.updatedAt } -Descending)
    if ($maxResults -gt 0 -and $collected.Count -gt $maxResults) {
        $collected = $collected[0..($maxResults - 1)]
    }

    # Explicit curated repos ("owner/name") are always included, bypassing the
    # recency cap, for catalog entries whose names don't match the search terms.
    if ($h.PSObject.Properties.Name -contains 'repos') {
        foreach ($full in $h.repos) {
            if (-not $full -or $seen.ContainsKey($full)) { continue }
            $owner = ($full -split '/')[0]
            if (-not (Test-SafeOwner $owner)) { Write-Host "  ! unsafe owner skipped: $owner"; continue }
            $meta = $null
            try {
                $meta = gh api "repos/$full" --jq '{fullName:.full_name,description:.description,url:.html_url,isArchived:.archived,updatedAt:.updated_at}' 2>$null
            } catch {
                Write-Host "  ! repo fetch failed ($full): $($_.Exception.Message)"; continue
            }
            if (-not $meta -or $meta -match '"message"' -or $meta -match '"status"') { continue }
            $r = $meta | ConvertFrom-Json
            if (-not $r.fullName) { continue }
            if (-not $includeArchived -and $r.isArchived) { continue }
            $seen[$r.fullName] = $true
            $collected += $r
        }
    }

    $labs = @()
    foreach ($r in $collected) {
        $short = ($r.fullName -split '/')[-1]
        $title = if ($r.description) { $r.description.Trim() } else { $short }
        $labs += [ordered]@{
            session_code = $short
            title        = $title
            source_url   = $r.url
            presenters   = @()
        }
    }
    return $labs
}

# ----------------------------------------------------------------------------
# PROBE
# ----------------------------------------------------------------------------

function New-Probe {
    # Fully-shaped default probe so every consumer can read all fields safely
    # (Set-StrictMode-friendly), whether or not a repo was actually probed.
    return [ordered]@{
        ok                 = $false
        has_azure_yaml     = $false
        azure_yaml_path    = $null
        has_infra          = $false
        has_bicep          = $false
        has_terraform      = $false
        has_dockerfile     = $false
        has_devcontainer   = $false
        has_codespaces     = $false
        languages          = @()
        path_count         = 0
        default_branch     = $null
        latest_release_tag = $null
        archived           = $false
        readme             = ''
    }
}

function Get-RepoProbe([string]$slug) {
    # Inspect a repo's structure via GitHub APIs — no clone. Returns a probe
    # hashtable plus README text (for service scanning). On any failure, ok=$false.
    $probe = New-Probe
    if (-not (Test-SafeSlug $slug)) { return $probe }

    # Metadata
    try {
        $meta = gh api "repos/$slug" 2>$null | ConvertFrom-Json
        if ($meta) {
            $probe.default_branch = $meta.default_branch
            $probe.archived       = [bool]$meta.archived
        }
    } catch { return $probe }

    # File tree (recursive, single call)
    try {
        $paths = gh api "repos/$slug/git/trees/$($probe.default_branch)?recursive=1" --jq '.tree[].path' 2>$null
    } catch { $paths = $null }
    if (-not $paths) { return $probe }

    $probe.ok = $true
    $probe.path_count = @($paths).Count
    foreach ($p in $paths) {
        if ($p -match '(^|/)azure\.ya?ml$') {
            $probe.has_azure_yaml = $true
            if (-not $probe.azure_yaml_path -or ($p.Split('/').Count -lt $probe.azure_yaml_path.Split('/').Count)) {
                $probe.azure_yaml_path = $p
            }
        }
        if ($p -match '(^|/)infra/')        { $probe.has_infra = $true }
        if ($p -match '\.bicep$')           { $probe.has_bicep = $true }
        if ($p -match '\.tf$')              { $probe.has_terraform = $true }
        if ($p -match '(^|/)Dockerfile')    { $probe.has_dockerfile = $true }
        if ($p -match '\.devcontainer')     { $probe.has_devcontainer = $true; $probe.has_codespaces = $true }
    }

    # Languages
    try {
        $langs = gh api "repos/$slug/languages" --jq 'keys[]' 2>$null
        if ($langs) { $probe.languages = @($langs) }
    } catch {}

    # Latest release tag (informational; some labs gate event content behind a tag)
    try {
        $rel = (gh api "repos/$slug/releases/latest" --jq '.tag_name' 2>$null) -join ''
        # Guard against gh emitting a 404 error body (e.g. {"message":"Not Found",...}) to stdout
        if ($rel -and $rel -ne 'null' -and $rel -notmatch '"message"' -and $rel -notmatch '"status"') {
            $probe.latest_release_tag = $rel.Trim()
        }
    } catch {}

    # README (for service scanning)
    try {
        $rb64 = (gh api "repos/$slug/readme" --jq .content 2>$null) -join ''
        if ($rb64) { $probe.readme = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rb64)) }
    } catch {}

    return $probe
}

function Get-ServicesFromText([string]$text) {
    $found = @()
    if (-not $text) { return $found }
    $lower = $text.ToLowerInvariant()
    foreach ($svc in $script:ServiceSignatures.Keys) {
        if ($lower -match $script:ServiceSignatures[$svc]) { $found += $svc }
    }
    return $found
}

# ----------------------------------------------------------------------------
# CLASSIFY
# ----------------------------------------------------------------------------

function Get-SupportClassification($probe, $services, $hasRepo, $validated) {
    $reason = @()
    # App-code languages that imply a deployable app (vs docs-only repos).
    $appLangs = @('Python','TypeScript','JavaScript','C#','Java','Go','Bicep','HCL','Rust','C++')
    $hasAppCode = $false
    if ($probe.ok) {
        $hasAppCode = (@($probe.languages | Where-Object { $appLangs -contains $_ }).Count -gt 0)
    }

    if ($validated) {
        $reason += "deploy-validated (status=$($validated.status))"
        $status = if ($validated.status -eq 'passed') { 'supported' }
                  elseif ($validated.status -eq 'partial') { 'partial' }
                  elseif ($validated.status -eq 'failed') { 'unsupported' }
                  else { 'likely_supported' }
        $path = if ($probe.has_azure_yaml) { 'azd' } elseif ($probe.has_terraform) { 'terraform' } else { 'unknown' }
        return @{ support_status = $status; deploy_path = $path; support_reason = $reason }
    }

    if (-not $hasRepo) {
        return @{ support_status = 'unsupported'; deploy_path = 'none'
                  support_reason = @('no public GitHub repo published (partner/3rd-party or unreleased)') }
    }
    if (-not $probe.ok) {
        return @{ support_status = 'unknown'; deploy_path = 'unknown'
                  support_reason = @('repo could not be probed (private, 404, or API error)') }
    }
    if ($probe.archived) { $reason += 'repo archived' }

    if ($probe.has_azure_yaml) {
        $reason += "azure.yaml present ($($probe.azure_yaml_path)) → azd up path"
        if ($probe.has_infra)      { $reason += 'infra/ present' }
        if ($probe.has_dockerfile) { $reason += 'Dockerfile (container build)' }
        return @{ support_status = 'likely_supported'; deploy_path = 'azd'; support_reason = $reason }
    }
    if ($probe.has_terraform) {
        $reason += 'Terraform IaC (not azd) — manual / non-azd deploy'
        return @{ support_status = 'partial'; deploy_path = 'terraform'; support_reason = $reason }
    }
    if ($hasAppCode -and @($services).Count -gt 0) {
        $reason += "app code ($($probe.languages -join ', ')) + Azure services, no azure.yaml → agent can generate IaC (AVM)"
        return @{ support_status = 'needs_iac_generation'; deploy_path = 'needs_iac_generation'; support_reason = $reason }
    }
    $reason += "docs-only repo (no azure.yaml / infra / app code; path_count=$($probe.path_count))"
    return @{ support_status = 'docs_only'; deploy_path = 'docs_only'; support_reason = $reason }
}

# ----------------------------------------------------------------------------
# VALIDATION MERGE (from deployment registry.json)
# ----------------------------------------------------------------------------

function Get-ValidationMap($registryStatePath) {
    # Map repo_url → validation evidence from prior deploy/destroy runs.
    $map = @{}
    if (-not $registryStatePath -or -not (Test-Path $registryStatePath)) { return $map }
    try {
        $state = Get-Content $registryStatePath -Raw | ConvertFrom-Json
        foreach ($d in @($state.deployments)) {
            if (-not $d.repo_url) { continue }
            $st = switch ($d.status) {
                'deployed'    { 'passed' }
                'provisioned' { 'partial' }
                'failed'      { 'failed' }
                default       { 'not_tested' }
            }
            $map[$d.repo_url] = @{
                status             = $st
                last_run_utc       = $d.deployed_at
                last_tested_commit = $null
                evidence           = "deployment registry: $($d.status)"
            }
        }
    } catch {}
    return $map
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------

function Build-LabRegistry {
    param(
        [string]$SourcesPath,
        [string]$OutputJson,
        [string]$OutputMarkdown,
        [string]$RegistryStatePath,
        [string]$EventFilter,
        [int]$MaxLabs = 0
    )

    $repoRoot = Split-Path $PSScriptRoot -Parent
    if (-not $SourcesPath)       { $SourcesPath = Join-Path $repoRoot 'sources/event-sources.json' }
    if (-not $OutputJson)        { $OutputJson = Join-Path $repoRoot 'registry/labs-registry.json' }
    if (-not $OutputMarkdown)    { $OutputMarkdown = Join-Path $repoRoot 'references/lab-support-matrix.md' }
    if (-not $RegistryStatePath) { $RegistryStatePath = Join-Path $env:USERPROFILE '.lab-lifecycle/registry.json' }

    # Decode gh's UTF-8 stdout correctly so non-ASCII repo descriptions (Korean,
    # French, emoji, …) are not mangled into mojibake in harvested titles.
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

    Write-Host "`n📚 Building Lab Registry`n" -ForegroundColor Cyan

    $sources = Get-Content $SourcesPath -Raw | ConvertFrom-Json
    $validationMap = Get-ValidationMap $RegistryStatePath
    $entries = @()
    # Track repo slugs already added so a repo discovered by a later source
    # (e.g. github_search) does not duplicate an event lab.
    $seenSlugs = @{}

    foreach ($evt in $sources.events) {
        if ($EventFilter -and $evt.event_family -ne $EventFilter) { continue }
        Write-Host "── $($evt.event) ($($evt.event_family)) ──" -ForegroundColor White

        $rawLabs = switch ($evt.harvest.type) {
            'markdown_catalog' { Get-LabsFromMarkdownCatalog $evt $repoRoot }
            'github_search'    { Get-LabsFromGitHubSearch $evt }
            default            { Get-LabsFromGitHubReadme $evt }
        }
        Write-Host "  discovered $($rawLabs.Count) lab(s)"

        $count = 0
        foreach ($lab in $rawLabs) {
            if ($MaxLabs -gt 0 -and $count -ge $MaxLabs) { break }
            $count++

            $repoUrl = Resolve-ShortLink $lab.source_url
            if ($repoUrl -and $repoUrl -notmatch 'github\.com') { $repoUrl = $null }
            $slug = Get-RepoSlug $repoUrl
            $hasRepo = [bool]$slug

            if ($slug) {
                if ($seenSlugs.ContainsKey($slug)) {
                    Write-Host ("  • {0,-9} {1} (dup, skip)" -f $lab.session_code, $slug)
                    continue
                }
                $seenSlugs[$slug] = $true
            }

            Write-Host ("  • {0,-9} {1}" -f $lab.session_code, ($slug ?? 'no repo'))

            $probe = if ($hasRepo) { Get-RepoProbe $slug } else { New-Probe }
            $services = if ($hasRepo -and $probe.ok) { Get-ServicesFromText $probe.readme } else { @() }
            $validated = if ($repoUrl -and $validationMap.ContainsKey($repoUrl)) { $validationMap[$repoUrl] } else { $null }
            $cls = Get-SupportClassification $probe $services $hasRepo $validated

            $codePrefix = ($lab.session_code -replace '\d+$','')
            $sessionType = 'unknown'
            if ($evt.harvest.PSObject.Properties.Name -contains 'session_type_map' -and
                $evt.harvest.session_type_map.PSObject.Properties.Name -contains $codePrefix) {
                $sessionType = $evt.harvest.session_type_map.$codePrefix
            } elseif ($lab.session_code -match '^LABSP') { $sessionType = 'lab' }
              elseif ($lab.session_code -match '^LAB')   { $sessionType = 'lab' }
              elseif ($lab.session_code -match '^WRK')   { $sessionType = 'workshop' }
            if ($sessionType -eq 'unknown' -and
                $evt.harvest.PSObject.Properties.Name -contains 'default_session_type') {
                $sessionType = $evt.harvest.default_session_type
            }

            $srcType = $evt.harvest.source_type
            if ($hasRepo -and $slug -notmatch $script:OFFICIAL_ORG) { $srcType = 'partner_or_external' }
            elseif (-not $hasRepo) { $srcType = 'partner_or_external' }

            $entry = [ordered]@{
                lab_id        = "$($evt.event_slug)-$($lab.session_code)"
                event         = $evt.event
                event_family  = $evt.event_family
                year          = $evt.year
                session_code  = $lab.session_code
                session_type  = $sessionType
                title         = $lab.title
                summary       = if ($probe.ok -and $probe.readme) { $null } else { $null }
                presenters    = $lab.presenters
                source_url    = $lab.source_url
                repo_url      = $repoUrl
                repo_slug     = $slug
                event_hub_url = $evt.event_hub_url
                source_type   = $srcType
                repo_structure = [ordered]@{
                    has_azure_yaml     = [bool]$probe.has_azure_yaml
                    azure_yaml_path    = $probe.azure_yaml_path
                    has_infra          = [bool]$probe.has_infra
                    has_bicep          = [bool]$probe.has_bicep
                    has_terraform      = [bool]$probe.has_terraform
                    has_dockerfile     = [bool]$probe.has_dockerfile
                    has_devcontainer   = [bool]$probe.has_devcontainer
                    has_codespaces     = [bool]$probe.has_codespaces
                    languages          = @($probe.languages)
                    path_count         = [int]$probe.path_count
                    default_branch     = $probe.default_branch
                    latest_release_tag = $probe.latest_release_tag
                    archived           = [bool]$probe.archived
                }
                services_used   = @($services)
                deploy_path     = $cls.deploy_path
                support_status  = $cls.support_status
                support_reason  = @($cls.support_reason)
                validation      = [ordered]@{
                    status             = if ($validated) { $validated.status } else { 'not_tested' }
                    last_run_utc       = if ($validated) { $validated.last_run_utc } else { $null }
                    last_tested_commit = $null
                    evidence           = if ($validated) { $validated.evidence } else { $null }
                }
                source_confidence   = if ($srcType -eq 'partner_or_external') { 'low' }
                                      elseif ($evt.harvest.type -eq 'markdown_catalog') { 'high' } else { 'high' }
                last_discovered_utc = (Get-Date).ToUniversalTime().ToString('o')
            }
            $entries += $entry
        }
    }

    # Summary roll-ups
    $byEvent = @{}; $byStatus = @{}
    foreach ($e in $entries) {
        $byEvent[$e.event_family] = ($byEvent[$e.event_family] ?? 0) + 1
        $byStatus[$e.support_status] = ($byStatus[$e.support_status] ?? 0) + 1
    }

    $registry = [ordered]@{
        schema_version = '1.0.0'
        generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
        generator      = 'registry-builder.ps1 v1.0.0'
        summary        = [ordered]@{
            total             = $entries.Count
            by_event          = $byEvent
            by_support_status = $byStatus
        }
        labs = $entries
    }

    $outDir = Split-Path $OutputJson
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $registry | ConvertTo-Json -Depth 8 | Set-Content $OutputJson -Encoding utf8

    Write-LabSupportMatrix -Registry $registry -Path $OutputMarkdown

    Write-Host "`n✅ Registry built: $($entries.Count) labs" -ForegroundColor Green
    Write-Host "   JSON:     $OutputJson"
    Write-Host "   Markdown: $OutputMarkdown"
    Write-Host "   Status:   $(( $byStatus.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')"
    return $OutputJson
}

function Write-LabSupportMatrix {
    param($Registry, [string]$Path)

    $emoji = @{
        supported            = '✅'
        likely_supported     = '🟢'
        needs_iac_generation = '🛠️'
        partial              = '🟡'
        docs_only            = '📄'
        unsupported          = '❌'
        unknown              = '❔'
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Lab Support Matrix')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("> Which Microsoft event labs the **Lab Lifecycle agent** supports. Auto-generated by ``registry-builder.ps1`` — do not edit by hand.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("**Generated:** $($Registry.generated_utc) &nbsp;|&nbsp; **Total labs:** $($Registry.summary.total)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Legend')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Status | Meaning |')
    [void]$sb.AppendLine('|--------|---------|')
    [void]$sb.AppendLine('| ✅ supported | Deploy-validated by the agent (real `azd up` succeeded) |')
    [void]$sb.AppendLine('| 🟢 likely_supported | Has `azure.yaml` → standard `azd` path, not yet deploy-tested |')
    [void]$sb.AppendLine('| 🛠️ needs_iac_generation | Azure app code but no `azure.yaml` — agent can generate IaC (AVM) |')
    [void]$sb.AppendLine('| 🟡 partial | Terraform-only or manual/external steps required |')
    [void]$sb.AppendLine('| 📄 docs_only | Published repo is docs-only (no deployable artifacts) |')
    [void]$sb.AppendLine('| ❌ unsupported | No public repo / no Azure deploy path |')
    [void]$sb.AppendLine('| ❔ unknown | Repo could not be probed |')
    [void]$sb.AppendLine('')

    # Render preferred event families first, then any additional ones (e.g. the
    # Microsoft Learn / workshops source) in discovery order.
    $preferred = @('Build', 'Ignite', 'AI Tour')
    $allFamilies = @($Registry.labs | ForEach-Object { $_.event_family } | Select-Object -Unique)
    $orderedFamilies = @($preferred | Where-Object { $allFamilies -contains $_ }) +
                       @($allFamilies | Where-Object { $preferred -notcontains $_ })

    foreach ($fam in $orderedFamilies) {
        $labs = @($Registry.labs | Where-Object { $_.event_family -eq $fam })
        if ($labs.Count -eq 0) { continue }
        $evtName = $labs[0].event
        [void]$sb.AppendLine("## $evtName")
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| Status | Lab | Title | Deploy path | Services | Repo |')
        [void]$sb.AppendLine('|--------|-----|-------|-------------|----------|------|')
        foreach ($l in ($labs | Sort-Object session_code)) {
            $ico = $emoji[$l.support_status]
            $repo = if ($l.repo_url) { "[repo]($($l.repo_url))" } else { '—' }
            $svcs = if (@($l.services_used).Count -gt 0) { (@($l.services_used) | Select-Object -First 4) -join ', ' } else { '—' }
            $title = $l.title -replace '\|','\|'
            [void]$sb.AppendLine("| $ico ``$($l.support_status)`` | $($l.session_code) | $title | ``$($l.deploy_path)`` | $svcs | $repo |")
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('---')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_“supported” means the agent has actually deployed it; all other states are static-analysis classifications and may deploy successfully once validated._')

    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $sb.ToString() | Set-Content $Path -Encoding utf8
}
