#!/bin/bash
# Tier 2 cutover — rotate JWT_SECRET + anon/service keys on hp-server
# Prereq: image pedidos:v2 already loaded on this server
set -euo pipefail
SRV="$HOME/server"
ENVF="$SRV/.env"
OVR="$SRV/docker-compose.override.yml"
TS=$(date +%Y%m%d-%H%M)

source "$HOME/tier2-secrets.env"

docker image inspect pedidos:v2 >/dev/null 2>&1 || { echo "ERROR: pedidos:v2 no existe — cargar la imagen primero"; exit 1; }

cp "$ENVF" "$ENVF.bak-tier2-$TS"
cp "$SRV/docker-compose.yml" "$SRV/docker-compose.yml.bak-tier2-$TS"
cp "$OVR" "$OVR.bak-tier2-$TS"
echo "backups: *.bak-tier2-$TS"

sed -i -E "s#^JWT_SECRET=.*#JWT_SECRET=$NEW_JWT_SECRET#" "$ENVF"
sed -i -E "s#^SERVICE_KEY=.*#SERVICE_KEY=$NEW_SERVICE_KEY#" "$ENVF"
sed -i -E "s#^ANON_KEY=.*#ANON_KEY=$NEW_ANON_KEY#" "$ENVF"
if grep -q "^SUPABASE_SERVICE_KEY=" "$ENVF"; then
  sed -i -E "s#^SUPABASE_SERVICE_KEY=.*#SUPABASE_SERVICE_KEY=$NEW_SERVICE_KEY#" "$ENVF"
else
  echo "SUPABASE_SERVICE_KEY=$NEW_SERVICE_KEY" >> "$ENVF"
fi

sed -i -E "s#^( *image: )pedidos:latest#\1pedidos:v2#" "$OVR"

cd "$SRV" && docker compose up -d

sleep 5
echo "--- verificacion ---"
curl -s -o /dev/null -w "gotrue health: %{http_code}\n" http://localhost:8080/auth/v1/health
curl -s -o /dev/null -w "postgrest con clave nueva: %{http_code}\n" -H "apikey: $NEW_ANON_KEY" -H "Authorization: Bearer $NEW_ANON_KEY" "http://localhost:8080/rest/v1/productos?limit=1"
curl -s -o /dev/null -w "storage publico: %{http_code}\n" "http://localhost:8080/storage/v1/object/public/productos/7910-1879.png"
curl -s -o /dev/null -w "app via caddy: %{http_code}\n" "http://localhost:8080/"
echo "--- fin verificacion ---"
rm -f "$HOME/tier2-secrets.env"
echo "archivo de secretos eliminado del server"
