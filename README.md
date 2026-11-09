# FCG Infra — Grupo 14

Repositório de orquestração da plataforma **FIAP Cloud Games (FCG)**. Centraliza o `docker-compose.yml` para execução local completa e todos os manifests Kubernetes para deploy em cluster. Não contém código de aplicação.

> **Tech Challenge Fase 4:** além do API Gateway (Kong), da função Serverless e da observabilidade da Fase 3, a plataforma roda em **Kubernetes gerenciado na AWS (EKS)** provisionado por **Terraform**, com imagens no **ECR**, **CI/CD no GitHub Actions** (build, testes, scan, push e rolling update), **persistência poliglota** (PostgreSQL, DynamoDB, Redis), **busca avançada com OpenSearch** e **segredos no AWS Secrets Manager**. Veja [Infraestrutura na AWS](#infraestrutura-na-aws-terraform), [Segredos](#segredos) e [CI/CD](#cicd).

---

## Sumário

- [Visão Geral](#visão-geral)
- [Segredos](#segredos) · [Infraestrutura na AWS (Terraform)](#infraestrutura-na-aws-terraform) · [CI/CD](#cicd)
- [Arquitetura e Fluxo de Eventos](#arquitetura-e-fluxo-de-eventos)
- [Pré-requisitos](#pré-requisitos)
- [Estrutura do Repositório](#estrutura-do-repositório)
- [Execução com Docker Compose](#execução-com-docker-compose)
- [Deploy no Kubernetes](#deploy-no-kubernetes)
- [Observabilidade](#observabilidade)
- [Persistência Poliglota](#persistência-poliglota)
- [Hierarquia de Configuração e Secrets](#hierarquia-de-configuração-e-secrets)
- [Variáveis de Ambiente](#variáveis-de-ambiente)
- [Endpoints (via Kong)](#endpoints-via-kong)
- [Troubleshooting](#troubleshooting)
- [Documentação Detalhada dos Serviços](#documentação-detalhada-dos-serviços)

---

## Visão Geral

A FCG é composta por microsserviços independentes por trás de um **API Gateway (Kong)**, comunicando-se de forma assíncrona via **RabbitMQ + MassTransit**, com uma função **Serverless (AWS Lambda)** substituindo o antigo worker de notificações. Cada serviço tem seu próprio repositório, banco de dados e ciclo de vida.

| Componente | Repositório | Tipo | Onde roda |
|---|---|---|---|
| Kong | `fcg-infra` (`k8s/kong/`) | API Gateway | Kubernetes local |
| UsersAPI | `fcg-users-api` | Web API | Kubernetes local |
| CatalogAPI | `fcg-catalog-api` | Web API | Kubernetes local |
| PaymentsAPI | `fcg-payments-api` | Worker Service | Kubernetes local |
| Notifications | `fcg-notifications-serverless` | Função Lambda | **AWS real** |
| ~~NotificationsAPI~~ | `fcg-notifications-api` | ~~Worker Service~~ | **Descomissionado na Fase 3** — substituído pela Lambda acima |

**Infraestrutura compartilhada (Kubernetes local):**

| Serviço | Porta | Finalidade |
|---|---|---|
| Kong | `8000` (proxy) / `8001` (admin) | Ponto de entrada único, validação de JWT, roteamento |
| PostgreSQL 16 | `5432` | Banco relacional (1 DB por serviço, 1 instância) |
| RabbitMQ 3 | `5672` / `15672` | Broker de mensagens entre os microsserviços |
| Redis 7 | `6379` | Cache distribuído (listagem de jogos do CatalogAPI) |
| Prometheus | `9090` | Coleta de métricas |
| Grafana | `3000` | Dashboards |

**Infraestrutura na AWS (região `us-east-1`), provisionada pelo `fcg-notifications-serverless`:**

| Recurso | Nome | Finalidade |
|---|---|---|
| SQS | `fcg-user-created` | Aciona a Lambda quando um usuário se cadastra |
| SQS | `fcg-payment-processed` | Aciona a Lambda quando um pagamento é processado |
| Lambda | `fcg-notifications-function` | Processa as notificações (antigo NotificationsAPI) |
| DynamoDB | `fcg-notification-logs` | Persiste o histórico de notificações enviadas |

---

## Arquitetura e Fluxo de Eventos

```
                              ┌──────────┐
  Cliente ──────────────────► │   KONG   │  :8000 (proxy) / :8001 (admin)
                              │ (JWT +   │
                              │ routing) │
                              └────┬─────┘
                                   │
                 ┌─────────────────┼──────────────────┐
                 ▼                                     ▼
         ┌──────────────┐                      ┌──────────────┐
         │  UsersAPI    │                      │  CatalogAPI  │◄──── Redis (cache de /games)
         │ /User /Auth  │                      │ /games       │
         └──────┬───────┘                      └──────┬───────┘
                │                                      │
        UserCreatedEvent                        OrderPlacedEvent
                │                                      │
                ├──────────────┐                       ▼
                │              │              ┌──────────────────┐
                ▼              │              │   PaymentsAPI    │ (Worker)
          ┌──────────┐         │              │ consome          │
          │ RabbitMQ │         │              │ OrderPlacedEvent │
          │ (dual-   │         │              └────────┬─────────┘
          │ publish) │         │                       │
          └──────────┘         │              PaymentProcessedEvent
                                │                       │
                                │         ┌──────────────┴──────────────┐
                                │         ▼                             ▼
                                │  RabbitMQ (CatalogAPI consome  RabbitMQ + SQS (dual-publish)
                                │  e libera o jogo na biblioteca)        │
                                ▼                                       ▼
                        SQS "fcg-user-created"          SQS "fcg-payment-processed"
                                │                                       │
                                └───────────────┬───────────────────────┘
                                                 ▼
                                    ┌─────────────────────────┐
                                    │   AWS Lambda            │
                                    │   fcg-notifications-     │
                                    │   function                │
                                    │   (fcg-notifications-     │
                                    │   serverless)              │
                                    └───────────┬──────────────┘
                                                │
                                  ┌─────────────┴─────────────┐
                                  ▼                           ▼
                          CloudWatch Logs           DynamoDB "fcg-notification-logs"
                          [EMAIL SIMULADO]

Observabilidade: UsersAPI e CatalogAPI expõem /metrics (Prometheus) e /health,
                 scraped por Prometheus, visualizados no Grafana (dashboard "FCG Overview").
```

### Fluxo 1 — Cadastro de Usuário

```
Cliente → POST /api/v1/User/register  (via Kong, rota pública)
    └─► UsersAPI cria usuário no banco
            ├─► publica UserCreatedEvent no RabbitMQ (histórico/outros consumers futuros)
            └─► dual-publish: envia o mesmo evento para a fila SQS "fcg-user-created"
                    └─► aciona a Lambda fcg-notifications-function
                            └─► [EMAIL SIMULADO] boas-vindas → CloudWatch Logs
                            └─► grava item em DynamoDB fcg-notification-logs (type: Welcome)
```

### Fluxo 2 — Compra de Jogo

```
Cliente → POST /api/v1/games/{id}/acquire  (via Kong, JWT obrigatório)
    └─► CatalogAPI publica OrderPlacedEvent (UserId + UserEmail extraídos do JWT) → retorna 202 Accepted
            └─► PaymentsAPI consome OrderPlacedEvent
                    └─► Simula pagamento (90% aprovado / 10% rejeitado)
                            └─► publica PaymentProcessedEvent no RabbitMQ
                            │       └─► CatalogAPI consome (fila catalog-api-payment-processed)
                            │               └─► [Approved] adiciona jogo à biblioteca do usuário
                            └─► dual-publish: envia o mesmo evento para SQS "fcg-payment-processed"
                                    └─► aciona a Lambda fcg-notifications-function
                                            └─► [EMAIL SIMULADO] confirmação/rejeição → CloudWatch Logs
                                            └─► grava item em DynamoDB (type: PurchaseConfirmation/PurchaseRejected)
```

> **Contratos de evento (`FCG.Events`):** `UserCreatedEvent`, `OrderPlacedEvent` e `PaymentProcessedEvent` existem como cópias locais em cada repositório (sem pacote NuGet compartilhado, para preservar a autonomia de build de cada serviço), mas **todas declaram `namespace FCG.Events;`**. O MassTransit identifica o tipo de uma mensagem no wire pelo namespace + nome do tipo .NET — se um serviço usasse um namespace diferente para sua cópia, publisher e consumer não se reconheceriam como o mesmo evento, e a mensagem seria descartada silenciosamente (sem erro, sem exceção). Pelo mesmo motivo, `PaymentProcessedEvent` é consumido em fila nomeada explicitamente (`catalog-api-payment-processed`) em vez do nome padrão derivado da classe do consumer.
>
> **Por que dual-publish (RabbitMQ + SQS) em vez de substituir a mensageria:** a Lambda roda na AWS real e não tem como consumir RabbitMQ diretamente. Reescrever toda a mensageria para SQS/SNS seria um risco desnecessário — o CatalogAPI continua dependendo do RabbitMQ para `PaymentProcessedEvent`. `UsersAPI` e `PaymentsAPI` publicam a mesma informação duas vezes: uma no RabbitMQ (como sempre) e outra, como DTO plano (sem o envelope do MassTransit), na fila SQS correspondente. Uma falha ao publicar no SQS é *best-effort* — logada, mas não derruba o fluxo principal (usuário/pagamento já processados com sucesso antes desse ponto).
>
> **Por que DynamoDB em vez do Postgres original:** a Lambda roda fora do cluster Kubernetes local e não alcança o Postgres do antigo `fcg-notifications-api`. Persistir em DynamoDB resolve essa conectividade e, de quebra, cobre o requisito de NoSQL da Fase 3 usando exatamente o cenário sugerido no enunciado ("logs de eventos").

---

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| Docker Desktop | 4.x | [docker.com](https://www.docker.com/products/docker-desktop/) |
| Docker Compose | v2 (incluso no Desktop) | — |
| kubectl | 1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Kubernetes local | qualquer | Docker Desktop K8s, Kind, Minikube ou k3d |
| .NET SDK | 10.0 (e 8.0 só para a Lambda) | Apenas para build fora do Docker |
| AWS CLI | v2 | [instruções oficiais](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| AWS SAM CLI | qualquer recente | [instruções oficiais](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) |

### Estrutura de diretórios esperada

Todos os repositórios devem estar clonados **na mesma pasta raiz**:

```
FIAP - MS/                          ← pasta raiz
├── fcg-users-api/
├── fcg-catalog-api/
├── fcg-payments-api/
├── fcg-notifications-api/          ← histórico (Fase 2); não é mais implantado
├── fcg-notifications-serverless/   ← Fase 3: função Lambda + IaC (SAM)
└── fcg-infra/                      ← este repositório
    ├── docker-compose.yml
    ├── .env
    ├── gateway/
    ├── monitoring/
    └── k8s/
```

> O `docker-compose.yml` usa `build: ../fcg-<servico>` para referenciar os Dockerfiles de cada serviço.

---

## Estrutura do Repositório

```
fcg-infra/
├── docker-compose.yml              # Orquestração local (9 serviços)
├── .env                            # Variáveis de ambiente (valores de dev já preenchidos)
├── scripts/
│   ├── build-all.sh
│   └── build-all.ps1
├── gateway/
│   └── kong.yml                    # Config declarativo do Kong (usado pelo docker-compose)
├── monitoring/
│   ├── prometheus.yml              # Scrape config (usado pelo docker-compose)
│   └── grafana/
│       ├── provisioning/           # Datasource + dashboard provider
│       └── dashboards/
│           └── fcg-overview.json   # Dashboard: request rate, status code, p95, taxa de erro
├── aws/
│   └── fcg-services-policy.json    # IAM policy mínima (sqs:SendMessage) do usuário fcg-services
└── k8s/
    ├── 00-namespace.yaml            # Namespace "fcg" (precisa ser aplicado primeiro)
    ├── infra/                       # PostgreSQL + RabbitMQ
    ├── shared/                      # Config/segredos comuns: JWT, RabbitMQ, credenciais AWS, URLs das filas SQS
    ├── redis/                       # Cache distribuído (Fase 3)
    ├── kong/                        # API Gateway (Fase 3) — mesmo config do gateway/kong.yml, adaptado para o cluster
    ├── prometheus/                  # Observabilidade Opção A (Fase 3)
    ├── grafana/                     # Observabilidade Opção A (Fase 3)
    ├── users-api/
    ├── catalog-api/                 # Inclui configmap próprio com Redis__ConnectionString
    └── payments-worker/
```

> `k8s/notifications-worker/` foi **removido** na Fase 3 — a lógica migrou para a função Lambda em `fcg-notifications-serverless`, mantendo o container antigo rodando derrotaria o propósito da migração.

---

## Execução com Docker Compose

### Passo 1 — Configure as variáveis de ambiente

Copie o template e preencha os valores (o `.env` está no `.gitignore` e nunca deve ser commitado):

```bash
cp .env.example .env
openssl rand -base64 32   # use para JWT_SECRET; gere senhas fortes para as demais
```

O `docker compose` **falha ao subir** se `JWT_SECRET`, `POSTGRES_PASSWORD`, `RABBITMQ_PASSWORD` ou `GRAFANA_ADMIN_PASSWORD` estiverem vazias — não há mais valores padrão embutidos. As variáveis `AWS_*` são as credenciais do IAM user `fcg-services` (dual-publish para a Lambda) e as URLs reais das filas SQS (saem do `sam deploy` em `fcg-notifications-serverless`).

> ⚠️ Nunca grave segredos em arquivos versionados. O Kong recebe o segredo JWT por variável de ambiente (`JWT_SECRET`) e o injeta em `/tmp/kong.yml` na subida do container.

### Passo 2 — Suba todos os serviços

```bash
docker compose up -d --build
docker compose ps
```

Resultado esperado:

| Container | Porta (host) |
|---|---|
| `fcg_postgres` | `5432` |
| `fcg_rabbitmq` | `5672`, `15672` |
| `fcg_redis` | `6379` |
| `fcg_kong` | `8000` (proxy), `8001` (admin) |
| `fcg_prometheus` | `9090` |
| `fcg_grafana` | `3000` |
| `fcg_users_api` | `8080` (direto, sem passar pelo Kong) |
| `fcg_catalog_api` | `8081` (direto, sem passar pelo Kong) |
| `fcg_payments_worker` | — |

> Os serviços de API aguardam postgres/rabbitmq/redis ficarem `healthy` antes de iniciar. As portas diretas (`8080`/`8081`) continuam expostas para debug, mas o fluxo real de uso é sempre **via Kong (`8000`)**.

### Passo 3 — Acesse os serviços

| Interface | URL | Credenciais |
|---|---|---|
| Kong (proxy — ponto de entrada real) | http://localhost:8000 | JWT nas rotas protegidas |
| UsersAPI Swagger | http://localhost:8080/swagger | — |
| CatalogAPI Swagger | http://localhost:8081/swagger | JWT necessário |
| RabbitMQ Management | http://localhost:15672 | `guest` / `guest` |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | `admin` / `admin` |

### Passo 4 — Teste os fluxos (via Kong)

**Cadastro:**
```bash
# Email e Password são Value Objects — o JSON precisa envolver o valor em { "value": "..." }
curl -X POST http://localhost:8000/api/v1/User/register \
  -H "Content-Type: application/json" \
  -d '{"name":"João Silva","email":{"value":"joao@example.com"},"password":{"value":"Senha@123"}}'

# Confirmar: CloudWatch Logs (grupo /aws/lambda/fcg-notifications-function) com "[EMAIL SIMULADO]"
# Confirmar: item novo na tabela DynamoDB fcg-notification-logs (type: Welcome)
```

**Compra de jogo:**
```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/v1/Auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":{"value":"joao@example.com"},"password":{"value":"Senha@123"}}' | jq -r '.data.token')

# Sem token: 401 do próprio Kong (não chega a bater no serviço)
curl -i http://localhost:8000/api/v1/games

# Com token válido: 200, resposta real do CatalogAPI
curl http://localhost:8000/api/v1/games -H "Authorization: Bearer $TOKEN"

# Comprar (retorna 202 Accepted)
curl -X POST http://localhost:8000/api/v1/games/{id}/acquire -H "Authorization: Bearer $TOKEN"
```

### Passo 5 — Monitorar logs

```bash
docker compose logs -f
docker compose logs -f users-api catalog-api payments-worker kong
```

### Passo 6 — Encerrar

```bash
docker compose down        # apenas parar
docker compose down -v     # parar e remover volumes (apaga os bancos)
```

---

## Deploy no Kubernetes

> **EKS (produção):** use [Infraestrutura na AWS](#infraestrutura-na-aws-terraform) e o [CI/CD](#cicd). Os Deployments de `users-api` e `catalog-api` apontam para o ECR (`122102659912.dkr.ecr.us-east-1.amazonaws.com`) e são atualizados pelo pipeline. Os passos abaixo valem para um **cluster local**: antes, publique as imagens locais com a tag do ECR (`docker tag fcg-users-api:latest <ecr>/fcg-users-api:latest`) ou ajuste o `image:` dos Deployments.

### Passo 1 — Habilite o Kubernetes local

Docker Desktop: Settings → Kubernetes → Enable Kubernetes → Apply & Restart. Para Kind/Minikube, consulte a documentação oficial.

```bash
kubectl cluster-info
kubectl get nodes
```

### Passo 2 — Build das imagens Docker locais

```bash
cd "FIAP - MS"
./fcg-infra/scripts/build-all.sh      # ou build-all.ps1 no Windows
```

Ou individualmente:
```bash
docker build -t fcg-users-api:latest ./fcg-users-api
docker build -t fcg-catalog-api:latest ./fcg-catalog-api
docker build -t fcg-payments-api:latest ./fcg-payments-api
```

> A `fcg-notifications-serverless` **não** entra nesse build — ela não roda em container, é implantada via `sam deploy` (ver seção [Persistência Poliglota](#persistência-poliglota) e o README do próprio repositório).

### Passo 3 — Crie os Secrets

Preencha o `.env` (a partir do `.env.example`) e rode `scripts/create-secrets.ps1` (ou `.sh`): ele cria no namespace `fcg` todos os Secrets que os manifests esperam. Rode **depois** de aplicar o `00-namespace.yaml` do passo 4.

Config/segredos comuns a mais de um serviço ficam centralizados em `k8s/shared/` — veja a seção [Hierarquia de Configuração e Secrets](#hierarquia-de-configuração-e-secrets) para os detalhes de por que essa separação existe.

- `k8s/shared/configmap.yaml` — Jwt Issuer/Audience/ExpirationMinutes, RabbitMq Host/Username, **URLs das filas SQS**.
- **Secret `fcg-shared-secret`** (não versionado; ver [Segredos](#segredos)) — Jwt SecretKey, RabbitMq Password, **credenciais do IAM user `fcg-services`** (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_REGION` — nomes exigidos pela cadeia de resolução de credenciais do AWS SDK, não pelo padrão `Config__Nested` usado no resto do arquivo).

O que resta em cada pasta por serviço é só o que é exclusivo dele (connection string do Postgres, e no caso do CatalogAPI, também `Redis__ConnectionString`).

> O Kong lê o segredo JWT do mesmo `fcg-shared-secret` (variável `JWT_SECRET`), então trocar `Jwt__SecretKey` basta: reinicie o pod do Kong.

### Passo 4 — Aplique os manifests

Todos os recursos são criados no namespace dedicado `fcg`. Aplique **exatamente** nesta ordem:

```bash
cd fcg-infra

kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/infra/                # PostgreSQL + RabbitMQ
kubectl apply -f k8s/shared/configmap.yaml  # Config compartilhada (os Secrets vêm do passo 3)
kubectl apply -f k8s/redis/                 # Cache do CatalogAPI

kubectl apply -f k8s/users-api/
kubectl apply -f k8s/catalog-api/
kubectl apply -f k8s/payments-worker/

kubectl apply -f k8s/kong/                  # API Gateway
kubectl apply -f k8s/prometheus/            # Observabilidade
kubectl apply -f k8s/grafana/
```

### Passo 5 — Verifique o status

```bash
kubectl get pods -n fcg
kubectl get services -n fcg
kubectl wait --for=condition=ready pod --all -n fcg --timeout=120s
```

### Passo 6 — Acesse o Kong

No EKS o Service `kong` é um Load Balancer (`kubectl get svc kong -n fcg`, coluna `EXTERNAL-IP`, porta 80). Em cluster local use o port-forward:

```bash
kubectl port-forward service/kong 8000:80 -n fcg              # ponto de entrada real
kubectl port-forward service/grafana 3000:3000 -n fcg
kubectl port-forward service/prometheus 9090:9090 -n fcg
kubectl port-forward service/rabbitmq 15672:15672 -n fcg
```

### Passo 7 — Monitore os logs

```bash
kubectl logs -f deployment/users-api -n fcg
kubectl logs -f deployment/payments-worker -n fcg
kubectl logs -f deployment/kong -n fcg
# Logs da Lambda: CloudWatch Logs, grupo /aws/lambda/fcg-notifications-function
```

### Passo 8 — Remover tudo do cluster

```bash
kubectl delete -f k8s/grafana/
kubectl delete -f k8s/prometheus/
kubectl delete -f k8s/kong/
kubectl delete -f k8s/payments-worker/
kubectl delete -f k8s/catalog-api/
kubectl delete -f k8s/users-api/
kubectl delete -f k8s/redis/
kubectl delete -f k8s/infra/
```

Para remover os recursos da AWS: `sam delete --profile fcg-deploy` no repositório `fcg-notifications-serverless`.

---

## Observabilidade

**Stack escolhida: Opção A — Prometheus + Grafana** (código aberto, self-hosted no cluster).

- `UsersAPI` e `CatalogAPI` expõem `/metrics` (formato Prometheus, via `prometheus-net.AspNetCore`) e `/health` — ambas as rotas ficam fora da validação JWT do Kong, já que o Prometheus fala direto com o Service do Kubernetes.
- `k8s/prometheus/` faz scrape estático dos dois serviços a cada 15s.
- `k8s/grafana/` provisiona automaticamente o datasource (`http://prometheus:9090`) e o dashboard **"FCG Overview"**, com 4 painéis:
  - Request rate (req/s) por serviço
  - Requisições por status code
  - Latência p95
  - Taxa de erro (5xx / total)

Métricas usadas nas queries: `http_request_duration_seconds` (histograma; `_count` dá o total de requisições, `_bucket` alimenta o `histogram_quantile` da latência) e o label `code` para quebrar por status HTTP.

---

## Persistência Poliglota

- **Cache distribuído (Redis):** `CatalogAPI` cacheia a listagem de jogos (`games:all`, TTL de 60s) via `IDistributedCache`/`StackExchange.Redis`, com invalidação explícita em criar/atualizar/remover jogo.
- **NoSQL (DynamoDB):** a função Lambda em `fcg-notifications-serverless` grava cada notificação simulada (boas-vindas, confirmação/rejeição de compra) na tabela `fcg-notification-logs`. Ver o README daquele repositório para o schema e como fazer o deploy (`sam build && sam deploy --guided`).
- **NoSQL (DynamoDB) no catálogo:** `CatalogAPI` grava as avaliações de jogos na tabela `fcg-game-reviews` (`gameId` + `userId`) via `AWSSDK.DynamoDBv2` — `GET/POST /api/v1/games/{id}/reviews`.
- **Busca avançada (OpenSearch):** `CatalogAPI` indexa cada jogo criado/editado/removido e `/api/v1/games/search` consulta só o índice (fuzzy search + ordenação por relevância). Em produção o OpenSearch roda como pod (`k8s/opensearch/`), aplicado só durante a demonstração e removido depois, para evitar custo.

---

## Hierarquia de Configuração e Secrets

Para evitar divergências, os arquivos `secret.yaml` e `configmap.yaml` adotam uma estrutura hierárquica:

- **Shared (`k8s/shared/`):** configurações e segredos comuns a mais de um serviço — JWT (Issuer/Audience/SecretKey), RabbitMQ (Host/Username/Password), credenciais AWS e URLs das filas SQS. O que estiver aqui **deve ser idêntico** entre os serviços: se trocar o `Jwt__SecretKey`, o token emitido pelo UsersAPI continua sendo aceito pelo CatalogAPI porque os dois leem do mesmo lugar via `envFrom`.
- **Service Specific (`k8s/<servico>/`):** o que resta em cada pasta por serviço é só o que é exclusivo dele — normalmente a connection string do Postgres, e no caso do CatalogAPI, também o `Redis__ConnectionString`.

> **Segurança:** os valores atuais em `k8s/*/secret.yaml` e `.env` são de desenvolvimento (a mesma prática desde a Fase 2 — dev secrets versionados para facilitar a correção/avaliação). Em qualquer ambiente real, gere valores próprios (`openssl rand -base64 32` para o JWT) e nunca reutilize os deste repositório.

---

## Variáveis de Ambiente

### UsersAPI

| Variável | Exemplo | Origem |
|---|---|---|
| `ConnectionStrings__Postgres` | `Host=postgres;...` | Secret próprio |
| `Jwt__SecretKey` | — | `fcg-shared-secret` |
| `Jwt__Issuer` / `Jwt__Audience` / `Jwt__ExpirationMinutes` | `FCG.Api` / `FCG.Client` / `60` | `fcg-shared-config` |
| `RabbitMq__Host` / `Username` / `Password` | `rabbitmq` / `guest` / — | `fcg-shared-config` / `fcg-shared-secret` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | — | `fcg-shared-secret` |
| `Aws__Sqs__UserCreatedQueueUrl` | `https://sqs.us-east-1.amazonaws.com/.../fcg-user-created` | `fcg-shared-config` |

### CatalogAPI

Mesmas variáveis de JWT/RabbitMQ do UsersAPI (com `Jwt__Issuer` = `FCG.UsersAPI`), mais:

| Variável | Exemplo | Origem |
|---|---|---|
| `Redis__ConnectionString` | `redis:6379` | `catalog-api-config` (próprio do serviço, não é `shared` porque só o CatalogAPI usa Redis hoje) |

### PaymentsAPI (Worker)

Mesmas variáveis de RabbitMQ, mais:

| Variável | Exemplo | Origem |
|---|---|---|
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | — | `fcg-shared-secret` |
| `Aws__Sqs__PaymentProcessedQueueUrl` | `https://sqs.us-east-1.amazonaws.com/.../fcg-payment-processed` | `fcg-shared-config` |

> **Nota sobre JWT:** `Jwt__SecretKey` deve ser **idêntico** em `UsersAPI`, `CatalogAPI` e na credencial JWT configurada no Kong (`k8s/kong/configmap.yaml`) — os três validam/assinam tokens com a mesma chave.
>
> Cada notificação simulada (boas-vindas, confirmação/rejeição de compra) é registrada na tabela DynamoDB `fcg-notification-logs`, além do log `[EMAIL SIMULADO]` no CloudWatch — útil para demonstrar o fluxo sem depender de captura de tela do terminal no timing certo.

---

## Endpoints (via Kong)

Ponto de entrada único: **`http://localhost:8000`** (Docker Compose) ou o DNS do Load Balancer do Service `kong` no EKS (`kubectl get svc kong -n fcg`, porta 80).

| Método | Rota | Auth | Serviço |
|---|---|---|---|
| `POST` | `/api/v1/User/register` | Pública | UsersAPI |
| `POST` | `/api/v1/Auth/login` | Pública | UsersAPI |
| `GET` | `/api/v1/User/get-all` | JWT (Admin) | UsersAPI |
| `GET` | `/api/v1/User/get-by-id` | JWT (Admin) | UsersAPI |
| `PATCH` | `/api/v1/User/update-by-id` | JWT (User/Admin) | UsersAPI |
| `GET` | `/api/v1/games` | JWT | CatalogAPI |
| `GET` | `/api/v1/games/search` | JWT | CatalogAPI |
| `POST` | `/api/v1/games` | JWT (Admin) | CatalogAPI |
| `PATCH` \| `DELETE` | `/api/v1/games/{id}` | JWT (Admin) | CatalogAPI |
| `POST` | `/api/v1/games/{id}/acquire` | JWT | CatalogAPI → retorna 202 |
| `GET` | `POST` | `/api/v1/games/{id}/reviews` | JWT | CatalogAPI (DynamoDB) |

> `Email` e `Password` são Value Objects — o corpo de `register`/`login` precisa envolver o valor: `{ "email": { "value": "..." }, "password": { "value": "..." } }`.
>
> `/metrics` e `/health` de cada serviço não passam pelo Kong — são acessados direto pelo Prometheus via Service do Kubernetes.

---

## Troubleshooting

### Container da API não sobe (exit code 1)
O serviço aguarda postgres/rabbitmq/redis ficarem `healthy`:
```bash
docker compose logs postgres
docker compose logs rabbitmq
```

### Pod com status `CrashLoopBackOff`
Os pods de API têm `restartPolicy: Always` e reiniciam sozinhos aguardando a infraestrutura. Se persistir:
```bash
kubectl describe pod <nome-do-pod> -n fcg
kubectl logs <nome-do-pod> -n fcg --previous
```
Causas comuns: Secret com valor errado, imagem Docker não encontrada (`imagePullPolicy: Never` requer build local).

### Pod com status `ErrImageNeverPull` mesmo após `docker build`
Em versões recentes do Docker Desktop, o Kubernetes roda em modo `kind` (confirme com `docker desktop kubernetes status`) — o node do cluster usa um `containerd` próprio, separado do namespace de imagens (`moby`) usado pelo `docker build`. A imagem existe no seu Docker Engine, mas o `kubelet` não a enxerga.

Sintoma: `kubectl describe pod <nome>` mostra `Container image "fcg-xxx-api:latest" is not present with pull policy of Never`.

Correções, da mais simples à mais manual:
```bash
# 1. Tente resetar o cluster Kubernetes do Docker Desktop primeiro
docker desktop kubernetes reset-cluster

# 2. Rebuilde as imagens e reaplique os manifests
./fcg-infra/scripts/build-all.sh
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/infra/ && kubectl apply -f k8s/shared/configmap.yaml
kubectl apply -f k8s/users-api/ && kubectl apply -f k8s/catalog-api/ && kubectl apply -f k8s/payments-worker/
```

Se persistir, importe a imagem manualmente para o namespace `k8s.io` do containerd do node:
```bash
kubectl debug node/<nome-do-node> --image=alpine:latest -it=false -- sleep 3600
docker save fcg-users-api:latest | kubectl exec -i <pod-debug> -- chroot /host ctr -n k8s.io images import -
```

### 401 em tudo, mesmo com token válido, ao passar pelo Kong
O `key` da credencial JWT do Kong (`k8s/kong/configmap.yaml`) precisa ser **exatamente igual** ao claim `iss` do token (hoje `FCG.Api`, o `Jwt:Issuer` do UsersAPI), e o `secret` precisa ser idêntico ao `Jwt__SecretKey`. O Kong usa a string literalmente como bytes UTF-8 (sem decodificar base64) — mesmo comportamento do `SymmetricSecurityKey` do .NET, então basta colar o mesmo valor.

### JWT inválido diretamente no CatalogAPI (`401`, sem passar pelo Kong)
```bash
kubectl get secret catalog-api-secret -n fcg -o jsonpath='{.data.Jwt__SecretKey}' | base64 -d
kubectl get secret fcg-shared-secret -n fcg -o jsonpath='{.data.Jwt__SecretKey}' | base64 -d
```
Precisam ser idênticos.

### Lambda não é acionada / nada aparece no CloudWatch Logs
1. Confirme que `Aws__Sqs__UserCreatedQueueUrl`/`Aws__Sqs__PaymentProcessedQueueUrl` estão preenchidos em `k8s/shared/configmap.yaml` (ou no `.env`, no caso do compose) com as URLs reais do `sam deploy`.
2. Confirme que `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` em `fcg-shared-secret` pertencem a um IAM user com permissão `sqs:SendMessage` nessas duas filas (`fcg-infra/aws/fcg-services-policy.json`).
3. Sem essas variáveis, o dual-publish só loga um aviso (`"... não configurado — pulando dual-publish"`) e segue — não é um erro que trava o fluxo principal, mas explica por que a Lambda não dispara.

### RabbitMQ não recebe mensagens / filas acumulando sem consumer
Acesse o Management UI (`http://localhost:15672` ou via port-forward) e confirme os consumers de cada fila (`OrderPlaced` e `catalog-api-payment-processed` devem ter pelo menos 1 cada). Desde a Fase 3, as filas `UserCreated` e a antiga `notifications-worker-payment-processed` não têm mais consumer (o `notifications-worker` que as lia foi descomissionado) — isso é esperado e inofensivo (RabbitMQ só acumula as mensagens), mas se quiser eliminar o acúmulo, considere remover essas filas/bindings do lado do publisher. As filas são criadas automaticamente pelo MassTransit na primeira conexão dos consumers.

---

## Documentação Detalhada dos Serviços

Para detalhes específicos sobre a lógica de domínio, padrões arquiteturais e suíte de testes de cada serviço, consulte a documentação dedicada nos respectivos repositórios no GitHub:

- [Users API](https://github.com/filipifirmino/fcg-users-api)
- [Catalog API](https://github.com/filipifirmino/fcg-catalog-api)
- [Payments Worker](https://github.com/filipifirmino/fcg-payments-api)
- [Notifications Worker (Fase 2, histórico)](https://github.com/filipifirmino/fcg-notifications-api)
- [Notifications Serverless (Fase 3, atual)](https://github.com/filipifirmino/fcg-notifications-serverless)

---

## Grupo 14

Projeto desenvolvido para o **Tech Challenge — Fase 3** da pós-graduação em **Full Stack Developer** — FIAP.

**Tecnologias:** .NET 10 (.NET 8 na Lambda) · ASP.NET Core · Entity Framework Core · PostgreSQL · RabbitMQ · MassTransit · Redis · Kong · Prometheus · Grafana · AWS Lambda · Amazon SQS · Amazon DynamoDB · Docker · Kubernetes

---

## Segredos

Nenhum segredo é versionado. Os `Secret` do namespace `fcg` (`fcg-shared-secret`, `catalog-api-secret`, `users-api-secret`, `payments-worker-secret`, `postgres-secret`, `rabbitmq-secret`, `grafana-secret`) são criados de duas formas, com os mesmos nomes e chaves:

| Ambiente | Como | Origem |
|---|---|---|
| Cluster local | `scripts/create-secrets.ps1` (ou `.sh`) | `.env` local (gitignored) |
| EKS | `kubectl apply -f k8s/external-secrets/` (External Secrets Operator) | AWS Secrets Manager |

Chaves esperadas no Secrets Manager (JSON): `fcg/jwt` → `secretKey`; `fcg/postgres` → `password`; `fcg/rabbitmq` → `password`; `fcg/grafana` → `password`; `fcg/aws-services` → `accessKeyId`, `secretAccessKey`. As conexões do Postgres são montadas pelo próprio ExternalSecret (`template`), então só a senha é armazenada.

---

## Infraestrutura na AWS (Terraform)

`terraform/` provisiona, na região `us-east-1`: VPC (sub-redes públicas, sem NAT), cluster **EKS** gerenciado com node group (2× `t3.large`) e add-ons (CoreDNS, kube-proxy, VPC CNI, EBS CSI), repositórios **ECR** (`fcg-users-api`, `fcg-catalog-api`, `fcg-payments-api`, com scan on push), tabela **DynamoDB** `fcg-game-reviews`, os *containers* de segredos no **Secrets Manager** (`fcg/*`, sem valores) e as roles IAM: IRSA do External Secrets Operator e a role OIDC do GitHub Actions (push no ECR + deploy no namespace `fcg`).

O OpenSearch **não** é provisionado pelo Terraform: roda como pod (`k8s/opensearch/`), aplicado só para a gravação e removido em seguida.

```bash
cd terraform
terraform init
terraform plan            # ~73 recursos
terraform apply
```

Depois do `apply`:

1. Informe os valores dos segredos (fora do repositório), por exemplo:
   `aws secretsmanager put-secret-value --secret-id fcg/jwt --secret-string '{"secretKey":"..."}'`
   (formato de cada segredo na seção [Segredos](#segredos)).
2. `scripts/bootstrap-eks.ps1` — configura o kubeconfig, instala o External Secrets Operator (Helm) e aplica namespace, ExternalSecrets e a plataforma (Postgres, RabbitMQ, Redis, Kong, Prometheus, Grafana).
3. Cadastre `AWS_ROLE_ARN` (output `github_actions_role_arn`) como variável nos repositórios do GitHub.
4. Para a demonstração: `kubectl apply -f k8s/opensearch` (e `kubectl delete -f k8s/opensearch` ao final).

**Custo aproximado enquanto ativo:** control plane do EKS (~US$ 0,10/h) + 2× `t3.large` (~US$ 0,17/h) + EBS/KMS — da ordem de US$ 7 por dia. Ao terminar: `terraform destroy` (ECR e segredos têm remoção forçada). O state é local (`terraform.tfstate`, ignorado pelo git): guarde-o até o `destroy`.

---

## CI/CD

Cada serviço (hoje `fcg-users-api` e `fcg-catalog-api`) tem um `.github/workflows/ci-cd.yml` de poucas linhas que chama o workflow reutilizável `.github/workflows/dotnet-service-cicd.yml` deste repositório:

| Etapa | O que faz | Quando |
|---|---|---|
| `test` | `dotnet restore/build/test` (inclui testes de integração com Testcontainers) | push e pull request |
| `build-and-push` | `docker build` com tags `<sha curto>` e `latest`, **scan Trivy** (falha em CRITICAL/HIGH com correção disponível) e push no ECR | push em `main` |
| `deploy` | `kubectl set image` no Deployment, `rollout status` e `rollout undo` em caso de falha | push em `main`, ambiente `production` |

Os Deployments usam `RollingUpdate` com `maxUnavailable: 0`, 2 réplicas e probes `readiness`/`liveness` em `/health`, então a atualização ocorre sem downtime. A autenticação na AWS é por **OIDC** (sem chaves de acesso no GitHub): configure a variável `AWS_ROLE_ARN` em cada repositório e um *environment* `production`. Se este repositório for privado, habilite em *Settings → Actions → Access* o uso dos workflows por outros repositórios.

Os manifests de `k8s/` são a fonte única do que roda no cluster; os repositórios dos serviços não mantêm cópias.

---

## Relatório de Entrega (rascunho)

- **Grupo:** 14 — integrantes e usernames no Discord: _preencher_
- **Documentação:** este README e os READMEs de cada serviço
- **Repositórios:** `fcg-infra`, `fcg-users-api`, `fcg-catalog-api`, `fcg-payments-api`, `fcg-notifications-api`, `fcg-notifications-serverless` (GitHub `filipifirmino`)
- **Vídeo (YouTube/Drive):** _preencher_

| Requisito do desafio | Onde está |
|---|---|
| Kubernetes gerenciado + registry privado + exposição | `terraform/` (EKS, ECR), `k8s/kong/service.yaml` (Load Balancer) |
| NoSQL com driver oficial | DynamoDB (`AWSSDK.DynamoDBv2`) — avaliações no CatalogAPI |
| Cache distribuído | Redis (`IDistributedCache`) no CatalogAPI |
| Busca com fuzzy e relevância | OpenSearch no CatalogAPI (`/api/v1/games/search`) |
| CI/CD (build, teste, imagem versionada, scan, push, rolling update) | `.github/workflows/` |
| Zero credenciais no código | AWS Secrets Manager + External Secrets Operator (`k8s/external-secrets/`) |
