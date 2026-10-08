#!/bin/bash
# Migrates product photos from Supabase storage to the self-hosted storage shim.
# Usage: bash /tmp/migrate_photos.sh "<access_token>"
TOKEN="$1"
OK=0; FAIL=0
while read -r u; do
  [ -z "$u" ] && continue
  n="${u##*/productos/}"
  if curl -fsSL "$u" -o /tmp/mig_img 2>/dev/null \
     && curl -fsS -X POST "http://localhost:8080/storage/v1/object/productos/$n" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: image/jpeg" \
          --data-binary @/tmp/mig_img >/dev/null 2>&1; then
    echo "OK     $n"
    OK=$((OK+1))
  else
    echo "FALLO  $u"
    FAIL=$((FAIL+1))
  fi
done < /tmp/urls.txt
echo "Migradas: $OK | Fallidas: $FAIL"
