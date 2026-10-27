# 0013. Proteção contra deleção/rebuild nos recursos críticos

- **Status:** Aceito
- **Commits:** `3bde92d`

## Contexto

Um `terraform apply` com um `-replace` errado, uma mudança que força recriação ou um clique no console poderia
apagar os masters (e o etcd com eles), o IP da VPN (quebrando todas as configurações de cliente) ou a rede.

## Decisão

Com `protect = true` (padrão), a Hetzner aplica `delete_protection` (e `rebuild_protection` nos masters) em:

- masters (etcd)
- IP primário do gateway
- rede privada

Gateway e workers ficam **sem** proteção, porque foram feitos para ser substituídos.

## Alternativas consideradas

- **`lifecycle { prevent_destroy = true }`:** só protege contra o Terraform. Não cobre console e API, e não pode
  ser desligado por variável.
- **Sem proteção, confiando em revisão de plan:** depende de atenção humana em todos os applies.

## Consequências

- A API recusa a deleção até no console.
- O plan **ainda mostra** o destroy, mas é o apply que falha. Para substituir de propósito: `protect = false`,
  apply, mudança, e `protect = true` de volta (ver [operations.md](../operations.md#proteção-contra-deleção)).
- Destruir o ambiente exige um apply com `protect=false` antes.
