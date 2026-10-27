# 0007. State remoto no Cloudflare R2 com `use_lockfile`

- **Status:** Aceito
- **Commits:** `04881d6`, `110765f`

## Contexto

O state começou local, o que significa uma cópia só, sem lock, presa a uma máquina e, no caso do `cluster`, lida
por caminho de arquivo. Ele contém todos os segredos do projeto. A Hetzner Object Storage era uma opção, mas o
DNS já está na Cloudflare.

## Decisão

Os dois roots usam o backend `s3` apontando para o bucket R2 `rke2-tfstate` (`infra/terraform.tfstate`,
`cluster/terraform.tfstate`):

- Lock nativo com `use_lockfile = true`. O R2 avalia `If-None-Match` de forma atômica, então dois applies não
  pegam o lock ao mesmo tempo. Isso exige Terraform ≥ 1.10.
- As credenciais vêm do perfil AWS `r2`, nunca do código. O token R2 tem escopo de Object Read & Write **somente
  nesse bucket**.
- Flags `skip_*` e `use_path_style` desligam as verificações exclusivas da AWS.
- Como o **R2 não tem versionamento de objetos**, `scripts/backup-state.sh` guarda as 30 últimas cópias de cada
  state em `state-backups/` (git-ignored, permissão 0600) e deve rodar após cada apply.

## Alternativas consideradas

- **AWS S3 + DynamoDB:** tem versionamento, mas é mais uma conta e mais um provedor, com custo e IAM a gerenciar.
- **Hetzner Object Storage:** fica no mesmo provedor do cluster, o que é pior para recuperação de desastre, e o
  suporte a lock condicional não foi validado.
- **HCP Terraform:** tem lock, versionamento e UI, mas runs remotos não alcançam a VPN, e o state com segredos
  ficaria num SaaS a mais.
- **State local:** sem lock, sem compartilhamento, com risco de perda.

## Consequências

- Lock confiável e state acessível de qualquer máquina com o perfil `r2`.
- O state fica criptografado em repouso pela Cloudflare, mas **não** do lado do cliente: quem tem o token R2 lê
  todos os segredos.
- O backup é manual. Se ninguém rodar o script depois do apply, um state sobrescrito não tem como voltar.
- O endpoint do R2 (ID da conta) aparece em `backend.tf` e em `terraform/cluster/main.tf`.

## Atualizações
- **2026-10-27:** `scripts/backup-state.sh` também envia cada cópia para `rke2-tfstate/backups/<root>/`, com a
  mesma retenção, para que um state sobrescrito seja recuperável sem o laptop do operador.
