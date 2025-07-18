# 🚀 Deploy Blue/Green com Docker, ECR e EC2 via GitHub Actions & SSM

Um template reutilizável para automatizar deploys de aplicações Docker em instâncias **Amazon EC2**, utilizando a estratégia **Blue/Green**. A orquestração é feita pelo **GitHub Actions**, com imagens gerenciadas no **Amazon ECR** e execução remota via **AWS Systems Manager (SSM)**.

> ⚠️ **Importante:**
> Esta solução foi criada especialmente para aplicações que **não estão configuradas para ler diretamente os secrets do AWS Secrets Manager**. O script de deploy busca os secrets, gera um arquivo `.env` na instância EC2 e injeta as variáveis de ambiente no container Docker via flag `--env-file`.

## 📋 Índice

- [Visão Geral da Arquitetura](#-visão-geral-da-arquitetura)
- [Como Funciona](#-como-funciona)
- [Pré-requisitos](#-pré-requisitos)
  - [Na AWS](#na-aws)
  - [No GitHub (Autenticação AWS)](#no-github-autenticação-aws)
  - [Na Instância EC2](#na-instância-ec2)
- [Como Usar](#-como-usar)
- [Conteúdo Completo dos Arquivos](#-conteúdo-completo-dos-arquivos)
  - [templates/github-actions-deploy-template.yml](#templatesgithub-actions-deploy-templateyml)
  - [templates/deploy-blue-green-ecr-to-ec2.sh](#templatesdeploy-blue-green-ecr-to-ec2sh)
  - [example/.env.sample](#exampleenvsample)
  - [LICENSE](#license)
- [Autor](#-autor)


---

## 🏗️ Visão Geral da Arquitetura

O fluxo de trabalho segue os seguintes passos:

1.  **Push/Merge:** Um desenvolvedor envia o código para uma branch específica (ex: `main` ou `develop`).
2.  **GitHub Actions:** O push aciona o workflow do GitHub Actions.
3.  **Build & Push:** A action, rodando em um runner (ex: AWS CodeBuild), faz o build da imagem Docker e a envia para o Amazon ECR.
4.  **Execução Remota:** A action executa um comando no AWS SSM, apontando para a instância EC2 de destino.
5.  **Deploy Script:** O script de deploy na EC2 executa a lógica Blue/Green:
    * Busca secrets no AWS Secrets Manager.
    * Inicia um novo container ("Green") em uma porta secundária.
    * Valida a saúde do novo container.
    * Se saudável, o container antigo ("Blue") é removido.

```mermaid
graph TD
    A[Dev Push/Merge] --> B{GitHub Actions};
    B --> C[1. Login & Build Docker Image];
    C --> D[2. Push Image to Amazon ECR];
    D --> E[3. Trigger AWS SSM Run Command];
    subgraph "Instância EC2"
        E --> F[4. SSM Agent recebe o comando];
        F --> G{deploy-blue-green.sh};
        G --> H[Busca secrets no Secrets Manager];
        H --> I[Gera arquivo .env];
        I --> J[Docker Pull da nova imagem do ECR];
        J --> K[Inicia Container 'Green' em porta alternativa];
        K --> L[Healthcheck no Container 'Green'];
        L -- Sucesso --> M[Remove Container 'Blue'];
        L -- Falha --> N[Cancela o deploy e remove 'Green'];
    end

```

## ⚙️ Como Funciona

O processo de deploy é dividido em duas fases:

1.  **CI/CD (GitHub Actions):**
    * Realiza o login no Docker Hub (opcional, para imagens base) e no Amazon ECR.
    * Faz o build da imagem Docker da aplicação.
    * Adiciona uma tag à imagem (ex: o hash do commit).
    * Envia (push) a imagem para o repositório ECR.
    * Dispara o script `deploy-blue-green-ecr-to-ec2.sh` na instância EC2 de destino usando o AWS SSM Run Command.

2.  **Deploy Script na EC2 (Estratégia Blue/Green):**
    * O script recebe a nova tag da imagem como argumento.
    * **Blue (Container Atual):** Identifica o container em produção (`OLD_CONTAINER`).
    * **Green (Novo Container):**
        * Busca as variáveis de ambiente no AWS Secrets Manager e as salva em um arquivo `.env`.
        * Faz o `docker pull` da nova imagem do ECR.
        * Inicia o novo container (`NEW_CONTAINER`) em uma porta secundária (`PORT_NEW`), injetando as variáveis com `--env-file`.
    * **Validação (Healthcheck):** Realiza uma verificação de saúde (`curl`) no endpoint `HEALTHCHECK_PATH` do container "Green".
    * **Swap:** Se o healthcheck for bem-sucedido, o script remove o container "Blue" e o deploy é concluído. O "Green" agora é o novo "Blue".
    * **Rollback:** Se o healthcheck falhar, o script remove o container "Green" e o container "Blue" original continua operando normalmente.

---

## ✅ Pré-requisitos

Antes de começar, garanta que os seguintes recursos estão configurados.

### Na AWS

* **ECR:** Um repositório no Amazon ECR para armazenar suas imagens Docker.
* **EC2:** Uma instância EC2 com:
    * O **Agente SSM** instalado e em execução.
    * Uma **IAM Role** associada que permita as ações: `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, e `secretsmanager:GetSecretValue`.
* **Secrets Manager:** Um secret contendo as variáveis de ambiente da sua aplicação no formato JSON (chave/valor).
* **CodeBuild:** (Recomendado) Um projeto do AWS CodeBuild configurado com integração ao GitHub Actions para atuar como runner.

### No GitHub (Autenticação AWS)

Existem diferentes maneiras de autenticar o workflow com a AWS, dependendo do tipo de runner utilizado.

#### Método 1: AWS CodeBuild como Runner (Recomendado)
Este é o método mais simples e seguro.
1.  **Crie um Projeto no CodeBuild:** Configure um projeto no AWS CodeBuild e, na seção "Source", conecte-o ao seu repositório do GitHub. Isso o registrará como um runner para o GitHub Actions.
2.  **Configure a IAM Role do CodeBuild:** Atribua uma IAM Role ao projeto do CodeBuild com as permissões necessárias para o deploy (ex: `ecr:*` para login e push, e `ssm:SendCommand` para executar o deploy).
3.  **Nenhuma configuração de credencial é necessária no GitHub Actions.** O workflow herdará as permissões da IAM Role do CodeBuild automaticamente.

#### Método 2: OpenID Connect (OIDC) (Para Runners Padrão do GitHub)
Use este método se estiver usando os runners hospedados pelo próprio GitHub.
1.  **Configure o OIDC na AWS:** Crie um Provedor de Identidade (IdP) no IAM para o GitHub.
2.  **Crie uma IAM Role:** Crie uma role que o GitHub Actions possa assumir (`sts:AssumeRoleWithWebIdentity`).
3.  **Use a Role no Workflow:** Adicione o ARN da role no arquivo de workflow usando a action `aws-actions/configure-aws-credentials`.

#### Método 3: Chaves de Acesso (Alternativa)
* **Secrets do Repositório:** Configure `AWS_ACCESS_KEY_ID` e `AWS_SECRET_ACCESS_KEY` em `Settings > Secrets and variables > Actions` e use a action `aws-actions/configure-aws-credentials`.

### Na Instância EC2

* **Ferramentas Instaladas:** A instância precisa ter `docker`, `aws-cli`, `jq` e `curl` instalados e no `PATH` do sistema.

---

## 🛠️ Como Usar

1.  **Crie os arquivos** no seu repositório usando o conteúdo da seção abaixo.
2.  **Altere os placeholders** nos arquivos para corresponderem ao seu ambiente (ID da conta AWS, nome do repositório ECR, etc.).
3.  **Configure a autenticação** na AWS e no GitHub conforme os pré-requisitos.
4.  **Envie o script** `deploy-blue-green-ecr-to-ec2.sh` para sua instância EC2 no caminho que você definiu no workflow.
5.  **Faça o push** do seu código para a branch de deploy para iniciar o processo.

---

## 📄 Conteúdo Completo dos Arquivos

Aqui está o código-fonte que você pode usar para criar os arquivos do seu projeto.

### `templates/github-actions-deploy-template.yml`

```yaml
# Workflow do GitHub Actions para Deploy usando um Runner do AWS CodeBuild
name: Deploy Blue-Green to EC2 via CodeBuild

on:
  push:
    branches:
      - main # ⚠️ Substitua por: nome-da-branch-deploy

jobs:
  build-and-deploy:
    # ⚠️ Substitua pelo nome do runner do CodeBuild configurado no seu repositório
    runs-on: codebuild-meu-projeto-runner 
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4

    # NENHUMA ETAPA DE CREDENCIAIS É NECESSÁRIA AQUI
    # A autenticação é herdada da IAM Role do projeto CodeBuild.

    - name: Login to Docker Hub
      if: ${{ secrets.DOCKER_USERNAME != '' }}
      uses: docker/login-action@v3
      with:
        username: ${{ secrets.DOCKER_USERNAME }}
        password: ${{ secrets.DOCKER_PASSWORD }}

    - name: Login to Amazon ECR
      id: login-ecr
      uses: aws-actions/amazon-ecr-login@v2

    - name: Build, tag, and push image to Amazon ECR
      id: build-image
      env:
        ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
        ECR_REPOSITORY: meu-app # ⚠️ Substitua por: NOME-DO-REPOSITORIO
        IMAGE_TAG: ${{ github.sha }}
      run: |
        docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
        docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
        echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

    - name: Deploy to EC2 via SSM
      run: |
        # A REGIAO_AWS será obtida do ambiente do CodeBuild, mas pode ser especificada se necessário
        aws ssm send-command \
          --instance-ids "i-0123456789abcdef0" \
          --document-name "AWS-RunShellScript" \
          --parameters 'commands=["/home/ubuntu/deploy-blue-green-ecr-to-ec2.sh ${{ github.sha }}"]'
        # ⚠️ Substitua o ID da instância e o caminho do script
```

### `templates/deploy-blue-green-ecr-to-ec2.sh`

```bash
#!/bin/bash

set -euo pipefail

# ========== VARIÁVEIS CONFIGURÁVEIS ==========
SECRET_NAME="backend/development"    # Altere para o seu Secrets
ENV_FILE="/app/.env"                 # Altere para o seu PATH
OLD_CONTAINER="minha-aplicacao"
NEW_CONTAINER="minha-aplicacao-green"
IMAGE_NAME="123456789013.dkr.ecr.us-east-1.amazonaws.com/development/backend:latest"  # Altere para o seu ECR

APP_PORT=8080              # Porta da aplicação
GREEN_PORT=8081            # Porta temporária
HEALTH_ENDPOINT="/health"  # Healthcheck
CURL_TIMEOUT=15            # Timeout do healthcheck

# ========== CAPTURA ERROS ==========
handle_error() {
  local exit_code=$?
  local last_command="${BASH_COMMAND}"
  echo "❌ ERRO: O comando '$last_command' falhou com código $exit_code"
  echo "🛠️ Verifique os logs acima para mais detalhes."
  exit $exit_code
}
trap 'handle_error' ERR

deploy_start=$(date +%s)

echo "::group::🔧 Preparação Inicial"
echo "📌 Variáveis:"
echo " - Secret: $SECRET_NAME"
echo " - Imagem: $IMAGE_NAME"
echo " - Porta principal: $APP_PORT"
echo " - Porta green: $GREEN_PORT"
echo " - Endpoint: $HEALTH_ENDPOINT"
echo " - Timeout healthcheck: ${CURL_TIMEOUT}s"
echo "::endgroup::"

echo "::group::🔑 Autenticando no ECR..."
aws ecr get-login-password --region us-east-1 \                  
  | docker login --username AWS --password-stdin 671941044004.dkr.ecr.us-east-1.amazonaws.com    # Altere para o seu ECR     
echo "✅ Login bem-sucedido no ECR."
echo "::endgroup::"

echo "::group::📦 Baixando imagem do ECR..."
docker pull "$IMAGE_NAME"
echo "✅ Imagem '$IMAGE_NAME' baixada com sucesso."
echo "::endgroup::"

echo "::group::📄 Gerando .env com secrets..."
mkdir -p "$(dirname "$ENV_FILE")"
secret_json=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --region us-east-1 --output text)
echo "$secret_json" | jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' > "$ENV_FILE"
echo "✅ Secrets exportados para '$ENV_FILE'."
echo "::endgroup::"

echo "::group::🚀 Iniciando container green ($NEW_CONTAINER)..."
docker run -d \
  --env-file "$ENV_FILE" \
  -p "$GREEN_PORT:$APP_PORT" \
  --name "$NEW_CONTAINER" \
  "$IMAGE_NAME"
echo "✅ Container '$NEW_CONTAINER' rodando na porta $GREEN_PORT."
echo "::endgroup::"

echo "::group::🩺 Healthcheck do container green..."
start_time=$(date +%s)
while true; do
  if curl -fs "http://localhost:$GREEN_PORT$HEALTH_ENDPOINT" > /dev/null; then
    echo "✅ Healthcheck OK!"
    break
  fi

  current_time=$(date +%s)
  elapsed=$((current_time - start_time))

  if [ "$elapsed" -ge "$CURL_TIMEOUT" ]; then
    echo "❌ Healthcheck falhou após ${CURL_TIMEOUT}s."
    docker stop "$NEW_CONTAINER" && docker rm "$NEW_CONTAINER"
    echo "🧹 Container green removido."
    exit 1
  fi

  echo "⏳ Aguardando healthcheck... ($elapsed/${CURL_TIMEOUT}s)"
  sleep 1
done
echo "::endgroup::"

echo "::group::🔄 Removendo container antigo se existir..."
if docker ps -a --format '{{.Names}}' | grep -qw "$OLD_CONTAINER"; then
  docker stop "$OLD_CONTAINER"
  docker rm "$OLD_CONTAINER"
  echo "✅ Container antigo '$OLD_CONTAINER' removido."
else
  echo "ℹ️ Container antigo '$OLD_CONTAINER' não encontrado."
fi
echo "::endgroup::"

echo "::group::🚀 Promovendo container green para produção..."
docker stop "$NEW_CONTAINER"
docker rm "$NEW_CONTAINER"

docker run -d \
  --env-file "$ENV_FILE" \
  -p "$APP_PORT:$APP_PORT" \
  --name "$OLD_CONTAINER" \
  "$IMAGE_NAME"
echo "✅ Novo container '$OLD_CONTAINER' rodando na porta $APP_PORT."
echo "::endgroup::"

deploy_end=$(date +%s)
total_time=$((deploy_end - deploy_start))

echo "::group::✅ Finalização"
echo "🎉 Deploy Blue/Green concluído com sucesso!"
echo "⏱️ Tempo total: ${total_time}s"
echo "::endgroup::"

```

### `example/.env.sample`
```bash
# Exemplo de arquivo .env. Este arquivo é gerado automaticamente pelo script de deploy.
# Os valores são obtidos do AWS Secrets Manager.

DATABASE_URL="postgresql://user:password@host:port/database"
API_KEY_EXTERNA="abcdef123456"
JWT_SECRET="um-segredo-muito-forte-para-jwt"
NODE_ENV="production"
PORT="8080" # A porta que a aplicação escuta dentro do container
```

### `LICENSE`
```text
MIT License

Copyright (c) 2025 Fernando Januario

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 👨‍💻 Autor

Desenvolvido por **Fernando Januario**

* **Cargo:** DevOps
* **Paixão:** Automações e infraestrutura inteligente
* **LinkedIn:** [linkedin.com/in/fernando-januario](https://www.linkedin.com/in/fernando-januario)