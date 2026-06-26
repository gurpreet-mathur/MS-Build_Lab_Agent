# 🧪 Lab Lifecycle Agent Skill — Quick Start Guide

> Deploy, manage, and destroy Microsoft Build & Ignite labs with one command.

## 🚀 Getting Started (2 minutes)

### Prerequisites

| Tool | Install |
|------|---------|
| PowerShell 7+ | `winget install Microsoft.PowerShell` |
| Azure CLI | `winget install Microsoft.AzureCLI` |
| Azure Developer CLI (azd) | `winget install Microsoft.Azd` |
| azd AI Agents extension | `azd extension install azure.ai.agents` |
| Git | `winget install Git.Git` |
| Node.js 18+ | `winget install OpenJS.NodeJS.LTS` |

### Setup

```powershell
# 1. Clone the skill
git clone https://github.com/msbl26/lab-lifecycle-skill.git
cd lab-lifecycle-skill

# 2. Validate your environment
.\scripts\lab-manager.ps1 -Action doctor

# 3. You're ready! Deploy any lab:
.\scripts\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps.git"
```

---

## 📋 Available Actions

| Action | What It Does | Example |
|--------|--------------|---------|
| `doctor` | Validates prerequisites | `.\scripts\lab-manager.ps1 -Action doctor` |
| `analyze` | Inspects a lab repo | `.\scripts\lab-manager.ps1 -Action analyze -RepoUrl <url>` |
| `generate` | Auto-creates IaC for labs missing infra | `.\scripts\lab-manager.ps1 -Action generate -RepoUrl <url>` |
| `prepare` | Checks deployment readiness | `.\scripts\lab-manager.ps1 -Action prepare -RepoUrl <url>` |
| `outline` | Breaks lab into step-by-step modules | `.\scripts\lab-manager.ps1 -Action outline -RepoUrl <url>` |
| `deploy` | Full end-to-end deployment | `.\scripts\lab-manager.ps1 -Action deploy -RepoUrl <url>` |
| `destroy` | Tears down all resources | `.\scripts\lab-manager.ps1 -Action destroy -RepoUrl <url>` |
| `list` | Shows all tracked deployments | `.\scripts\lab-manager.ps1 -Action list` |
| `status` | Checks a deployed lab's health | `.\scripts\lab-manager.ps1 -Action status -RepoUrl <url>` |

---

## 🤖 Using with Copilot CLI

### Install the Build26 Plugin (recommended)

The **microsoft-events** plugin gives Copilot CLI awareness of Build/Ignite sessions, schedules, and lab metadata. Install it once:

```
# In Copilot CLI:
/plugin install microsoft/Build-CLI
```

Or step-by-step:
1. Open Copilot CLI (`copilot` in terminal)
2. Type `/plugin`
3. Select "Install a plugin"
4. Enter: `microsoft/Build-CLI`
5. Confirm

### Using the Lab Lifecycle Skill

If you're inside the `lab-lifecycle-skill/` directory with Copilot CLI active, just ask in natural language:

- *"Deploy LAB520 for my demo"*
- *"What's the status of my labs?"*
- *"Generate infrastructure for LAB513"*
- *"Walk me through LAB511 step by step"*
- *"Destroy LAB540 when I'm done"*

The skill auto-activates via `SKILL.md` — no configuration needed.

---

## 🔌 Using as MCP Server (VS Code / Multi-Agent)

Add to your `.vscode/mcp.json`:

```json
{
  "servers": {
    "lab-lifecycle": {
      "command": "node",
      "args": ["<full-path-to>/lab-lifecycle-skill/mcp-server/src/index.js"],
      "transport": "stdio"
    }
  }
}
```

This exposes 7 MCP tools: `doctor_check`, `analyze_lab`, `generate_lab`, `prepare_lab`, `deploy_lab`, `destroy_lab`, `outline_lab`.

---

## 🧠 Smart Features

### Self-Mitigation
The skill auto-recovers from common deployment failures:
- ⚠️ Region not available → detects alternate region → retries automatically
- ⚠️ Name conflict (soft-deleted resource) → purges and retries
- ⚠️ Missing IaC → runs `generate` to create Bicep from lab content

### AVM-Powered Generation
For labs without infrastructure code, the `generate` action:
1. Scans markdown, requirements.txt, Dockerfile, .env files
2. Infers required Azure resources with confidence scoring
3. Maps to Azure Verified Modules (enterprise-grade Bicep)
4. Generates deployment-ready `infra/` + `azure.yaml`
5. Validates Bicep compiles cleanly

---

## 🏷️ Tested Labs

| Code | Lab | Status |
|------|-----|--------|
| LAB511 | Postgres-powered Agentic Apps (HorizonDB) | ✅ Full lifecycle + self-heal |
| LAB513 | AI App with Azure SQL + Fabric + Foundry | ✅ Generate created IaC |
| LAB510 | LLMs from Prototype to Production on AKS | ✅ Terraform detection + AKS inference |
| LAB520 | Get Started with Models in Foundry | ✅ Deploy (~3 min) |
| LAB540 | Observe & Protect Hosted Agents | ✅ Analyze + outline |

---

## ⚙️ Team Configuration (Optional)

Edit `team-config.yaml` to set shared defaults:

```yaml
defaults:
  subscription: "your-subscription-id"
  location: "eastus2"

labs:
  LAB520:
    env_overrides:
      ENABLE_CAPABILITY_HOST: "true"
      ENABLE_HOSTED_AGENTS: "true"
```

---

## 💰 Cost & Cleanup

- Most labs cost **$0.50–$1.20/hour** while running
- **Always run `destroy` when done** to avoid ongoing charges
- All resources are tagged with `azd-env-name` for easy identification

```powershell
# Clean up when done
.\scripts\lab-manager.ps1 -Action destroy -RepoUrl <url>
```

---

## 🆘 Troubleshooting

| Issue | Fix |
|-------|-----|
| `doctor` fails on Azure login | Run `az login` first |
| Deploy fails (region) | Skill auto-retries; or set `-Location swedencentral` |
| Deploy fails (policy) | Check with your admin; try a different subscription |
| `generate` skips | Lab already has IaC; use `-Force` to regenerate |

---

## 📬 Contact

**Skill Owner:** Gurpreet Mathur (SE)  
**Repo:** https://github.com/msbl26/lab-lifecycle-skill  
**Registry:** https://glowing-adventure-mvqrg5p.pages.github.io/registry/index.html

