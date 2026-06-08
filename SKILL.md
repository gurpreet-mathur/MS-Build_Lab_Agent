# Lab Lifecycle Skill

> Deploy, manage, and destroy Microsoft Build labs with one command.

## When to activate

Activate when the user:
- Wants to deploy, destroy, or manage a Build lab
- Asks about lab status or deployment history
- Mentions "lab lifecycle", "deploy lab", "destroy lab", "lab status"
- References a lab code (LAB520, LAB540, etc.)
- Asks to check prerequisites or validate their environment

## Available actions

| Action | Description |
|--------|-------------|
| `doctor` | Validate all prerequisites for a team member |
| `analyze` | Inspect a lab repo and report requirements |
| `prepare` | Check deployment readiness and provide guided remediation |
| `deploy` | Clone, configure, provision, and deploy a lab |
| `destroy` | Tear down all lab resources (requires confirmation) |
| `list` | Show all tracked lab deployments |
| `status` | Check current status of a deployed lab |

## Usage

```powershell
# Check prerequisites
.\core\lab-manager.ps1 -Action doctor

# Analyze a lab before deploying
.\core\lab-manager.ps1 -Action analyze -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Check readiness and get remediation guidance
.\core\lab-manager.ps1 -Action prepare -RepoUrl "https://github.com/microsoft/Build26-LAB501-..."

# Deploy a lab
.\core\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Check status
.\core\lab-manager.ps1 -Action status -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Destroy when done
.\core\lab-manager.ps1 -Action destroy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."
```

## Supported labs

| Code | Title | Deploy Time | Status |
|------|-------|-------------|--------|
| LAB520 | Get Started with Models in Foundry | ~3 min | ✅ Tested |
| LAB540 | Observe & Protect Hosted Agents | ~10 min | ✅ Tested |
| LAB511 | Postgres-powered Agentic Apps | ~5 min | ⚠️ Untested |
| LAB532 | Agent-ready Knowledge with Foundry IQ | ~5 min | ⚠️ Untested |

## Safety rules

1. **Never destroy without confirmation** — destroy always requires explicit user approval
2. **Never store credentials** — uses Azure CLI auth, no secrets in config
3. **Tag all resources** — every deployment is tagged for cost tracking
4. **Registry tracks state** — prevents orphaned resources
