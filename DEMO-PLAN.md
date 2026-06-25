# Lab Lifecycle Agent Skill — Demo Plan

## Demo Context (from testing session 2026-06-25/26)

### Proven Results

| Lab | Action | Result | Time |
|-----|--------|--------|------|
| LAB540 | deploy (swedencentral) | ✅ Full lifecycle | 7m 57s deploy, 3m 10s destroy |
| LAB520 | deploy (swedencentral) | ✅ Infra OK (agent timeout) | ~5 min infra |
| LAB511 | deploy (self-heal) | ✅ Region auto-retry worked | 15m 20s |
| LAB510 | generate + deploy (westus2) | ✅ AKS + ACR from AVM | 7m 2s |
| LAB530 | analyze + generate | ✅ AI Foundry inferred | 12.5s |
| LAB501 | deploy | ❌ Container App timeout | Skip |
| LAB532 | deploy | ❌ Post-provision hook fail | Skip |

### Recommended Demo Lab: LAB540 (Observe & Protect Hosted Agents)
- **Repo**: https://github.com/microsoft/Build26-LAB540-observe-optimize-and-protect-your-hosted-agents-in-microsoft-foundry.git
- **Region**: swedencentral
- **Deploy time**: ~8 min
- **Destroy time**: ~3 min
- **Reliability**: 100% (2/2 clean runs)

### Demo Flow (5 minutes with pre-deploy)

#### PRE-DEMO (run 10 min before):
```powershell
.\scripts\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB540-observe-optimize-and-protect-your-hosted-agents-in-microsoft-foundry.git" -Location swedencentral
```

#### LIVE DEMO:

**Beat 1: Doctor (17s)**
```powershell
.\scripts\lab-manager.ps1 -Action doctor
```
Talk track: "One command validates everything — Azure CLI, azd, RBAC, Node.js, all 10 prereqs."

**Beat 2: Analyze LAB530 cold (2s)**
```powershell
.\scripts\lab-manager.ps1 -Action analyze -RepoUrl "https://github.com/microsoft/Build26-LAB530-engineering-agents-that-reason-act-and-adapt.git"
```
Talk track: "Never seen this lab before. Inspects it cold — no azure.yaml, no infra code. Most tools stop here."

**Beat 3: Generate IaC from docs (13s)**
```powershell
.\scripts\lab-manager.ps1 -Action generate -RepoUrl "https://github.com/microsoft/Build26-LAB530-engineering-agents-that-reason-act-and-adapt.git" -Force
```
Talk track: "Reads the lab docs, infers AI Foundry is needed, selects AVM pattern module, generates production Bicep, validates. Zero manual authoring."

**Beat 4: Status on pre-deployed LAB540 (3s)**
```powershell
.\scripts\lab-manager.ps1 -Action status -RepoUrl "https://github.com/microsoft/Build26-LAB540-observe-optimize-and-protect-your-hosted-agents-in-microsoft-foundry.git"
```
Talk track: "I deployed this 10 minutes ago with one command. Here it is running in Azure — AI Foundry, models, observability, all configured."

**(Optional) Show Azure Portal** — open https://portal.azure.com, show rg-lab540-XXXX with live resources.

**Beat 5: Destroy live (3 min)**
```powershell
.\scripts\lab-manager.ps1 -Action destroy -RepoUrl "https://github.com/microsoft/Build26-LAB540-observe-optimize-and-protect-your-hosted-agents-in-microsoft-foundry.git"
```
Type `yes` when prompted.
Talk track: "One command cleanup. No orphaned resources, no surprise bills. Full lifecycle control."

#### CLOSING (15s)
"9 actions. Any azd repo. Self-healing. AVM-powered generation. From zero to deployed in minutes, not hours."

---

### Timed Results from Dry Run

```
Beat 1: doctor             16.8s  ✅
Beat 2: analyze LAB530      1.8s  ✅
Beat 3: generate LAB530    12.5s  ✅
Beat 4: status (pre-deploy)  3s   ✅
Beat 5: destroy            3m 10s ✅
Total demo time:          ~4.5 min ✅
```

### Key Talking Points (Technical + Mid-Manager)

| Point | Message |
|-------|---------|
| Time savings | 2-3 hours → 15 minutes per lab setup |
| Self-service | No dependency on infra team or lab authors |
| Cost control | Tags everything, tracks all deployments, one-command cleanup |
| Self-healing | Auto-fixes region conflicts, retries without human help |
| AVM-powered | Generates infra from docs using Azure Verified Modules |
| Universal | Works for Build, Ignite, AI Tour, or any azd repo |

### Repo Structure (Agent Package format)
```
lab-lifecycle-skill/
├── SKILL.md              # Required – frontmatter + instructions
├── scripts/              # Executable code
│   ├── lab-manager.ps1   # Core engine (9 actions)
│   └── avm-composer.ps1  # AVM inference + Bicep generation
├── references/           # Documentation
│   ├── ONBOARDING.md
│   ├── build-2026-labs.md
│   └── share-templates.md
├── assets/               # Templates
│   └── templates/        # 11 Bicep templates (AVM modules)
└── mcp-server/           # Optional MCP integration
```

### 9 Available Actions
1. `doctor` — Validate prerequisites
2. `analyze` — Inspect any repo
3. `generate` — Auto-create IaC using AVM
4. `prepare` — Check deployment readiness
5. `outline` — Break lab into step-by-step modules
6. `deploy` — Full provision + deploy (with self-healing)
7. `destroy` — One-command teardown
8. `list` — Show all tracked deployments
9. `status` — Health check deployed lab

### Environment Info
- Windows, PowerShell 7.6.2, Azure CLI 2.77.0, azd 1.25.4
- Subscription: b5e02113-6104-40e0-a06b-a0ac0ffcc751 (gumathur-9)
- GitHub repos: msbl26/lab-lifecycle-skill (internal), gurpreet-mathur/MS-Build_Lab_Agent (public)
- Owner: Gurpreet Mathur (STU team)
