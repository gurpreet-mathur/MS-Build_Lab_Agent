# Generated IaC (DRAFT — not deploy-validated)

> ⚠️ **DRAFT.** These Bicep/`azure.yaml` files were **auto-generated** by the
> `lab-lifecycle-skill` AVM composer (`scripts/avm-composer.ps1`) from
> README/code signals in each upstream accelerator. Resources are **inferred**,
> not authored by the accelerator owners. Each set compiles (`az bicep build`
> succeeds) but has **not** been deploy-validated against Azure. Treat as a
> starting point: review, complete parameters/wiring, and test before any real
> deployment.

## Provenance

- **Tool:** `scripts/avm-composer.ps1` (Azure Verified Modules-based generator)
- **Source classification:** `support_status = needs_iac_generation` accelerators
  (Azure app code present, but no `azure.yaml` upstream).
- **Validation performed:** `az bicep build` → compiles clean (`bicep_valid: true`).
- **Validation NOT performed:** `azd up` / live deploy (deferred — pending new tenant).

## Artifacts

| Accelerator (microsoft/*) | Inferred resources | bicep_valid |
|---------------------------|--------------------|:-----------:|
| Purview-ADB-Lineage-Solution-Accelerator | ai-foundry; event-hub, storage-account | ✅ |
| Azure-Synapse-Retail-Recommender-Solution-Accelerator | ai-foundry, aks-cluster, container-registry; event-hub, storage-account | ✅ |
| Azure-PDF-Form-Processing-Automation-Solution-Accelerator | ai-foundry; storage-account, cosmos-db | ✅ |
| Azure-Non-Fungible-Token-Solution-Accelerator | aks-cluster, container-registry, key-vault | ✅ |
| Azure-Synapse-Customer-Insights-Customer360-Solution-Accelerator | storage-account | ✅ |

Each folder contains:

```
azure.yaml
infra/
  main.bicep
  main.parameters.json
  modules/*.bicep
```

## Regenerate

```powershell
pwsh -File ./scripts/lab-manager.ps1 -Action generate -RepoUrl <accelerator-repo-url> -Force
```

The clone lands under `labs/` (gitignored); copy the generated `azure.yaml` +
`infra/` here to persist.
