#!/bin/bash

set -e  # Para o script se qualquer comando falhar

# 🔧 CONFIGURAÇÕES – Substitua os valores abaixo conforme seu ambiente
SECRET_NAME="CAMINHO/DO/SECRET_NO_SECRETS_MANAGER"        # Ex: backend/development
ENV_FILE="/caminho/para/.env"                             # Ex: /app/.env
OLD_CONTAINER="nome-do-container-principal"               # Ex: minha-aplicacao
NEW_CONTAINER="nome-do-container-novo"                    # Ex: minha-aplicacao-green
IMAGE_NAME="CONTA.dkr.ecr.REGIAO.amazonaws.com/repo:tag"  # Ex: 123456789012.dkr.ecr.us-east-1.amazonaws.com/backend:latest
PORT_OLD=8080
PORT_NEW=8081
HEALTHCHECK_PATH="/health"                                # Caminho de verificação de saúde
HEALTHCHECK_TIMEOUT=15                                    # Tempo máximo de espera (segundos)
AWS_REGION="REGIAO"                                       # Ex: us-east-1

echo "🔑 Autenticando no ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$(echo "$IMAGE_NAME" | cut -d'/' -f1)"

echo "📦 Baixando última imagem do ECR..."
docker pull "$IMAGE_NAME"

echo "📄 Gerando .env com secrets do Secrets Manager..."
secret_json=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --region "$AWS_REGION" --output text)
mkdir -p "$(dirname "$ENV_FILE")"
echo "$secret_json" | jq -r 'to_entries|map("\(.key)=\(.value)")|.[]' > "$ENV_FILE"

echo "🚀 Subindo novo container (green) na porta $PORT_NEW..."
docker run -d \
  --env-file "$ENV_FILE" \
  -p "$PORT_NEW:$PORT_OLD" \
  --name "$NEW_CONTAINER" \
  "$IMAGE_NAME"

echo "🩺 Aguardando healthcheck no novo container por até $HEALTHCHECK_TIMEOUT segundos..."
start_time=$(date +%s)
while true; do
  if ! curl -fs "http://localhost:$PORT_NEW$HEALTHCHECK_PATH" > /dev/null; then
    echo "❌ Healthcheck falhou. Removendo container green."
    docker stop "$NEW_CONTAINER" && docker rm "$NEW_CONTAINER"
    exit 1
  fi

  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  if [ "$elapsed" -ge "$HEALTHCHECK_TIMEOUT" ]; then
    break
  fi

  sleep 1
done

echo "✅ Novo container saudável. Substituindo o antigo..."

if docker ps -a --format '{{.Names}}' | grep -qw "$OLD_CONTAINER"; then
  docker stop "$OLD_CONTAINER" && docker rm "$OLD_CONTAINER"
fi

docker stop "$NEW_CONTAINER" && docker rm "$NEW_CONTAINER"

echo "🚀 Subindo container principal na porta $PORT_OLD..."
docker run -d \
  --env-file "$ENV_FILE" \
  -p "$PORT_OLD:$PORT_OLD" \
  --name "$OLD_CONTAINER" \
  "$IMAGE_NAME"

echo "🎉 Deploy Blue/Green finalizado com sucesso!"
