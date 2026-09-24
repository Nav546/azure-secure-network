# Azure secure network with private endpoint

Infrastructure as code (Bicep) and CI/CD (GitHub Actions) that deploys a storage account which **cannot be reached from the public internet**. The only path in is a private endpoint inside a locked-down virtual network.

## What gets deployed

| Resource | Purpose |
|---|---|
| Virtual network `10.0.0.0/16` | Private network boundary |
| `snet-app` `10.0.1.0/24` + NSG | Test VM with no public IP; internet inbound denied |
| `snet-endpoints` `10.0.2.0/24` + NSG | Private endpoint; only the app subnet may connect, HTTPS only |
| Storage account | Public network access disabled, shared keys disabled, TLS 1.2 minimum |
| Private endpoint + private DNS zone | Storage resolves to `10.0.2.x` inside the VNet |

## How the pipeline works

- **Pull request:** lints the Bicep and runs `what-if` to preview changes. Nothing is deployed.
- **Merge to main:** deploys, then runs two automated tests:
  1. From the GitHub runner (public internet): storage resolves to a public address and access is refused.
  2. From the VM inside the VNet: storage resolves to the private endpoint (`10.0.2.x`).

Azure login uses OIDC federated credentials, so no Azure passwords or keys are stored in GitHub. The pipeline identity has Contributor on one resource group only.

## Security decisions

- Public network access disabled on storage, so leaked keys alone are not enough.
- Shared key access disabled, forcing Entra ID authentication.
- NSGs on both subnets, with network policies enabled on the endpoint subnet so its NSG is enforced.
- Test VM has no public IP and is managed through `az vm run-command`, not SSH over the internet.

## Setup

1. Run `setup.sh` in Azure Cloud Shell (edit `GITHUB_REPO` first).
2. Add the four printed values as repository secrets.
3. Push to `main`.

## Clean up

```bash
az group delete -n rg-secure-net --yes --no-wait
```
