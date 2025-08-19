#! /bin/sh
set -e
(set -o pipefail) 2>/dev/null || true

# Defaults
: "${S3_REGION:=us-east-1}"   # região obrigatória (AWS CLI não aceita "auto")
: "${S3_ENDPOINT:=}"          # endpoint S3 (ex.: https://usc1.contabostorage.com)
: "${SCHEDULE:=}"             # vazio = execução única

# Exporta envs AWS
export AWS_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${S3_REGION}"
export AWS_S3_ADDRESSING_STYLE=path

# Config extra (assinatura SigV4 para MinIO/Contabo)
[ "${S3_S3V4}" = "yes" ] && aws configure set default.s3.signature_version s3v4 >/dev/null 2>&1 || true

echo "[run.sh] endpoint=${S3_ENDPOINT:-<none>} region=${AWS_DEFAULT_REGION} schedule='${SCHEDULE}'"

# Se não tiver schedule → executa 1x e sai
if [ -z "${SCHEDULE}" ] || [ "${SCHEDULE}" = "**None**" ]; then
  echo "[run.sh] modo=run-once"
  exec /bin/sh backup.sh
else
  echo "[run.sh] modo=cron schedule=${SCHEDULE}"
  exec go-cron "$SCHEDULE" /bin/sh backup.sh
fi
