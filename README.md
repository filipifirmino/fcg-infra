# FCG Infra — Grupo 14

Repositório de orquestração da plataforma FIAP Cloud Games (FCG). Contém o `docker-compose.yml` para execução local completa e os manifests Kubernetes para deploy em cluster.

---

## Sumário

- [Visão Geral](#visão-geral)
- [Microsserviços](#microsserviços)
- [Arquitetura](#arquitetura)
- [Pré-requisitos](#pré-requisitos)
- [Rodando com Docker Compose](#rodando-com-docker-compose)
- [Deploy no Kubernetes](#deploy-no-kubernetes)
- [Variáveis de Ambiente](#variáveis-de-ambiente)
- [Estrutura do Repositório](#estrutura-do-repositório)

---

## Visão Geral

Este repositório centraliza a infraestrutura de orquestração dos quatro microsserviços FCG. Não contém código de aplicação — apenas configurações de ambiente, containers e manifests de deploy.

| Repositório | Responsabilidade | Porta |
|---|---|---|
| [fcg-users-api](../fcg-users-api) | Cadastro e autenticação de usuários | 8080 |
| [fcg-catalog-api](../fcg-catalog-api) | Catálogo de jogos e fluxo de compra | 8081 |
| [fcg-payments-api](../fcg-payments-api) | Simulação de pagamentos (Worker) | — |
| [fcg-notifications-api](../fcg-notifications-api) | Notificações por e-mail simuladas (Worker) | — |

---

## Microsserviços

### Fluxo de eventos

```
UsersAPI  ──UserCreatedEvent──────────────────────────────▶  NotificationsAPI
               (user.created)                                  (boas-vindas)

CatalogAPI  ──OrderPlacedEvent──▶  PaymentsAPI  ──PaymentProcessedEvent──┬──▶  CatalogAPI
                (order.placed)       (simulação)    (payment.processed)   │      (biblioteca)
                                                                          └──▶  NotificationsAPI
                                                                                 (confirmação)
```

### Bancos de dados (1 por serviço)

| Serviço | Banco | Tabelas |
|---|---|---|
| UsersAPI | `fcg_users_db` | `users` |
| CatalogAPI | `fcg_catalog_db` | `games`, `acquisitions` |
| PaymentsAPI | `fcg_payments_db` | `payments` |
| NotificationsAPI | — | (sem persistência) |

---

## Arquitetura

```
┌─────────────────────────────────────────────────────────────────┐
│                        KUBERNETES CLUSTER                       │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐    │
│  │  UsersAPI    │   │  CatalogAPI  │   │   PaymentsAPI    │    │
│  │  :8080       │   │  :8081       │   │   (worker only)  │    │
│  └──────┬───────┘   └──────┬───────┘   └────────┬─────────┘    │
│         │                  │                     │              │
│         │ UserCreated       │ OrderPlaced         │ PaymentProc. │
│         └──────────────────┴─────────────────────┴──────────┐  │
│                                                              │  │
│                     ┌────────────────┐                       │  │
│                     │   RabbitMQ     │◀──────────────────────┘  │
│                     │   :5672/:15672 │                          │
│                     └───────┬────────┘                          │
│                             │                                   │
│                    ┌────────▼──────────┐                        │
│                    │  NotificationsAPI │                        │
│                    │  (worker only)    │                        │
│                    └───────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Pré-requisitos

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) com Kubernetes habilitado (ou [Kind](https://kind.sigs.k8s.io/) / [Minikube](https://minikube.sigs.k8s.io/))
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Repositórios dos microsserviços clonados na mesma pasta raiz

### Estrutura esperada de diretórios

```
./ (pasta raiz)
├── fcg-users-api/
├── fcg-catalog-api/
├── fcg-payments-api/
├── fcg-notifications-api/
└── fcg-infra/          ← este repositório
    ├── docker-compose.yml
    └── k8s/
```

---

## Rodando com Docker Compose

### 1. Configure as variáveis de ambiente

Crie um arquivo `.env` na raiz deste repositório:

```env
JWT_SECRET=UvPTu5UZIcSe0V1onJSNTWT579OHlmoxXA1flLgKpow=
```

### 2. Suba todos os serviços

```bash
docker compose up -d
```

Serviços iniciados:

| Serviço | Container | Porta(s) |
|---|---|---|
| PostgreSQL 16 | `fcg_postgres` | `5432` |
| RabbitMQ 3 | `fcg_rabbitmq` | `5672` / `15672` (management) |
| UsersAPI | `fcg_users_api` | `8080` |
| CatalogAPI | `fcg_catalog_api` | `8081` |
| PaymentsAPI Worker | `fcg_payments_worker` | — |
| NotificationsAPI Worker | `fcg_notifications_worker` | — |

### 3. Verifique os logs

```bash
# Todos os serviços
docker compose logs -f

# Serviço específico
docker compose logs -f users-api
docker compose logs -f notifications-worker
```

### 4. Acesse os serviços

| Serviço | URL |
|---|---|
| UsersAPI Swagger | http://localhost:8080/swagger |
| CatalogAPI Swagger | http://localhost:8081/swagger |
| RabbitMQ Management | http://localhost:15672 (guest/guest) |

### 5. Encerre os serviços

```bash
docker compose down
# Para remover também os volumes (banco de dados):
docker compose down -v
```

---

## Deploy no Kubernetes

### 1. Build das imagens Docker locais

Execute na pasta raiz (onde estão os repositórios dos microsserviços):

```bash
docker build -t fcg-users-api:latest ./fcg-users-api
docker build -t fcg-catalog-api:latest ./fcg-catalog-api
docker build -t fcg-payments-api:latest ./fcg-payments-api
docker build -t fcg-notifications-api:latest ./fcg-notifications-api
```

### 2. Configure os Secrets

Edite `k8s/secret.yaml` substituindo os valores base64:

```bash
# Gere os valores base64
echo -n "Host=postgres;Port=5432;Database=fcg_users_db;Username=fcg;Password=fcg_secret" | base64
echo -n "UvPTu5UZIcSe0V1onJSNTWT579OHlmoxXA1flLgKpow=" | base64
echo -n "fcg_secret" | base64
```

### 3. Aplique os manifests

```bash
# Infraestrutura compartilhada (PostgreSQL + RabbitMQ)
kubectl apply -f k8s/infra/

# Cada microsserviço
kubectl apply -f k8s/users-api/
kubectl apply -f k8s/catalog-api/
kubectl apply -f k8s/payments-worker/
kubectl apply -f k8s/notifications-worker/
```

### 4. Verifique o status

```bash
# Pods em execução
kubectl get pods

# Serviços expostos
kubectl get services

# Logs de um pod
kubectl logs -f deployment/users-api
```

### 5. Acesse as APIs (port-forward)

```bash
kubectl port-forward service/users-api 8080:80
kubectl port-forward service/catalog-api 8081:80
```

---

## Variáveis de Ambiente

### Compartilhadas (todos os serviços)

| Variável | Descrição |
|---|---|
| `RabbitMq__Host` | Host do RabbitMQ (`rabbitmq` no Docker Compose, `rabbitmq` no K8s) |
| `RabbitMq__Username` | Usuário do RabbitMQ |
| `RabbitMq__Password` | Senha do RabbitMQ |

### UsersAPI e CatalogAPI

| Variável | Descrição |
|---|---|
| `Jwt__SecretKey` | Chave secreta JWT compartilhada entre os dois serviços |
| `Jwt__Issuer` | `FCG.UsersAPI` |
| `Jwt__Audience` | `FCG.Client` |
| `Jwt__ExpirationMinutes` | `60` |

### Bancos de dados

| Serviço | Variável | Banco |
|---|---|---|
| UsersAPI | `ConnectionStrings__Postgres` | `fcg_users_db` |
| CatalogAPI | `ConnectionStrings__Postgres` | `fcg_catalog_db` |
| PaymentsAPI | `ConnectionStrings__Postgres` | `fcg_payments_db` |

---

## Estrutura do Repositório

```
fcg-infra/
├── docker-compose.yml          # Orquestração local completa
├── .env.example                # Exemplo de variáveis de ambiente
└── k8s/
    ├── infra/
    │   ├── postgres-deployment.yaml
    │   ├── postgres-service.yaml
    │   ├── rabbitmq-deployment.yaml
    │   └── rabbitmq-service.yaml
    ├── users-api/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── configmap.yaml
    │   └── secret.yaml
    ├── catalog-api/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── configmap.yaml
    │   └── secret.yaml
    ├── payments-worker/
    │   ├── deployment.yaml
    │   ├── configmap.yaml
    │   └── secret.yaml
    └── notifications-worker/
        ├── deployment.yaml
        └── configmap.yaml
```

---

## Grupo 14

Projeto desenvolvido para a disciplina **Full Stack Developer** — FIAP.
