# Lab Lifecycle Skill

> Deploy, manage, and destroy Microsoft Build & Ignite labs with one command. Share with your team for repeatable demo environments.

> **Event-agnostic:** the engine auto-detects the event (Build26, Ignite, …) from each repo URL, so the same commands work for any event's labs without code changes.

## 🚀 Quick Start

```powershell
# 1. Clone this repo
git clone https://github.com/msbl26/lab-lifecycle-skill.git
cd lab-lifecycle-skill

# 2. Check your environment
.\core\lab-manager.ps1 -Action doctor

# 3. (Optional) Outline the lab into modules for a guided, verify-as-you-go demo
.\core\lab-manager.ps1 -Action outline -RepoUrl "https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps"

# 4. Deploy a lab (or run it module-by-module — see "Guided walkthrough" below)
.\core\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps"

# 4. Test it
# (The deploy output shows how to invoke the agent)

# 5. Destroy when done
.\core\lab-manager.ps1 -Action destroy -RepoUrl "https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps"
```

## 📋 Prerequisites

Run `.\core\lab-manager.ps1 -Action doctor` to validate. Requirements:

| Tool | Version | Install |
|------|---------|---------|
| Azure CLI (`az`) | 2.60+ | `winget install Microsoft.AzureCLI` |
| Azure Developer CLI (`azd`) | 1.25+ | `winget install Microsoft.Azd` |
| azd AI Agents extension | 0.1.30+ | `azd ext install azure.ai.agents` |
| PowerShell | 7.0+ | `winget install Microsoft.PowerShell` |
| Git | 2.40+ | `winget install Git.Git` |
| Node.js (for MCP server) | 18+ | `winget install OpenJS.NodeJS.LTS` |
| GitHub CLI (`gh`) | 2.40+ | `winget install GitHub.cli` |

### Azure Access

- Azure subscription with **Contributor** + **User Access Administrator** roles
- Logged in: `az login`
- Subscription set: `az account set -s <subscription-id>`

### Team Config (Optional)

Create `team-config.yaml` to share default settings:

```yaml
defaults:
  subscription_id: "0837f455-5e03-40aa-b602-9a4f8afc25a1"
  location: "eastus2"
  principal_type: "User"
  org: "msbl26"

labs:
  LAB520:
    repo: "https://github.com/microsoft/Build26-LAB520-get-started-with-models-in-microsoft-foundry-to-build-ai-apps"
    deploy_time: "3 min"
    env_overrides:
      ENABLE_CAPABILITY_HOST: "false"
  LAB540:
    repo: "https://github.com/microsoft/Build26-LAB540-observe-optimize-and-protect-your-hosted-agents-in-microsoft-foundry"
    deploy_time: "10 min"
    env_overrides:
      ENABLE_CAPABILITY_HOST: "true"
      ENABLE_HOSTED_AGENTS: "true"
```

## 🏗️ Architecture

```
lab-lifecycle-skill/
├── SKILL.md                  # Copilot CLI auto-detects this
├── README.md                 # This file
├── team-config.yaml          # Team defaults (customize per team)
├── core/
│   └── lab-manager.ps1       # Core engine (all actions)
├── mcp-server/
│   ├── package.json
│   └── src/index.js          # MCP Server (6 tools)
└── .vscode/
    └── mcp.json              # VS Code MCP integration
```

## 🔌 Integration Options

### Option 1: Copilot CLI (Recommended)

Clone this repo into your workspace. The `SKILL.md` is auto-detected by Copilot CLI. Just say:

> "Deploy LAB520 for my demo"

### Option 2: MCP Server (VS Code)

```bash
cd mcp-server && npm install
```

Add to your `.vscode/mcp.json`:
```json
{
  "servers": {
    "lab-lifecycle": {
      "type": "stdio",
      "command": "node",
      "args": ["<path-to>/lab-lifecycle-skill/mcp-server/src/index.js"]
    }
  }
}
```

### Option 3: Direct PowerShell

```powershell
.\core\lab-manager.ps1 -Action <action> -RepoUrl <url> [-EnvName <name>] [-Location <region>]
```

## 🧭 Guided Walkthrough (module-by-module)

Want to run a lab as a **live demo**, one chapter at a time, proving each step
works before moving on? Ask the agent:

> "Walk me through LAB540 module by module"

The skill will:

1. **Outline** the lab — parse its README/docs into ordered modules/chapters,
   extracting each module's commands and the **manual verification steps** a
   presenter must do by hand.
2. **Run one module at a time** — deploy/perform that module's work.
3. **Pause for verification** — present the manual checks (open the app, run the
   agent, confirm the expected output) and wait for your confirmation.
4. **Only advance once you confirm** the current module works. If something
   fails, it helps you troubleshoot before continuing.

You can also get the raw structure directly:

```powershell
.\core\lab-manager.ps1 -Action outline -RepoUrl "https://github.com/microsoft/Build26-LAB540-..."
```

## 📊 Supported Labs

### Microsoft Build 2026

| Code | Title | Time | Docker | Status |
|------|-------|------|--------|--------|
| LAB520 | Get Started with Models in Foundry | ~3 min | No | ✅ Tested |
| LAB540 | Observe & Protect Hosted Agents | ~10 min | Yes | ✅ Tested |
| LAB511 | Postgres Agentic Apps (HorizonDB) | ~5 min | TBD | ⚠️ Untested |
| LAB532 | Foundry IQ Knowledge | ~5 min | TBD | ⚠️ Untested |

### Microsoft Ignite

Ignite labs use the same lifecycle — pass the Ignite lab repo URL to any action.
The event is auto-detected from the URL, clones are kept in an event-prefixed
folder (e.g. `Ignite-LABxxx`) so they never collide with Build clones, and
Foundry hosted-agent capability is enabled automatically when needed. Add tested
Ignite labs to `team-config.yaml` to share them with your team.

## 🛡️ Troubleshooting

| Issue | Fix |
|-------|-----|
| `ImageError: too large for CPU tier` | Increase `cpu`/`memory` in `azure.yaml` (use 1 CPU / 2Gi for Docker agents) |
| `Project not found` (404 after purge) | Use fresh env name — don't reuse purged resource names |
| Agent timeout (creating > 7 min) | Normal for Docker agents on first deploy. Wait 3-5 min, then `azd deploy` again |
| SAML SSO error on git push | Run `gh auth refresh -h github.com -s admin:org` |
| `disableLocalAuth: true` warning | By design — Entra ID auth is more secure |

## 📝 Cost Estimate

| Lab | Resources | ~Cost/hour |
|-----|-----------|-----------|
| LAB520 | AI Services + Project | ~$0.50 |
| LAB540 | AI Services + ACR + Container + App Insights | ~$1.20 |

> 💡 Always run `destroy` after demos to avoid unnecessary charges.

## 🤝 Contributing

1. Test a new lab: `.\core\lab-manager.ps1 -Action analyze -RepoUrl <new-lab-url>`
2. If it works, add it to `team-config.yaml`
3. Submit a PR with your findings
