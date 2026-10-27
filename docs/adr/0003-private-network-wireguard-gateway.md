# 0003. Nós só na rede privada, gateway WireGuard como único host público

- **Status:** Aceito
- **Commits:** `f756b5f`, `9f45b9f`, `d3ef7f5`, `21ef6a0`

## Contexto

Masters e workers expostos à internet ampliam muito a superfície de ataque (SSH, API do Kubernetes, kubelet,
NodePorts). A Hetzner **não permite** firewall em servidores sem interface pública (`PrivateNetOnlyServer`) e
não oferece NAT gateway gerenciado. Mesmo assim, nós privados precisam de egress (download do RKE2, imagens) e
o operador precisa de acesso administrativo.

## Decisão

- Nenhum nó do cluster tem IPv4/IPv6 público. Todos ficam na rede `10.0.0.0/16`.
- Um único servidor, o **gateway**, tem IP público (IP primário reservado, que sobrevive a rebuilds) e faz três
  coisas:
  1. **WireGuard** (`udp/51820`, a única regra do firewall) para acesso administrativo.
  2. **NAT** com nftables para o egress dos nós. A rota de rede `0.0.0.0/0 → 10.0.1.2` leva o tráfego até ele.
  3. Endpoint do control plane com HAProxy ([0004](0004-haproxy-control-plane-endpoint.md)).
- A rota `10.200.0.0/24 → gateway` devolve o tráfego aos clientes VPN sem NAT, então os nós veem o IP real do
  cliente.
- `private-network.sh` grava a default route via netplan antes de qualquer download.

## Alternativas consideradas

- **IPs públicos + firewall Hetzner:** simples, mas expõe todos os nós e custa um IPv4 por servidor.
- **Bastion SSH:** não resolve o egress nem dá acesso à API do Kubernetes sem túneis manuais.
- **Tailscale/Headscale:** boa experiência, mas depende de um control plane externo (ou de mais um serviço para
  hospedar). O WireGuard puro é declarativo e as chaves são geradas no Terraform.
- **OpenVPN/IPsec:** mais pesados, com mais portas e mais superfície.

## Consequências

- Os nós são inalcançáveis da internet. O isolamento vem da ausência de interface pública.
- Economia de IPv4 público por nó.
- O gateway vira ponto único de falha para VPN, egress e joins. Nós já no cluster seguem funcionando.
- `terraform/cluster` e qualquer `kubectl` exigem a VPN ativa.
- Chaves WireGuard ficam no state (tratar o state como segredo).
