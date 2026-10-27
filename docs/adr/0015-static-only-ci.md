# 0015. CI apenas estático; applies locais pela VPN

- **Status:** Aceito
- **Commits:** `fa4c83a`, `20c91bc`, `ea39a46`

## Contexto

O root `cluster` só funciona com a VPN. O state contém todos os segredos. Dar ao CI um peer WireGuard, o token
R2 e o token da Hetzner ampliaria muito o impacto de um comprometimento do GitHub ou de uma action.

## Decisão

`.github/workflows/terraform.yml` roda em PRs e na `main` com `permissions: contents: read`:

- `terraform fmt -check` e `validate` nos dois roots (`init -backend=false -lockfile=readonly`)
- `tflint` (`.tflint.hcl`: preset recomendado + documentação/nomenclatura)
- `trivy config` (HIGH/CRITICAL)
- `helm lint --strict` nos charts locais
- `shellcheck` nos scripts

As versões das ferramentas ficam fixadas em `env:` e as actions por SHA de commit. Os lock files trazem hashes
para darwin/linux amd64+arm64. **O CI nunca faz plan nem apply contra a infraestrutura real.** Os applies rodam
localmente, pela VPN, a partir de um plan revisado.

## Alternativas consideradas

- **Plan/apply no CI (Atlantis, HCP Terraform, Actions com segredos):** dá auditoria e automação, mas exige VPN e
  segredos no CI.
- **Sem CI:** erros de formatação, de lock file ou de configuração insegura só apareceriam no apply.

## Consequências

- O CI não guarda segredos e não pode alterar a infraestrutura.
- Não existe plan automático no PR: quem aplica precisa rodar e revisar o plan localmente.
- Lock file incompleto ou versão de ferramenta divergente quebram o CI de forma explícita.
