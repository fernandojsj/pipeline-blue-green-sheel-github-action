#!/bin/bash

set -euo pipefail

# ========== VARIÁVEIS CONFIGURÁVEIS ==========
SECRET_NAME="backend/development"
ENV_FILE="/app/.env"
OLD_CONTAINER="minha-aplicacao"
NEW_CONTAINER="minha-aplicacao-green"
IMAGE_NAME="671941044004.dkr.ecr.us-east-1.amazonaws.com/development/backend:latest"

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
  | docker login --username AWS --password-stdin 671941044004.dkr.ecr.us-east-1.amazonaws.com
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
