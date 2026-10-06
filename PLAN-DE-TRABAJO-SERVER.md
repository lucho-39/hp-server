# Plan de trabajo — Servidor self-hosted (HP Compaq 6530b)

**Actualizado:** 2026-10-04
**Objetivo:** transformar una laptop vieja en un servidor backend self-hosted 24/7, sin depender de la nube.
**Red:** IP del server en la LAN: `<IP-del-server>` (DHCP — reservarla fija en el router). SSH: `ssh <usuario>@<IP-del-server>`

## Objetivo original (las 5 capacidades)

1. Base de datos **PostgreSQL**
2. **APIs automáticas**
3. **Autenticación** de usuarios
4. **Almacenamiento** de archivos
5. **Funciones serverless**

## Hardware

| Componente | Detalle |
|---|---|
| Equipo | HP Compaq 6530b (vc178et#abu) |
| CPU | Intel Core 2 Duo P8700 — 2 núcleos, sin EPT |
| RAM | 4 GB DDR2 (3.7 GiB visibles; la GPU reserva ~300 MB) |
| Disco | SSD Kingston SV300S37A240G (240 GB) |
| GPU | Mobile Intel 4 Series (GMA 4500MHD) |

**Notas:**
- Docker **no** necesita EPT ni VT-x. Eso solo afecta a máquinas virtuales.
- El equipo soporta hasta **8 GB** (2x4 GB DDR2-800): la mejor inversión posible del proyecto.
- La GPU funciona bien con **Xorg** (XFCE/LXDE). Con **Wayland** (GNOME) falla.

## Leyenda

- ✅ hecho
- 🔧 en curso
- ⬜ pendiente
- ⚠️ con desvío

---

## Estado actual

**Fases 1-3 COMPLETAS. Fase 4: 5 de 5 capacidades andando y verificadas.**

### Servicios de la plataforma (`~/server/docker-compose.yml` + `.env`)

| Servicio | Versión | Puerto (solo localhost) | Estado |
|---|---|---|---|
| postgres | 16.15 | 5432 | ✅ |
| postgrest | 12.2.0 | 3000 | ✅ API con JWT obligatorio |
| gotrue | v2.171.0 | 9999 | ✅ signup/login/JWT verificados |
| storage nativo | tabla `files` en PG | vía PostgREST | ✅ upload/download verificados |
| edge-runtime | v1.76.2 | 9000 | ✅ función main verificada |

- **Auth:** GoTrue firma JWT (HS256, `JWT_SECRET` compartido en `.env`); PostgREST verifica y hace `SET ROLE authenticated` → RLS por fila (`anon`/`authenticated`/`authenticator`).
- **Storage:** patrón RPC binario (`upload_binary` octet-stream / `download_file` con dominio-named), dueño automático por `auth.uid()`, tamaños reales por columna generada, rename con permiso por columnas.
- **Desvíos aceptados:** MinIO/Kong/Caddy **fuera del stack** (rate limit de registros + simplicidad: binding a 127.0.0.1 + túneles SSH).
- **Serverless:** el edge-runtime NECESITA `command: ["start", "--main-service", "/home/deno/functions/main"]` (sin subcomando imprime help y hace crash loop). Funciones en `~/server/functions/<nombre>/index.ts`; override en `docker-compose.override.yml`. `VERIFY_JWT=false` por ahora.

### Resolución de los problemas acumulados

| Problema | Causa raíz | Estado |
|---|---|---|
| GNOME instalado sin pedirlo | El ISO era `debian-live-12.0.0-amd64-gnome.iso` (live, NO la netinst) | ✅ Diagnosticado |
| `raspi-firmware` en una HP | Arrastrado por la imagen live | ✅ Purgado + hooks borrados |
| Kernel sin configurar (dpkg roto) | Hook huérfano en `/etc/kernel/postinst.d/z50-raspi-firmware` | ✅ `6.1.0-53` configurado |
| "No arrancaba la gráfica" | GNOME/Wayland sobre GMA 4500MHD | ✅ XFCE con Xorg |
| No tenés sudo | El instalador solo agrega a `sudo` si la clave de root queda vacía | ✅ `usermod -aG sudo <usuario>` |
| El reboot se cuelga (3 de 3) | Firmware ACPI de 2009 (`\_SB.PCI0.GFX0._DOD` roto) | ✅ **Workaround:** `poweroff` + prender |

### Datos operativos

- **Hardware verificado:** SSD sano (SMART PASSED, 0 sectores reasignados), temperatura 30-32°C, sin errores MCE/ATA. **El hardware es apto.**
- **Procedimiento de reinicio (documento oficial):** `sudo poweroff` → esperar 10 s → botón de encendido. NO usar `reboot` (se cuelga en el firmware).
- **Kernel:** `6.1.0-53-amd64` (instalación limpia con netinst).
- **Swap:** 8 GiB en partición `/dev/sda1` (sin swapfile — la reinstalación limpia lo reemplazó).
- **Lección del proyecto:** *cuando algo se comporta raro de forma consistente, preguntate qué hay dentro de la base que estás usando.* El `raspi-firmware` era la huella de la imagen equivocada. Para reinstalar: **siempre la netinst** (`https://www.debian.org/CD/netinst/`), nunca las de `/CD/live/`.

---

## FASE 1 — Debian base ✅

- [x] **1.1** Instalación Debian (⚠️ era la live de GNOME, no la netinst)
- [x] **1.2** Particionado — ⚠️ swap de 974 Mi en lugar de 8 GiB
- [x] **1.3** XFCE instalado con `lightdm` (GNOME sigue como lastre, no arranca)
- [x] **1.4** Swapfile de 6 GB
- [x] **1.5** Arranque a consola (`multi-user.target`)

**Resultado:** swap total ~7 GiB · boots a consola (~506 MB RAM usados) · XFCE disponible vía `isolate graphical.target` · `reboot` reemplazado por `poweroff`+prender.

### 1.3 GNOME → XFCE

Desde una TTY (`Ctrl+Alt+F3`), **nunca** desde una terminal de GNOME:

```bash
sudo systemctl set-default multi-user.target
sudo systemctl isolate multi-user.target

# Simulación (no borra nada): mirar el numero de "to remove"
sudo apt purge --auto-remove -s task-desktop task-gnome-desktop 2>&1 | tail -4

# Purge real + XFCE en el mismo paso
sudo apt-mark manual sudo openssh-server
sudo apt purge --auto-remove task-desktop task-gnome-desktop
sudo apt autoremove --purge
sudo apt install -y task-xfce-desktop
```

### 1.4 Swapfile (con guarda)

```bash
if [ ! -e /swapfile ]; then
  sudo fallocate -l 6G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
  echo "OJO: /swapfile ya existe - NO tocar"
fi
sudo swapon --show
```

### 1.5 Modo servidor / escritorio bajo demanda

```bash
# Arrancar en consola (persistente)
sudo systemctl set-default multi-user.target

# Prender el escritorio AHORA (temporal)
sudo systemctl isolate graphical.target

# Volver a consola (temporal, libera RAM)
sudo systemctl isolate multi-user.target

# Dejarlo grafico siempre
sudo systemctl set-default graphical.target
```

> **NO** usar `systemctl disable lightdm`: rompe el `isolate graphical.target`.

---

## FASE 2 — Base del servidor ✅ (reinstalación limpia con netinst)

- [x] **2.1** Sistema al día (349 paquetes, base limpia)
- [x] **2.2** Hostname definitivo: `hp-server`
- [x] **2.3** Tapa: no suspender (drop-in logind + targets masked)
- [ ] **2.4** SSH con llave, sin password (⬜ pendiente: sigue con password)
- [x] **2.5** swappiness 10 + vfs_cache_pressure 50
- [x] **2.6** TRIM (`fstrim.timer`) — noatime en fstab pendiente de verificar
- [x] **2.7** Journal capado a 200 MB
- [x] **2.8** Docker Engine + Compose + daemon.json (logs 10m x3, live-restore)

### 2.3 Tapa

```bash
sudo mkdir -p /etc/systemd/logind.conf.d
sudo tee /etc/systemd/logind.conf.d/10-no-suspend.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
EOF

sudo systemctl restart systemd-logind
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 2.5 swappiness

```bash
sudo tee /etc/sysctl.d/99-swap-ssd.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sudo sysctl --system
cat /proc/sys/vm/swappiness      # debe devolver 10
```

### 2.6 TRIM + noatime

```bash
sudo systemctl enable --now fstrim.timer
# editar /etc/fstab: agregar noatime a las opciones de /
sudo mount -o remount /
```

### 2.7 Journal

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
sudo systemctl restart systemd-journald
```

### 2.8 Docker

```bash
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo tee /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF

sudo systemctl enable --now docker
sudo docker run --rm hello-world
```

---

## FASE 3 — Gestión visual ✅ (3.3 pendiente)

- [x] **3.1** Portainer CE (setup_token desde `docker logs portainer`; admin creado en 5 min o restart)
- [x] **3.2** Túnel SSH desde la PC (`ssh -L 9443:localhost:9443` → `https://localhost:9443`)
- [ ] **3.3** VS Code Remote-SSH + extensión Docker

```bash
sudo docker volume create portainer_data

sudo docker run -d \
  --name portainer --restart=always \
  -p 127.0.0.1:9443:9443 \
  -p 127.0.0.1:8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
```

Desde la PC Windows:

```
ssh -L 9443:localhost:9443 <usuario>@<IP-del-server>
```

Y en el navegador de la PC: `https://localhost:9443`

---

## FASE 4 — La plataforma 🔧 (5/5 capacidades andando — quedan firewall, Caddy, backups)

- [ ] **4.1** Firewall (`ufw`) — pendiente; hoy todo bindeado a 127.0.0.1 + túneles SSH
- [ ] **4.2** Caddy como único punto de entrada — DESVÍO: pospuesto (no necesario con túneles SSH)
- [x] **4.3** PostgreSQL 16.15 (mem 512M) — tuning fino pendiente
- [x] **4.4** PostgREST 12.2.0 (mem 128M) — JWT obligatorio, roles anon/authenticated/authenticator
- [x] **4.5** GoTrue v2.171.0 (mem 128M) — signup/login/JWT verificados
- [x] **4.6** Storage — DESVÍO: MinIO/Garage denegados por rate limit → **storage nativo en PG** (tabla `files` + RLS + RPC binario). Revisar S3 cuando los registros dejen de bloquear.
- [x] **4.7** Edge runtime Deno v1.76.2 (serverless) — función main verificada; VERIFY_JWT=false por ahora
- [x] **4.8** Límites de memoria vía `deploy.resources` en cada servicio
- [ ] **4.9** Backups pg_dump

**Presupuesto de RAM:** host ~600 MB → techo de ~2.8 GB para contenedores.

```yaml
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    mem_limit: 1g
    memswap_limit: 1280m      # 1g RAM + 256m swap: tope duro
    mem_reservation: 512m
```

**Fuera del stack:** Kong (lo reemplaza Caddy), Studio, Realtime, Analytics.

---

## FASE 5 — Operación ⬜

- [ ] **5.1** Monitoreo
- [ ] **5.2** Backups cifrados fuera del SSD
- [ ] **5.3** Actualizaciones de seguridad
- [ ] **5.4** Runbook de recuperación

---

## Reglas del proyecto

1. **El server hace RUN, no BUILD.** Se buildea en la PC y se transfiere.
2. **Inspeccionar antes de actuar** (`ls`, `lsblk`, `dpkg -l`) antes de cualquier comando que cree o borre.
3. **Un servicio por vez**, verificado antes de sumar el siguiente.
4. **Un backup en el mismo disco no es backup.**
5. Nunca `disable` el display manager: alcanza con `set-default multi-user.target`.

## Decisiones pendientes

- ~~IP del server en la LAN~~ → `<IP-del-server>` (reservarla fija en el router)
- ~~Hostname definitivo~~ → `hp-server`
- ¿Upgrade a 8 GB de RAM?
- ¿Migrar storage a S3 (MinIO/Garage) cuando los registros dejen de bloquear?

---

## Registro de problemas y soluciones

| Problema | Causa | Solución |
|---|---|---|
| `<usuario> is not in the sudoers file` | El instalador solo agrega a `sudo` si la clave de root queda vacía | `su -` → `usermod -aG sudo <usuario>` → relogin |
| Swap de solo ~1 GB | Se usó el particionado guiado | Swapfile de 6-8 GB |
| GNOME instalado sin querer | "Debian desktop environment" marcado sin DE específico → GNOME por defecto | Marcar XFCE explícitamente, o purge + `task-xfce-desktop` |
| `fallocate: fichero de texto está ocupado` | `/swapfile` ya existía y estaba activo como swap | Verificar con `ls -lh` antes de crear |
| `swapon: orden no encontrada` | `/sbin` no está en el PATH del usuario | Usar `sudo swapon` |
| No arranca la gráfica | GNOME/Wayland sobre GMA 4500MHD | Usar XFCE (Xorg) |
| Arranca en escritorio sin querer | DM habilitado vía `graphical.target.wants` | `systemctl set-default multi-user.target` |
| `apt purge` mata la sesión a mitad | El purge detiene el display manager desde una terminal gráfica | Correrlo desde una TTY (`Ctrl+Alt+F3`) |
| GoTrue: `required key API_EXTERNAL_URL missing value` | envconfig genera `GOTRUE_API_API_EXTERNAL_URL` y como fallback busca el nombre pelado `API_EXTERNAL_URL` | Usar `API_EXTERNAL_URL` sin prefijo (como el compose oficial de Supabase) |
| GoTrue: `schema "auth" does not exist` | Postgres pelado no trae el esquema `auth` | `CREATE SCHEMA auth AUTHORIZATION platform;` |
| GoTrue: `role "postgres" does not exist` | Las migraciones hacen `grant ... to postgres` | `CREATE ROLE postgres NOLOGIN;` |
| GoTrue: `type "auth.factor_type" does not exist` | Migración crea enums sin esquema (caen en `public`); luego se buscan en `auth` | `?search_path=auth,public` en `GOTRUE_DB_DATABASE_URL` + wipe del estado a medio migrar (drop schema auth, enums de public, `public.schema_migrations`) |
| PostgREST: `no matches found in the schema cache` | PostgREST cachea el esquema; en PG pelado nadie notifica el DDL | `NOTIFY pgrst, 'reload schema';` después de cada DDL |
| RPC binario: `function upload_binary() does not exist` | El parámetro bytea debe ir SIN nombre para que el body octet-stream lo llene | `CREATE FUNCTION upload_binary(bytea) ... VALUES (..., $1) ...` |
| Descarga binaria de tabla: HTTP 406 | En PostgREST v12 la salida cruda es solo por funciones | Dominio `"application/octet-stream"` + función que lo devuelve |
| `42501 permission denied` con config aparentemente correcta | El JWT vence a la hora (3600 s) y el pedido corre como `anon` | Renovar el TOKEN antes de diagnosticar |
| URI de PostgREST rota | `@` en el password rompe el parseo | Passwords sin `@` `:` `/` |
| Paste corrupto en SSH (comandos duplicados/cortados) | Pegar bloques largos por SSH los corrompe | Pegar de una; verificar con `grep`/`docker compose config` antes de ejecutar; considerar `scp` para archivos |
