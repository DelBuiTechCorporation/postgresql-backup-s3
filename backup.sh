#! /bin/sh

# Fail fast
set -e
# pipefail não existe em todos /bin/sh; ignore se der erro
(set -o pipefail) 2>/dev/null || true

>&2 echo "-----"

# ===================[ Validações básicas ]===================
if [ "${S3_ACCESS_KEY_ID}" = "**None**" ] || [ -z "${S3_ACCESS_KEY_ID:-}" ]; then
  echo "You need to set the S3_ACCESS_KEY_ID environment variable."
  exit 1
fi
if [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ] || [ -z "${S3_SECRET_ACCESS_KEY:-}" ]; then
  echo "You need to set the S3_SECRET_ACCESS_KEY environment variable."
  exit 1
fi
if [ "${S3_BUCKET}" = "**None**" ] || [ -z "${S3_BUCKET:-}" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi
if [ "${POSTGRES_DATABASE}" = "**None**" ] || [ -z "${POSTGRES_DATABASE:-}" ]; then
  echo "You need to set the POSTGRES_DATABASE environment variable."
  exit 1
fi

# Auto-link antigo (mantido por compatibilidade)
if [ "${POSTGRES_HOST}" = "**None**" ] || [ -z "${POSTGRES_HOST:-}" ]; then
  if [ -n "${POSTGRES_PORT_5432_TCP_ADDR:-}" ]; then
    POSTGRES_HOST="$POSTGRES_PORT_5432_TCP_ADDR"
    POSTGRES_PORT="$POSTGRES_PORT_5432_TCP_PORT"
  else
    echo "You need to set the POSTGRES_HOST environment variable."
    exit 1
  fi
fi
if [ "${POSTGRES_USER}" = "**None**" ] || [ -z "${POSTGRES_USER:-}" ]; then
  echo "You need to set the POSTGRES_USER environment variable."
  exit 1
fi
if [ "${POSTGRES_PASSWORD}" = "**None**" ] || [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "You need to set the POSTGRES_PASSWORD environment variable."
  exit 1
fi

# ===================[ AWS / S3 ]===================
# Endpoint (MinIO/Contabo etc.)
if [ "${S3_ENDPOINT}" = "**None**" ] || [ -z "${S3_ENDPOINT:-}" ]; then
  AWS_ARGS=""
else
  AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
fi

# Região válida p/ assinatura SigV4 (não use "auto")
if [ "${S3_REGION}" = "**None**" ] || [ -z "${S3_REGION:-}" ]; then
  S3_REGION="us-east-1"
fi

# Exporta credenciais/ajustes
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
# MinIO/Contabo → path-style é o mais seguro
export AWS_S3_ADDRESSING_STYLE=path
# Alguns ambientes antigos exigiam forçar SigV4; awscli v2 já usa por padrão
# if [ "${S3_S3V4:-}" = "yes" ]; then export AWS_SIGNATURE_VERSION=4; fi

# ===================[ Postgres ]===================
export PGPASSWORD="$POSTGRES_PASSWORD"
: "${POSTGRES_PORT:=5432}"
: "${POSTGRES_EXTRA_OPTS:=}"
POSTGRES_HOST_OPTS="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER $POSTGRES_EXTRA_OPTS"

# ===================[ Opções adicionais ]===================
# Excluir bancos ao usar 'all' (espaço ou vírgula separados)
: "${EXCLUDE_DATABASES:=template0,template1,postgres}"
# Comando de compressão para texto (ignorado no -Fc)
: "${COMPRESSION_CMD:=gzip}"
: "${DECOMPRESSION_CMD:=gunzip -c}"
# Dump custom (-Fc) quando POSTGRES_DATABASE != all
: "${USE_CUSTOM_FORMAT:=no}"
# Paralelismo de restore (somente usado por quem for restaurar com pg_restore)
: "${PARALLEL_JOBS:=1}"
# Retenção, schedule etc. mantidos pelo wrapper externo (cron/supercronic)
# Opcional: criptografia
: "${ENCRYPTION_PASSWORD:=**None**}"
# (novo) Dump de globais (roles/tablespaces) além dos bancos
: "${DUMP_GLOBALS:=yes}"

UTC_NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ===================[ Helpers ]===================
upload_stdin() {
  # $1 = dest key (ex.: s3://bucket/prefix/file)
  aws $AWS_ARGS s3 cp - "$1"
}

upload_file() {
  # $1 = src file, $2 = dest key
  aws $AWS_ARGS s3 cp "$1" "$2"
}

encrypt_if_needed() {
  # $1 = src file -> echo outputs final filename (maybe .enc)
  if [ "${ENCRYPTION_PASSWORD}" != "**None**" ] && [ -n "${ENCRYPTION_PASSWORD}" ]; then
    >&2 echo "Encrypting $1"
    openssl enc -aes-256-cbc -pbkdf2 -salt -in "$1" -out "${1}.enc" -k "$ENCRYPTION_PASSWORD"
    if [ $? -ne 0 ]; then
      >&2 echo "Error encrypting $1"
      exit 1
    fi
    rm -f "$1"
    echo "${1}.enc"
  else
    echo "$1"
  fi
}

mk_key() {
  # monta s3://bucket/prefix/file garantindo que prefix pode estar vazio
  # $1 = filename (sem caminho)
  if [ -z "${S3_PREFIX:-}" ] || [ "${S3_PREFIX}" = "**None**" ]; then
    echo "s3://${S3_BUCKET}/${1}"
  else
    echo "s3://${S3_BUCKET}/${S3_PREFIX}/${1}"
  fi
}

list_databases() {
  # Lista bancos conectáveis, aplicando exclusões
  EXC_SQL=""
  # aceita ambos: vírgula ou espaço
  echo "$EXCLUDE_DATABASES" | tr ',' ' ' | while read ex; do
    ex_trim=$(echo "$ex" | xargs)
    if [ -n "$ex_trim" ]; then
      if [ -z "$EXC_SQL" ]; then
        EXC_SQL="'$ex_trim'"
      else
        EXC_SQL="$EXC_SQL,'$ex_trim'"
      fi
    fi
  done
  if [ -z "$EXC_SQL" ]; then
    EXC_SQL="'template0','template1'"
  fi

  psql $POSTGRES_HOST_OPTS -At -c "
    SELECT datname
    FROM pg_database
    WHERE datallowconn
      AND datname NOT IN (${EXC_SQL})
    ORDER BY datname;
  "
}

# ===================[ Execução ]===================
echo "Starting backup from ${POSTGRES_HOST}:${POSTGRES_PORT}"

# 0) Preflight simples: listar bucket
aws $AWS_ARGS s3 ls "s3://${S3_BUCKET}/" >/dev/null 2>&1 || {
  echo "Cannot list bucket s3://${S3_BUCKET}. Check credentials/endpoint/permissions."
  exit 2
}

# 1) Globais (opcional) — sempre texto + compressão
if [ "${DUMP_GLOBALS}" = "yes" ]; then
  GLOBALS_FILE="globals_${UTC_NOW}.sql.gz"
  echo "Creating globals dump (roles/tablespaces)…"
  # stream para arquivo local (pequeno) e envia
  # (poderia stream direto, mas manter compat com criptografia por arquivo)
  sh -c "pg_dumpall --globals-only $POSTGRES_HOST_OPTS | $COMPRESSION_CMD > \"$GLOBALS_FILE\""
  # criptografia opcional
  FINAL_GLOB="$(encrypt_if_needed "$GLOBALS_FILE")"
  DEST_GLOB="$(mk_key "$(basename "$FINAL_GLOB")")"
  echo "Uploading globals to ${DEST_GLOB}"
  upload_file "$FINAL_GLOB" "$DEST_GLOB" || exit 2
  rm -f "$FINAL_GLOB"
fi

# 2) Dump de bancos
if [ "${POSTGRES_DATABASE}" = "all" ]; then
  echo "Enumerating databases…"
  DBS="$(list_databases)"

  # Se por algum motivo vier vazio, evita erro
  if [ -z "$DBS" ]; then
    echo "No databases found to backup."
    exit 0
  fi

  for DB in $DBS; do
    if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
      SRC_FILE="${DB}.dump"
      DEST_FILE="${DB}_${UTC_NOW}.dump"
      echo "Creating custom dump (-Fc) of ${DB}…"
      pg_dump -Fc $POSTGRES_HOST_OPTS "$DB" > "$SRC_FILE"
    else
      SRC_FILE="${DB}.sql.gz"
      DEST_FILE="${DB}_${UTC_NOW}.sql.gz"
      echo "Creating SQL dump of ${DB}…"
      sh -c "pg_dump $POSTGRES_HOST_OPTS \"$DB\" | $COMPRESSION_CMD > \"$SRC_FILE\""
    fi

    # Criptografia por arquivo (se habilitada)
    FINAL_SRC="$(encrypt_if_needed "$SRC_FILE")"
    DEST_KEY="$(mk_key "$DEST_FILE$( [ "$FINAL_SRC" != "$SRC_FILE" ] && echo .enc )")"

    echo "Uploading ${DEST_KEY}"
    upload_file "$FINAL_SRC" "$DEST_KEY" || exit 2
    rm -f "$FINAL_SRC"
  done

else
  # Somente um banco (comportamento antigo)
  if [ "$USE_CUSTOM_FORMAT" = "yes" ]; then
    SRC_FILE="dump.dump"
    DEST_FILE="${POSTGRES_DATABASE}_${UTC_NOW}.dump"
    echo "Creating custom dump (-Fc) of ${POSTGRES_DATABASE}…"
    pg_dump -Fc $POSTGRES_HOST_OPTS "$POSTGRES_DATABASE" > "$SRC_FILE"
  else
    SRC_FILE="dump.sql.gz"
    DEST_FILE="${POSTGRES_DATABASE}_${UTC_NOW}.sql.gz"
    echo "Creating SQL dump of ${POSTGRES_DATABASE}…"
    sh -c "pg_dump $POSTGRES_HOST_OPTS \"$POSTGRES_DATABASE\" | $COMPRESSION_CMD > \"$SRC_FILE\""
  fi

  FINAL_SRC="$(encrypt_if_needed "$SRC_FILE")"
  DEST_KEY="$(mk_key "$DEST_FILE$( [ "$FINAL_SRC" != "$SRC_FILE" ] && echo .enc )")"

  echo "Uploading ${DEST_KEY}"
  upload_file "$FINAL_SRC" "$DEST_KEY" || exit 2
  rm -f "$FINAL_SRC"
fi

# 3) Retenção (apaga objetos antigos em S3_PREFIX)
if [ "${DELETE_OLDER_THAN}" != "**None**" ] && [ -n "${DELETE_OLDER_THAN:-}" ]; then
  >&2 echo "Checking for files older than ${DELETE_OLDER_THAN}"
  # lista somente arquivos (ignora PRE de diretórios "lógicos")
  aws $AWS_ARGS s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" | grep " PRE " -v | while read -r line; do
    fileName=$(echo "$line" | awk '{print $4}')
    created=$(echo "$line" | awk '{print $1" "$2}')
    created_epoch=$(date -d "$created" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$created" "+%s" 2>/dev/null || echo 0)
    older_than_epoch=$(date -d "$DELETE_OLDER_THAN" +%s 2>/dev/null || echo 0)
    if [ -n "$fileName" ] && [ "$created_epoch" -lt "$older_than_epoch" ]; then
      >&2 echo "DELETING ${fileName}"
      aws $AWS_ARGS s3 rm "s3://$S3_BUCKET/$S3_PREFIX/$fileName" || true
    else
      >&2 echo "${fileName} not older than ${DELETE_OLDER_THAN}"
    fi
  done
fi

echo "SQL backup finished"
>&2 echo "-----"
