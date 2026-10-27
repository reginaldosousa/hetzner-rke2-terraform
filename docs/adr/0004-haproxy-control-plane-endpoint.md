# 0004. HAProxy no gateway como endpoint do control plane

- **Status:** Aceito. Substitui a decisão original de um Load Balancer privado (`fd20f6b`).
- **Commits:** `fd20f6b` (LB original), `c7bab57`

## Contexto

O RKE2 precisa de um endpoint estável para `:6443` (API) e `:9345` (join). A primeira versão usava um Hetzner
LB `lb11` só na rede privada (US$ 7,89/mês). Porém:

- O endpoint só é usado por `kubectl` (pela VPN) e por nós **entrando** no cluster. Agentes RKE2 já registrados
  balanceiam sozinhos entre os masters.
- O join já depende do gateway (egress para baixar o RKE2), então o gateway já era crítico nesse caminho.

## Decisão

O HAProxy roda no gateway, escutando **apenas no IP privado** `10.0.1.2` nas portas 6443 e 9345 em modo TCP,
com health check dos três masters. O backend é gerado de `local.master_ips`. `control_plane_ip` é o IP do
gateway, que também entra no `tls-san` dos masters. Timeouts de 1h mantêm `kubectl logs -f`/`watch`/`exec`.

## Alternativas consideradas

- **Manter o LB privado `lb11`:** gerenciado e com SLA, mas um custo fixo sem ganho real de disponibilidade.
- **DNS round-robin para os masters:** não tem health check e deixa clientes com cache apontando para um master
  morto.
- **kube-vip / VIP:** a rede da Hetzner não permite VIP flutuante sem alias IP gerenciado pela API, o que seria
  mais complexo.
- **Apontar para o master-1 diretamente:** sem HA no join e no kubectl.

## Consequências

- US$ 7,89/mês a menos ([custos](../costs.md)) e um recurso a menos para gerenciar.
- Nenhum ponto único de falha novo, porque o gateway já era necessário para joins.
- O `haproxy.cfg` é um arquivo mutável do gateway: mudanças nos masters chegam via
  [sync in-place](0009-gateway-config-sync.md).
- `net.ipv4.ip_nonlocal_bind=1` é necessário, já que o IP privado pode chegar por DHCP depois do HAProxy subir.

## Atualizações
- **2026-10-27:** O health check deixou de ser só TCP: `option httpchk` com TLS, esperando 200/401 de `/readyz` na
  6443 (o anonymous auth está desligado) e 200 de `/ping` na 9345. Um master com a porta aberta mas o servidor
  travado sai da rotação.
