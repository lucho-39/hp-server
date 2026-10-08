#!/bin/bash
# Rotacion de contrasenas de PostgreSQL (Tier 1) para hp-server.
# Uso: bash rotate-db-passwords.sh dry   -> solo muestra que haria (no cambia nada)
#      bash rotate-db-passwords.sh go    -> ejecuta la rotacion
set -uo pipefail
MODE="${1:-dry}"
SRV="$HOME/server"
ENVF="$SRV/.env"
TS=$(date +%Y%m%d-%H%M)
NEW_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)

echo "### 1. Archivos de configuracion"
ls -1 "$SRV"/.env "$SRV"/*.yml 2>/dev/null

echo "### 2. Lineas con passwords/URLs (nombres visibles, valores enmascarados)"
for f in "$SRV"/*.yml "$ENVF"; do
  echo "  [$f]"
  grep -n "PASSWORD\|DATABASE_URL\|DB_URI" "$f" 2>/dev/null | sed -E 's/^([0-9]+):([^=:]+)([=:]).*/\1: \2\3***/'
done

echo "### 3. Roles con login en PostgreSQL"
docker exec postgres psql -U platform -d platform -tAc "SELECT rolname FROM pg_roles WHERE rolcanlogin ORDER BY 1" 2>/dev/null || echo "(no se pudieron listar roles)"

echo "### 4. URLs de conexion (contrasenas enmascaradas)"
for f in "$SRV"/*.yml "$ENVF"; do
  grep -h "postgres://" "$f" 2>/dev/null | sed -E 's#(postgres://[^:]+:)[^@]+@#\1***@#' | sed "s#^#  [$f] #"
done

if [ "$MODE" != "go" ]; then
  echo "### DRY-RUN: no se cambio nada."
  echo "### Para aplicar: bash ~/server/scripts/rotate-db-passwords.sh go"
  exit 0
fi

echo "### APLICANDO ROTACION"
for f in "$SRV"/.env "$SRV"/*.yml; do cp "$f" "$f.bak-$TS"; done
echo "Backups creados: *.bak-$TS"

sed -i -E "s#^POSTGRES_PASSWORD=.*#POSTGRES_PASSWORD=$NEW_PW#" "$ENVF"
for f in "$SRV"/*.yml; do
  sed -i -E "s#^( *POSTGRES_PASSWORD:).*#\1 $NEW_PW#" "$f"
done
for f in "$SRV"/*.yml "$ENVF"; do
  sed -i -E "s#(postgres://[^:]+:)[^@]+@#\1$NEW_PW@#g" "$f"
done

USERS=$(grep -h "postgres://" "$SRV"/*.yml "$ENVF" 2>/dev/null | sed -E 's#.*postgres://([^:]+):.*#\1#' | sort -u)
for u in postgres $USERS; do
  EXIST=$(docker exec postgres psql -U platform -d platform -tAc "SELECT 1 FROM pg_roles WHERE rolname='$u'")
  if [ "$EXIST" = "1" ]; then
    docker exec postgres psql -U platform -d platform -v ON_ERROR_STOP=1 -c "ALTER ROLE \"$u\" PASSWORD '$NEW_PW';"
  else
    echo "(rol $u no existe - omitido)"
  fi
done
echo "Roles actualizados: $USERS"

cd "$SRV" && docker compose up -d
echo "### Verificacion"
curl -s -o /dev/null -w "gotrue health: %{http_code}\n" http://localhost:8080/auth/v1/health
curl -s -o /dev/null -w "postgrest root: %{http_code}\n" -H "apikey: $(sed -n 's/^ANON_KEY=//p' "$ENVF")" http://localhost:8080/rest/v1/
echo "### NUEVA CONTRASENA DE POSTGRES (guardala en lugar seguro):"
echo "$NEW_PW"
echo "### Listo. Para restaurar: cp <archivo>.bak-$TS <archivo> (en $SRV) y docker compose up -d"
