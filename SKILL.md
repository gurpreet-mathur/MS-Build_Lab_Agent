---
name: lab-lifecycle
description: Deploy, manage, and destroy Microsoft Build & Ignite hands-on lab environments on Azure with one command.
authors:
  - Gurpreet Mathur (STU)
version: 1.0.0
---

# Lab Lifecycle Skill

> Deploy, manage, and destroy Microsoft Build & Ignite labs with one command.

## When to activate

Activate when the user:
- Wants to deploy, destroy, or manage a Build or Ignite lab
- Asks about lab status or deployment history
- Mentions "lab lifecycle", "deploy lab", "destroy lab", "lab status"
- References a lab code (LAB520, LAB540, etc.)
- Asks to check prerequisites or validate their environment
- Wants to run a lab **module by module** / chapter by chapter, or to be
  walked through a lab step by step with verification between steps
- Mentions "guided walkthrough", "outline the lab", "go through the lab",
  "one module at a time", or "verify before continuing"

> The skill is **event-agnostic** — it auto-detects the event (Build26, Ignite, …)
> from each repo URL, so the same actions work for any event's labs.

## Available actions

| Action | Description |
|--------|-------------|
| `doctor` | Validate all prerequisites for a team member |
| `analyze` | Inspect a lab repo and report requirements |
| `outline` | Break the lab into ordered modules/chapters, each with its commands and manual verification steps |
| `prepare` | Check deployment readiness and provide guided remediation |
| `generate` | **NEW** Auto-generate IaC (Bicep + azure.yaml) for labs missing infrastructure code, using AVM modules |
| `deploy` | Clone, configure, provision, and deploy a lab |
| `destroy` | Tear down all lab resources (requires confirmation) |
| `list` | Show all tracked lab deployments |
| `status` | Check current status of a deployed lab |

## Usage

```powershell
# Check prerequisites
.\scripts\lab-manager.ps1 -Action doctor

# Analyze a lab before deploying
.\scripts\lab-manager.ps1 -Action analyze -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Break a lab into modules/chapters (with per-module commands + verification steps)
.\scripts\lab-manager.ps1 -Action outline -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Check readiness and get remediation guidance
.\scripts\lab-manager.ps1 -Action prepare -RepoUrl "https://github.com/microsoft/Build26-LAB501-..."

# Deploy a lab
.\scripts\lab-manager.ps1 -Action deploy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Check status
.\scripts\lab-manager.ps1 -Action status -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."

# Destroy when done
.\scripts\lab-manager.ps1 -Action destroy -RepoUrl "https://github.com/microsoft/Build26-LAB520-..."
```

## Supported labs

### Microsoft Build 2026

| Code | Title | Deploy Time | Status |
|------|-------|-------------|--------|
| LAB520 | Get Started with Models in Foundry | ~3 min | ✅ Tested |
| LAB540 | Observe & Protect Hosted Agents | ~10 min | ✅ Tested |
| LAB511 | Postgres-powered Agentic Apps | ~5 min | ⚠️ Untested |
| LAB532 | Agent-ready Knowledge with Foundry IQ | ~5 min | ⚠️ Untested |

### Microsoft Ignite

Ignite labs work the same way — just pass the Ignite lab's repo URL. Add tested
labs to `team-config.yaml` for the team. Any `*-LABnnn-*` repo is supported, and
hosted-agent capability is enabled automatically when the lab uses Foundry agents.

## Safety rules

1. **Never destroy without confirmation** — destroy always requires explicit user approval
2. **Never store credentials** — uses Azure CLI auth, no secrets in config
3. **Tag all resources** — every deployment is tagged for cost tracking
4. **Registry tracks state** — prevents orphaned resources

## Guided module-by-module walkthrough

Use this when the user wants to run a lab **as a guided demo**, performing one
module/chapter at a time and proving each works before moving on. The `outline`
action understands the lab's objective and returns its structure; **you (the
agent) drive the interactive loop and the verification gates** — `outline`,
`deploy`, etc. run non-interactively, so the pause-and-confirm step is yours.

### Protocol (follow in order)

1. **Outline the lab.** Run `outline` (or the `outline_lab` tool) for the repo.
   You get back an ordered `modules` array; each module has:
   - `title`, `index`, and `kind` (`deploy` / `configure` / `verify` / `cleanup` / `reading`)
   - `commands` — the runnable steps extracted from that module
   - `verification` — the **manual** steps a presenter must do by hand to show it works
2. **Present the plan.** Show the user the numbered module list and confirm they
   want to proceed module-by-module.
3. **For each module, in order:**
   1. State what the module does and which commands/resources it will run.
   2. Perform the module's work:
      - If `kind` is `deploy`, run `deploy` for the lab (infra is provisioned
        once via `azd`; do this on the first `deploy` module).
      - Otherwise run the module's `commands` (after summarizing them to the user).
   3. **Stop and gate on manual verification.** Present the module's
      `verification` checklist and ask the user to perform those manual steps
      (open the app/portal, run the agent, confirm the expected output, etc.).
      Use an interactive question to collect their confirmation.
   4. **Wait for explicit confirmation.** Do **not** start the next module until
      the user confirms the current one works.
      - If they confirm ✅ → advance to the next module.
      - If they report a problem ❌ → help troubleshoot (offer `prepare`, re-run
        the step, inspect logs) and stay on this module until it's resolved or
        the user chooses to skip.
4. **Finish.** After the last module, remind the user to run `destroy` when the
   demo is done to avoid charges.

### Rules for the walkthrough

- **One module at a time.** Never batch modules or auto-advance past a
  verification gate.
- **Always pause for manual verification** when a module has `verification`
  steps — these are the human checks that showcase the lab working.
- **Confirmation is explicit.** Treat silence or ambiguity as "not yet"; ask again.
- **Respect deploy semantics.** Most labs provision all infra with a single
  `azd up`/`deploy`. Map "deploy this module" to the appropriate `deploy` call
  rather than inventing per-module infra commands.
- **Keep destroy gated.** Never tear down mid-walkthrough without asking.

