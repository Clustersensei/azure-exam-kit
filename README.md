# Azure Exam Kit — Employee/Todo Platform

Three apps behind one public ingress IP on a **private** AKS cluster, with the backend
on ACI reachable only from the cluster subnet, data in a VNet-integrated Postgres, and
everything deployed by Terraform + Azure Pipelines + Flux.

## What's here

| Path | What it is |
|---|---|
| [`exam-kit/`](exam-kit/) | **Start here.** Runbook + scripts that generate all the code from one vars file |
| [`reference-build/`](reference-build/) | The verbatim code from a build that was verified working end to end |
| [`COMMANDS.md`](COMMANDS.md) | Running log of every command, with the gotcha each phase exposed |

## Two ways to use this

**Generator (recommended).** Edit `exam-kit/vars.env`, run `02-generate.sh`, and it
emits every Terraform module, pipeline and manifest with your names substituted in.
Re-run it as you discover values. Follow [`exam-kit/RUNBOOK.md`](exam-kit/RUNBOOK.md).

**Reference build.** Copy `reference-build/` and hand-edit the names. Slower and more
error-prone, but it is the exact code that ran. See
[`reference-build/README.md`](reference-build/README.md) for the list of things you
must change — and the two bugs it contains that the generator fixes.

## Architecture in one picture

```
                    internet
                       │
                  20.x.x.x  (Azure LB, public)
                       │
        ┌──────────────┼───────────────────────────────┐
        │  VNet 10.0.0.0/16                            │
        │              │                               │
        │   ┌──────────▼──────────┐                    │
        │   │ nginx ingress       │  snet-aks-node     │
        │   │ /emp  /to-do        │  10.0.1.0/24       │
        │   └───┬─────────┬───────┘                    │
        │       │         │                            │
        │  ┌────▼───┐ ┌───▼────┐                       │
        │  │frontend│ │  todo  │   (AKS, private API)  │
        │  └────────┘ └────────┘                       │
        │       │                                      │
        │       │ /emp/api  →  selector-less Service    │
        │       │              + manual Endpoints       │
        │       ▼                                      │
        │  ┌─────────────┐  snet-aci 10.0.3.0/24       │
        │  │ ACI backend │  NSG: only from 10.0.1.0/24 │
        │  └──────┬──────┘                             │
        │         │                                    │
        │  ┌──────▼───────┐  snet-postgres 10.0.4.0/24 │
        │  │  Postgres    │  delegated, no public access│
        │  └──────────────┘                            │
        │                                              │
        │  jump host (no public IP, NAT gw for egress) │
        │  = self-hosted ADO agent, only box that can  │
        │    reach the private AKS API server          │
        └──────────────────────────────────────────────┘
```

## The five things that cost the most time

1. **LB health probe on a 404 path.** nginx serves `/healthz` on port 10254, not 80.
   A failing probe drops *all* traffic while a direct NodePort curl still returns 200.
2. **NSG port 80.** AKS sets `EnableFloatingIP=True`, so the LB does not rewrite the
   destination port — real traffic arrives on 80, probes on the NodePort.
3. **`DBUSER` vs `DBUSERNAME`.** Postgres `28P01` means "auth failed", which covers an
   empty *username* too. Read the code that consumes your env vars.
4. **3 public IPs per region** on a trial subscription; AKS takes one invisibly.
5. **Node-pool tags.** Cluster `tags` never reach the auto-created `MC_*` VMSS.
