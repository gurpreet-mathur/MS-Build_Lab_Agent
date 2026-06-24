# Teams/Email Share Templates

## Short Version (Teams message)

---

🧪 **Lab Lifecycle Agent Skill** — Deploy Build/Ignite labs in one command

**Repo:** https://github.com/msbl26/lab-lifecycle-skill

**Quick start:**
```
git clone https://github.com/msbl26/lab-lifecycle-skill.git
cd lab-lifecycle-skill
.\core\lab-manager.ps1 -Action doctor
.\core\lab-manager.ps1 -Action deploy -RepoUrl "<any Build26-LABxxx repo URL>"
```

**What it does:**
- 🔍 `analyze` — inspect any lab's requirements
- 🔧 `generate` — auto-create IaC for labs without infra (uses Azure Verified Modules)
- 🚀 `deploy` — one-command deploy with self-healing (auto-fixes region issues)
- 📋 `outline` — step-by-step guided walkthrough
- 🗑️ `destroy` — clean up when done

**Works with:** Copilot CLI (auto-detected) | VS Code MCP | Direct PowerShell

**Prerequisites:** Azure CLI, azd, Git, PowerShell 7+
**Optional:** Copilot CLI + Build26 plugin (`/plugin install microsoft/Build-CLI`)

📖 Full guide: See `ONBOARDING.md` in the repo

---

## Longer Version (Email)

---

**Subject:** 🧪 New Agent Skill: Lab Lifecycle Manager — Deploy any Build/Ignite lab in one command

Hi team,

I've built a reusable agent skill that automates deploying Microsoft Build and Ignite hands-on labs. Instead of manually following setup instructions, you can now deploy any lab with a single command — and the skill self-heals common issues like region restrictions.

**Key capabilities:**
- **9 actions:** doctor, analyze, generate, prepare, outline, deploy, destroy, list, status
- **Self-mitigation:** Auto-detects region conflicts and retries with the correct region
- **IaC generation:** For labs without infrastructure code, auto-generates Bicep using Azure Verified Modules
- **Guided walkthroughs:** Breaks labs into modules with verification gates between steps
- **Multi-interface:** Works as Copilot CLI skill, MCP server (VS Code), or standalone PowerShell

**Tested on:** LAB511 (HorizonDB), LAB513 (SQL + Foundry), LAB510 (AKS), LAB520 (Foundry Models), LAB540 (Hosted Agents)

**Get started (2 minutes):**
1. Clone: `git clone https://github.com/msbl26/lab-lifecycle-skill.git`
2. Validate: `.\core\lab-manager.ps1 -Action doctor`
3. Deploy: `.\core\lab-manager.ps1 -Action deploy -RepoUrl "<lab-url>"`

Full onboarding guide is in `ONBOARDING.md` in the repo.

Let me know if you have questions or want a quick demo!

Best,
Gurpreet Mathur
CSA

---
