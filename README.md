# FCG Infra — Grupo 14

Repositório de orquestração da plataforma **FIAP Cloud Games (FCG)**. Centraliza o `docker-compose.yml` para execução local completa e todos os manifests Kubernetes para deploy em cluster. Não contém código de aplicação.

---

## Sumário

- [Visão Geral](#visão-geral)
- [Arquitetura e Fluxo de Eventos](#arquitetura-e-fluxo-de-eventos)
- [Pré-requisitos](#pré-requisitos)
- [Estrutura do Repositório](#estrutura-do-repositório)
- [Execução com Docker Compose](#execução-com-docker-compose)
- [Deploy no Kubernetes](#deploy-no-kubernetes)
- [Variáveis de Ambiente](#variáveis-de-ambiente)
- [Endpoints das APIs](#endpoints-das-apis)
- [Troubleshooting](#troubleshooting)

---

## Visão Geral

A FCG é composta por **quatro microsserviços independentes** que se comunicam de forma assíncrona via **RabbitMQ + MassTransit**. Cada serviço tem seu próprio repositório, banco de dados e ciclo de vida.

| Microsserviço | Repositório | Tipo | Porta (host) |
|---|---|---|---|
| UsersAPI | `fcg-users-api` | Web API | `8080` |
| CatalogAPI | `fcg-catalog-api` | Web API | `8081` |
| PaymentsAPI | `fcg-payments-api` | Worker Service | — |
| NotificationsAPI | `fcg-notifications-api` | Worker Service | — |

**Infraestrutura compartilhada:**

| Serviço | Porta (host) | Finalidade |
|---|---|---|
| PostgreSQL 16 | `5432` | Banco de dados (1 DB por serviço, 1 instância) |
| RabbitMQ 3 | `5672` / `15672` | Broker de mensagens / Management UI |

---

## Arquitetura e Fluxo de Eventos

```
┌─────────────────────────────────────────────────────────────────────┐
│                         KUBERNETES CLUSTER                          │
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌───────────────────────┐  │
│  │  UsersAPI    │    │  CatalogAPI  │    │     PaymentsAPI       │  │
│  │  port: 8080  │    │  port: 8081  │    │   (Worker — sem HTTP) │  │
│  │              │    │              │    │                       │  │
│  │ POST /register│   │ GET  /games  │    │  Consome:             │  │
│  │ POST /login  │    │ POST /games  │    │    OrderPlacedEvent   │  │
│  │ GET  /users  │    │ PATCH /games │    │  Publica:             │  │
│  │ PATCH /users │    │ DELETE /games│    │    PaymentProcessed   │  │
│  │              │    │ POST /acquire│    │    Event              │  │
│  └──────┬───────┘    └──────┬───────┘    └──────────┬────────────┘  │
│         │                   │                        │              │
│  UserCreatedEvent     OrderPlacedEvent         PaymentProcessedEvent│
│         │                   │                        │              │
│         └───────────────────┴────────────────────────┘              │
│                             │                                       │
│                    ┌────────▼────────┐                              │
│                    │    RabbitMQ     │                              │
│                    │  amqp: 5672     │                              │
│                    │  mgmt: 15672    │                              │
│                    └────────┬────────┘                              │
│                             │                                       │
│                   ┌─────────▼──────────┐                            │
│                   │  NotificationsAPI  │                            │
│                   │  (Worker — sem HTTP│                            │
│                   │                   │                            │
│                   │  Consome:         │                            │
│                   │    UserCreated    │                            │
│                   │    PaymentProc.   │                            │
│                   └───────────────────┘                            │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  PostgreSQL  (postgres:5432)                                │   │
│  │  ├── fcg_users_db    (UsersAPI)                             │   │
│  │  ├── fcg_catalog_db  (CatalogAPI)                           │   │
│  │  └── fcg_payments_db (PaymentsAPI)                          │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Fluxo 1 — Cadastro de Usuário

```
Cliente → POST /api/v1/User/register
    └─► UsersAPI cria usuário no banco
            └─► publica UserCreatedEvent
                    └─► NotificationsAPI consome
                            └─► [EMAIL SIMULADO] log de boas-vindas + grava notification_logs
```

### Fluxo 2 — Compra de Jogo

```
Cliente → POST /api/v1/games/{id}/acquire  (JWT obrigatório)
    └─► CatalogAPI publica OrderPlacedEvent (UserId + UserEmail extraídos do JWT) → retorna 202 Accepted
            └─► PaymentsAPI consome OrderPlacedEvent
                    └─► Simula pagamento (90% aprovado / 10% rejeitado)
                            └─► publica PaymentProcessedEvent
                                    ├─► CatalogAPI consome (fila catalog-api-payment-processed)
                                    │       └─► [Approved] adiciona jogo à biblioteca do usuário
                                    └─► NotificationsAPI consome (fila notifications-worker-payment-processed)
                                            └─► [Approved] [EMAIL SIMULADO] confirmação de compra + grava notification_logs
```

> **Contratos de evento (`FCG.Events`):** `UserCreatedEvent`, `OrderPlacedEvent` e `PaymentProcessedEvent` existem como cópias locais em cada repositório (sem pacote NuGet compartilhado, para preservar a autonomia de build de cada serviço), mas **todas declaram `namespace FCG.Events;`**. O MassTransit identifica o tipo de uma mensagem no wire pelo namespace + nome do tipo .NET — se um serviço usasse um namespace diferente para sua cópia, publisher e consumer não se reconheceriam como o mesmo evento, e a mensagem seria descartada silenciosamente (sem erro, sem exceção). Pelo mesmo motivo, `PaymentProcessedEvent` é consumido em **filas nomeadas explicitamente** por serviço (`catalog-api-payment-processed`, `notifications-worker-payment-processed`) em vez do nome padrão derivado da classe `PaymentProcessedConsumer` — as duas classes têm o mesmo nome em repositórios diferentes, e sem essa distinção os dois serviços cairiam na mesma fila física, competindo pela mensagem em vez de cada um receber sua cópia.

---

## Pré-requisitos

| Ferramenta | Versão mínima | Instalação |
|---|---|---|
| Docker Desktop | 4.x | [docker.com](https://www.docker.com/products/docker-desktop/) |
| Docker Compose | v2 (incluso no Desktop) | — |
| kubectl | 1.28+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| Kubernetes local | qualquer | Docker Desktop K8s, Kind, Minikube ou k3d |
| .NET SDK | 10.0 | Apenas para build fora do Docker |

### Estrutura de diretórios esperada

Todos os repositórios devem estar clonados **na mesma pasta raiz**:

```
FIAP - MS/              ← pasta raiz
├── fcg-users-api/
├── fcg-catalog-api/
├── fcg-payments-api/
├── fcg-notifications-api/
└── fcg-infra/          ← este repositório
    ├── docker-compose.yml
    ├── .env.example
    └── k8s/
```

> O `docker-compose.yml` usa `build: ../fcg-<servico>` para referenciar os Dockerfiles de cada serviço.

---

## Estrutura do Repositório

```
fcg-infra/
├── docker-compose.yml              # Orquestração local (6 serviços)
├── .env.example                    # Variáveis de ambiente necessárias
└── k8s/
    ├── infra/                      # Infraestrutura compartilhada no cluster
    │   ├── postgres-deployment.yaml
    │   ├── postgres-service.yaml
    │   ├── postgres-secret.yaml
    │   ├── rabbitmq-deployment.yaml
    │   ├── rabbitmq-service.yaml
    │   └── rabbitmq-secret.yaml
    ├── users-api/                  # Manifests do UsersAPI
    │   ├── deployment.yaml
    │   ├── service.yaml            # ClusterIP port 80 → 8080
    │   ├── configmap.yaml
    │   └── secret.yaml
    ├── catalog-api/                # Manifests do CatalogAPI
    │   ├── deployment.yaml
    │   ├── service.yaml            # ClusterIP port 80 → 8080
    │   ├── configmap.yaml
    │   └── secret.yaml
    ├── payments-worker/            # Manifests do PaymentsAPI (Worker)
    │   ├── deployment.yaml
    │   ├── service.yaml            # Headless (clusterIP: None)
    │   ├── configmap.yaml
    │   └── secret.yaml
    └── notifications-worker/       # Manifests do NotificationsAPI (Worker)
        ├── deployment.yaml
        ├── service.yaml            # Headless (clusterIP: None)
        ├── configmap.yaml
        └── secret.yaml
```

---

## Execução com Docker Compose

### Passo 1 — Configure as variáveis de ambiente

Copie o arquivo de exemplo e edite o valor do `JWT_SECRET`:

```bash
cd fcg-infra
cp .env.example .env
```

Conteúdo do `.env`:

```env
# Chave JWT compartilhada entre UsersAPI e CatalogAPI
# Gere uma nova com: openssl rand -base64 32
JWT_SECRET=UvPTu5UZIcSe0V1onJSNTWT579OHlmoxXA1flLgKpow=

# Senha do PostgreSQL (usuário: fcg)
POSTGRES_PASSWORD=fcg_secret

# Senha do RabbitMQ (usuário: guest)
RABBITMQ_PASSWORD=guest
```

### Passo 2 — Suba todos os serviços

```bash
# Build + inicialização de todos os containers
docker compose up -d --build

# Verifique se todos estão Up
docker compose ps
```

Resultado esperado (`docker compose ps`):

| Container | Status | Ports |
|---|---|---|
| `fcg_postgres` | Up (healthy) | `0.0.0.0:5432->5432/tcp` |
| `fcg_rabbitmq` | Up (healthy) | `0.0.0.0:5672->5672/tcp`, `0.0.0.0:15672->15672/tcp` |
| `fcg_users_api` | Up | `0.0.0.0:8080->8080/tcp` |
| `fcg_catalog_api` | Up | `0.0.0.0:8081->8080/tcp` |
| `fcg_payments_worker` | Up | — |
| `fcg_notifications_worker` | Up | — |

> Os serviços de API aguardam o postgres e rabbitmq passarem no healthcheck antes de iniciar (`depends_on: condition: service_healthy`).

### Passo 3 — Acesse os serviços

| Interface | URL | Credenciais |
|---|---|---|
| UsersAPI Swagger | http://localhost:8080/swagger | — |
| CatalogAPI Swagger | http://localhost:8081/swagger | JWT necessário |
| RabbitMQ Management | http://localhost:15672 | `guest` / `guest` |

### Passo 4 — Teste os fluxos

**Fluxo de cadastro:**
```bash
# 1. Registrar usuário (deve disparar e-mail de boas-vindas no log do notifications-worker)
# Email e Password são Value Objects — o JSON precisa envolver o valor em { "value": "..." }
curl -X POST http://localhost:8080/api/v1/User/register \
  -H "Content-Type: application/json" \
  -d '{"name":"João Silva","email":{"value":"joao@example.com"},"password":{"value":"Senha@123"}}'

# 2. Verificar log do notifications-worker
docker compose logs notifications-worker | grep "EMAIL SIMULADO"

# 3. Conferir o registro persistido em notification_logs
docker exec -it fcg_postgres psql -U fcg -d fcg_notifications_db \
  -c "SELECT type, recipient, message FROM notification_logs ORDER BY sent_at DESC LIMIT 5;"
```

**Fluxo de compra:**
```bash
# 1. Fazer login e obter JWT
TOKEN=$(curl -s -X POST http://localhost:8080/api/v1/Auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":{"value":"joao@example.com"},"password":{"value":"Senha@123"}}' | jq -r '.data.token')

# 2. Iniciar compra de jogo (retorna 202 Accepted)
curl -X POST http://localhost:8081/api/v1/games/{id}/acquire \
  -H "Authorization: Bearer $TOKEN"

# 3. Verificar logs do pagamento e notificação
docker compose logs payments-worker
docker compose logs notifications-worker
```

### Passo 5 — Monitorar logs

```bash
# Todos os serviços simultaneamente
docker compose logs -f

# Serviço específico
docker compose logs -f users-api
docker compose logs -f catalog-api
docker compose logs -f payments-worker
docker compose logs -f notifications-worker
```

### Passo 6 — Encerrar

```bash
# Apenas parar os containers
docker compose down

# Parar e remover volumes (apaga os bancos de dados)
docker compose down -v
```

---

## Deploy no Kubernetes

### Passo 1 — Habilite o Kubernetes local

No **Docker Desktop**: Settings → Kubernetes → Enable Kubernetes → Apply & Restart.

Para **Kind** ou **Minikube**, consulte a documentação oficial de cada ferramenta.

Verifique que o cluster está ativo:
```bash
kubectl cluster-info
kubectl get nodes
```

### Passo 2 — Build das imagens Docker locais

Execute a partir da **pasta raiz** (onde estão todos os repositórios):

```bash
cd "FIAP - MS"
./fcg-infra/scripts/build-all.sh
```

Ou individualmente:
```bash
docker build -t fcg-users-api:latest ./fcg-users-api
docker build -t fcg-catalog-api:latest ./fcg-catalog-api
docker build -t fcg-payments-api:latest ./fcg-payments-api
docker build -t fcg-notifications-api:latest ./fcg-notifications-api
```

Confirme que as imagens foram criadas:
```bash
docker images | grep fcg
```

> Os manifests usam `imagePullPolicy: Never` para usar as imagens locais sem precisar de um registry remoto.

### Passo 3 — Personalize os Secrets (opcional)

Os arquivos `secret.yaml` usam `stringData` com valores padrão prontos para uso em ambiente de desenvolvimento. Para personalizar:

```bash
# Exemplo: gerar nova chave JWT
openssl rand -base64 32
```

Configurações e segredos comuns a mais de um serviço (RabbitMQ host/usuário, JWT Issuer/Audience/SecretKey) ficam centralizados em `k8s/shared/`, para não divergir entre serviços. O que resta em cada pasta por serviço é só o que é exclusivo dele (normalmente a connection string do Postgres):

- `k8s/shared/configmap.yaml` — `fcg-shared-config`: RabbitMq Host/Username, Jwt Issuer/Audience/ExpirationMinutes, ambiente
- `k8s/shared/secret.yaml` — `fcg-shared-secret`: Jwt SecretKey, RabbitMq Password
- `k8s/infra/postgres-secret.yaml` — credenciais do PostgreSQL
- `k8s/infra/rabbitmq-secret.yaml` — credenciais do RabbitMQ
- `k8s/users-api/secret.yaml` — connection string do Postgres
- `k8s/catalog-api/secret.yaml` — connection string do Postgres
- `k8s/payments-worker/secret.yaml` — connection string do Postgres
- `k8s/notifications-worker/secret.yaml` — connection string do Postgres
- `k8s/notifications-worker/configmap.yaml` — nível de log específico do worker

> Se trocar `fcg-shared-secret.Jwt__SecretKey`, o token emitido pelo UsersAPI só é aceito pelo CatalogAPI porque os dois leem a mesma chave via `envFrom` — não precisa (nem deve) duplicar o valor em outro lugar.

### Passo 4 — Aplique os manifests

Todos os recursos são criados no namespace dedicado `fcg` (não em `default`).

```bash
cd fcg-infra

# 0. Namespace (precisa existir antes dos demais recursos)
kubectl apply -f k8s/00-namespace.yaml

# 1. Infraestrutura (PostgreSQL + RabbitMQ)
kubectl apply -f k8s/infra/

# 2. Configuração/segredos compartilhados (precisa existir antes dos serviços, que dependem dele via envFrom)
kubectl apply -f k8s/shared/

# 3. Microsserviços
kubectl apply -f k8s/users-api/
kubectl apply -f k8s/catalog-api/
kubectl apply -f k8s/payments-worker/
kubectl apply -f k8s/notifications-worker/
```

### Passo 5 — Verifique o status dos pods

```bash
# Listar todos os pods do namespace fcg
kubectl get pods -n fcg

# Listar todos os services do namespace fcg
kubectl get services -n fcg

# Aguardar todos os pods ficarem Ready
kubectl wait --for=condition=ready pod --all -n fcg --timeout=120s
```

Resultado esperado (`kubectl get pods`):

```
NAME                                    READY   STATUS    RESTARTS   AGE
postgres-<hash>                         1/1     Running   0          2m
rabbitmq-<hash>                         1/1     Running   0          2m
users-api-<hash>                        1/1     Running   0          1m
catalog-api-<hash>                      1/1     Running   0          1m
payments-worker-<hash>                  1/1     Running   0          1m
notifications-worker-<hash>             1/1     Running   0          1m
```

### Passo 6 — Acesse as APIs via port-forward

```bash
# Terminal 1 — UsersAPI
kubectl port-forward service/users-api 8080:80

# Terminal 2 — CatalogAPI
kubectl port-forward service/catalog-api 8081:80

# Terminal 3 — RabbitMQ Management (opcional)
kubectl port-forward service/rabbitmq 15672:15672
```

Acesse:
- UsersAPI Swagger: http://localhost:8080/swagger
- CatalogAPI Swagger: http://localhost:8081/swagger
- RabbitMQ Management: http://localhost:15672

### Passo 7 — Monitore os logs no cluster

```bash
# Logs de um deployment
kubectl logs -f deployment/users-api
kubectl logs -f deployment/payments-worker
kubectl logs -f deployment/notifications-worker

# Descrever um pod (útil para debugar falhas de startup)
kubectl describe pod <nome-do-pod>
```

### Passo 8 — Remover tudo do cluster

```bash
kubectl delete -f k8s/notifications-worker/
kubectl delete -f k8s/payments-worker/
kubectl delete -f k8s/catalog-api/
kubectl delete -f k8s/users-api/
kubectl delete -f k8s/infra/
```

---

## Variáveis de Ambiente

### UsersAPI

| Variável | Exemplo | Origem |
|---|---|---|
| `ConnectionStrings__Postgres` | `Host=postgres;Port=5432;Database=fcg_users_db;Username=fcg;Password=fcg_secret` | Secret |
| `Jwt__SecretKey` | `UvPTu5UZ...` | Secret |
| `Jwt__Issuer` | `FCG.Api` | ConfigMap |
| `Jwt__Audience` | `FCG.Client` | ConfigMap |
| `Jwt__ExpirationMinutes` | `60` | ConfigMap |
| `RabbitMq__Host` | `rabbitmq` | ConfigMap |
| `RabbitMq__Username` | `guest` | ConfigMap |
| `RabbitMq__Password` | `guest` | Secret |

### CatalogAPI

| Variável | Exemplo | Origem |
|---|---|---|
| `ConnectionStrings__Postgres` | `Host=postgres;Port=5432;Database=fcg_catalog_db;Username=fcg;Password=fcg_secret` | Secret |
| `Jwt__SecretKey` | `UvPTu5UZ...` *(deve ser igual ao UsersAPI)* | Secret |
| `Jwt__Issuer` | `FCG.UsersAPI` | ConfigMap |
| `Jwt__Audience` | `FCG.Client` | ConfigMap |
| `RabbitMq__Host` | `rabbitmq` | ConfigMap |
| `RabbitMq__Username` | `guest` | ConfigMap |
| `RabbitMq__Password` | `guest` | Secret |

### PaymentsAPI (Worker)

| Variável | Exemplo | Origem |
|---|---|---|
| `ConnectionStrings__Postgres` | `Host=postgres;Port=5432;Database=fcg_payments_db;Username=fcg;Password=fcg_secret` | Secret |
| `RabbitMq__Host` | `rabbitmq` | ConfigMap |
| `RabbitMq__Username` | `guest` | ConfigMap |
| `RabbitMq__Password` | `guest` | Secret |

### NotificationsAPI (Worker)

| Variável | Exemplo | Origem |
|---|---|---|
| `ConnectionStrings__Postgres` | `Host=postgres;Port=5432;Database=fcg_notifications_db;Username=fcg;Password=fcg_secret` | Secret |
| `RabbitMq__Host` | `rabbitmq` | ConfigMap |
| `RabbitMq__Username` | `guest` | ConfigMap |
| `RabbitMq__Password` | `guest` | Secret |

> Cada notificação simulada (boas-vindas, confirmação/rejeição de compra) é registrada na tabela `notification_logs` do banco `fcg_notifications_db`, além do log em console — útil para demonstrar o fluxo sem depender de captura de tela do terminal no timing certo.

> **Nota sobre JWT:** `Jwt__SecretKey` deve ser **idêntico** no UsersAPI e no CatalogAPI. O CatalogAPI valida tokens emitidos pelo UsersAPI usando a mesma chave.

---

## Endpoints das APIs

### UsersAPI — `http://localhost:8080`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `POST` | `/api/v1/User/register` | Anônimo | Cadastra usuário + dispara e-mail de boas-vindas |
| `POST` | `/api/v1/Auth/login` | Anônimo | Autentica e retorna JWT |
| `GET` | `/api/v1/User/get-all` | Admin | Lista todos os usuários |
| `GET` | `/api/v1/User/get-by-id` | Admin | Busca usuário por ID |
| `PATCH` | `/api/v1/User/update-by-id` | User/Admin | Atualiza dados do perfil |

> `Email` e `Password` são Value Objects — o corpo de `register`/`login` precisa envolver o valor: `{ "email": { "value": "..." }, "password": { "value": "..." } }`.

### CatalogAPI — `http://localhost:8081`

| Método | Rota | Auth | Descrição |
|---|---|---|---|
| `GET` | `/api/v1/games` | User/Admin | Lista jogos do catálogo |
| `GET` | `/api/v1/games/search` | User/Admin | Busca jogos com paginação |
| `POST` | `/api/v1/games` | Admin | Cria novo jogo |
| `PATCH` | `/api/v1/games/{id}` | Admin | Atualiza jogo |
| `DELETE` | `/api/v1/games/{id}` | Admin | Remove jogo |
| `POST` | `/api/v1/games/{id}/acquire` | User/Admin | Inicia fluxo de compra → retorna 202 |

---

## Troubleshooting

### Container da API não sobe (exit code 1)
O serviço aguarda postgres e rabbitmq ficarem `healthy`. Se demorar, verifique:
```bash
docker compose logs postgres
docker compose logs rabbitmq
```

### Pod com status `CrashLoopBackOff`
```bash
kubectl describe pod <nome-do-pod>
kubectl logs <nome-do-pod> --previous
```
Causas comuns: Secret com valor errado, imagem Docker não encontrada (`imagePullPolicy: Never` requer build local).

### Pod com status `ErrImageNeverPull` mesmo após `docker build`
Em versões recentes do Docker Desktop, o Kubernetes roda em **modo `kind`** (confirme com `docker desktop kubernetes status`) — o node do cluster usa um `containerd` próprio, separado do namespace de imagens (`moby`) usado pelo `docker build`/`docker images`. Ou seja, a imagem existe no seu Docker Engine, mas o `kubelet` não a enxerga.

Sintoma: `kubectl describe pod <nome>` mostra `Container image "fcg-xxx-api:latest" is not present with pull policy of Never`, mesmo com `docker images` listando a imagem.

Correções, da mais simples à mais manual:
```bash
# 1. Tente resetar o cluster Kubernetes do Docker Desktop primeiro
#    (às vezes resincroniza o compartilhamento de imagens)
docker desktop kubernetes reset-cluster

# 2. Rebuilde as imagens e reaplique os manifests
./fcg-infra/scripts/build-all.sh
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/infra/ && kubectl apply -f k8s/shared/
kubectl apply -f k8s/users-api/ && kubectl apply -f k8s/catalog-api/ \
  && kubectl apply -f k8s/payments-worker/ && kubectl apply -f k8s/notifications-worker/
```

Se persistir, importe a imagem manualmente para o namespace `k8s.io` do containerd do node:
```bash
kubectl debug node/<nome-do-node> --image=alpine:latest -it=false -- sleep 3600
# pegue o nome do pod criado (node-debugger-...) e rode, para cada imagem:
docker save fcg-users-api:latest | kubectl exec -i <pod-debug> -- chroot /host ctr -n k8s.io images import -
```

### Migrations não executam no K8s
Os serviços executam `MigrateAsync()` no startup. Se o postgres ainda não estiver pronto, o pod vai reiniciar. O `restartPolicy: Always` garante que ele tente novamente. Aguarde o pod estabilizar.

### JWT inválido no CatalogAPI (`401 Unauthorized`)
O `Jwt__SecretKey` nos secrets de `users-api` e `catalog-api` deve ser idêntico. Verifique:
```bash
kubectl get secret users-api-secret -o jsonpath='{.data.Jwt__SecretKey}' | base64 -d
kubectl get secret catalog-api-secret -o jsonpath='{.data.Jwt__SecretKey}' | base64 -d
```

### RabbitMQ não recebe mensagens
Acesse o Management UI (http://localhost:15672 ou via port-forward) e verifique se as filas `UserCreated`, `OrderPlaced` e `PaymentProcessed` estão criadas, com pelo menos 1 consumer cada (`PaymentProcessed` deve ter 2: CatalogAPI e NotificationsAPI). As filas são criadas automaticamente pelo MassTransit na primeira conexão dos consumers.

---

## Grupo 14

Projeto desenvolvido para o **Tech Challenge — Fase 2** da pós-graduação em **Full Stack Developer** — FIAP.

**Tecnologias:** .NET 10 · ASP.NET Core · Entity Framework Core · PostgreSQL · RabbitMQ · MassTransit · Docker · Kubernetes
