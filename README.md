# hp-server — Plataforma backend self-hosted en una laptop del 2009

Una laptop **HP Compaq 6530b de 2009** (4 GB de RAM) transformada en servidor backend 24/7, **sin depender de la nube**: PostgreSQL, APIs automáticas (PostgREST), autenticación (GoTrue), storage de archivos y funciones serverless (edge-runtime). Este README documenta **todos los pasos**, desde el instalador de Debian hasta el acceso al dashboard desde el celular.

> Todos los valores personales (usuario, IP, contraseñas, tailnet) van como **placeholders** (`<usuario>`, `<IP-del-server>`, …). Los secretos reales viven solo en `.env`, que está en `.gitignore`.

---

## Hardware usado

| Componente | Detalle |
|---|---|
| Equipo | HP Compaq 6530b (`vc178et#abu`) — laptop de 2009 |
| CPU | Intel Core 2 Duo P8700 — 2 núcleos, **sin EPT** |
| RAM | 4 GB DDR2-800 (el equipo soporta hasta 8 GB = mejor upgrade posible) |
| Disco | SSD Kingston SV300S37A240G, 240 GB |
| GPU | Mobile Intel 4 Series (GMA 4500MHD) — funciona con **Xorg**, falla con Wayland |
| Rol | Servidor 24/7 sin pantalla ni teclado — se maneja 100% por SSH |

Notas críticas del hardware:

- **Docker no necesita EPT ni VT-x** — eso solo afecta a máquinas virtuales.
- **`reboot` se cuelga** (firmware ACPI de 2009 roto). Procedimiento oficial de reinicio: `sudo poweroff` → esperar 10 s → botón de encendido.
- El SSD está sano (SMART PASSED, 0 sectores reasignados, 30-32 °C).

---

## Asistencia de IA

Este proyecto se construyó con asistencia de inteligencia artificial, **siempre con supervisión y verificación humana** en cada paso:

| IA | Para qué |
|---|---|
| **Gentle AI** | Arquitectura y planificación: plan de trabajo completo (`PLAN-DE-TRABAJO-SERVER.md`), selección del stack, diagnóstico de problemas |
| **OpenCode + mimo-v2.6-flash-free** | Asistencia operativa paso a paso: comandos, diagnóstico, iteración sobre el servidor, accesos remotos (SSH/Tailscale/Cockpit) y la escritura de este README |

Regla que se mantuvo durante todo el proyecto: **la IA propone, el humano ejecuta y valida**. Cada comando se corrió en el equipo y se verificó su resultado antes de darlo por bueno. Nada de lo documentado acá es "creído" — todo fue probado en hardware real.

---

## Índice

1. [Instalación limpia de Debian 12](#1-instalación-limpia-de-debian-12)
2. [Post-instalación base](#2-post-instalación-base)
3. [Docker Engine + Compose](#3-docker-engine--compose)
4. [La plataforma backend (5 capacidades)](#4-la-plataforma-backend-5-capacidades)
5. [Monitoreo: Cockpit](#5-monitoreo-cockpit)
6. [Acceso remoto: SSH + Tailscale (celular incluido)](#6-acceso-remoto-ssh--tailscale)
7. [Operación diaria](#7-operación-diaria)
8. [Seguridad y secretos](#seguridad-y-secretos)
9. [Reglas del proyecto](#reglas-del-proyecto)
10. [Troubleshooting](#troubleshooting)

---

## 1. Instalación limpia de Debian 12

### 1.1 Preparar el USB

- ISO: `debian-12.x.0-amd64-netinst.iso` — **la netinst, nunca la live** (`/CD/live/`).
- Grabar con Rufus en modo **MBR / BIOS (Legacy)**: el P8700 de 2009 casi seguro no tiene UEFI.

> ⚠️ **Gotcha real:** usar la ISO live de GNOME trajo `raspi-firmware` en una HP, hooks de kernel huérfanos y un dpkg roto. Siempre netinst: <https://www.debian.org/CD/netinst/>

### 1.2 Tasksel — qué desmarcar

En la pantalla "Software selection", dejar marcado **únicamente**:

- ✅ SSH server
- ✅ standard system utilities

Desmarcar **todo** lo demás: Debian desktop environment, GNOME/Xfce/KDE, web server, print server. Navegás con flechas y marcas/desmarcás con **Espacio** (Enter avanza).

### 1.3 Particionado (tabla `msdos`/MBR sobre `/dev/sda`)

Elegí "Manual":

| # | Tipo | Tamaño | Uso |
|---|------|--------|-----|
| 1 | Primaria | 8 GiB | swap |
| 2 | Primaria | resto (~215 GiB) | `/` ext4 |

Sin `/home` ni `/boot` separados: para un server Docker no aportan nada. 8 GiB de swap con 4 GB de RAM cubren los picos de builds de imágenes sin tocar significativamente el SSD (3.5% del disco).

### 1.4 Verificación post-install

```bash
lsb_release -a          # Debian 12 bookworm
lsblk -f                # ext4 en / + [SWAP] montado
free -h                 # Swap: 8.0Gi
systemctl get-default   # DEBE decir multi-user.target
```

Si devuelve `graphical.target`, se coló el entorno gráfico:

```bash
sudo systemctl set-default multi-user.target
```

### 1.5 Recuperar la contraseña de root (si quedó olvidada)

Desde el menú de GRUB: apretá `e`, al final de la línea que empieza con `linux` agregá `init=/bin/bash`, `Ctrl+X`, y en el prompt:

```bash
mount -o remount,rw /
usermod -aG sudo <usuario>
```

---

## 2. Post-instalación base

### 2.1 Que no se suspenda al cerrar la tapa

Drop-in (no tocar `logind.conf` principal, así una actualización de systemd no lo pisa):

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

### 2.2 Hostname

```bash
sudo hostnamectl set-hostname hp-server
```

### 2.3 SSH con llave, sin contraseña

En la PC (Windows), desde PowerShell:

```powershell
ssh-keygen -t ed25519        # Enter, Enter (sin passphrase)
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub   # copiar la salida
```

En el server, con la llave pública pegada en `~/.ssh/authorized_keys`:

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
# pegar la llave pública en ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

sudo tee /etc/ssh/sshd_config.d/10-no-password.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo systemctl restart ssh
```

Verificado: entra con llave, contraseña rechazada (`Permission denied (publickey)`).

### 2.4 Tuning de swap para SSD

```bash
sudo tee /etc/sysctl.d/99-swap-ssd.conf <<'EOF'
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sudo sysctl --system
cat /proc/sys/vm/swappiness      # debe devolver 10
```

### 2.5 TRIM semanal + noatime

```bash
sudo systemctl enable --now fstrim.timer
sudo cp /etc/fstab /etc/fstab.bak
# editar /etc/fstab: agregar noatime a las opciones de la línea de /
sudo mount -o remount /
```

Evitar la opción `discard` en fstab: hace TRIM continuo y golpea el SSD innecesariamente.

### 2.6 Journal acotado a 200 MB

```bash
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
EOF
sudo systemctl restart systemd-journald
```

---

## 3. Docker Engine + Compose

Repo oficial (sintaxis deb822, llave en `docker.asc`):

```bash
sudo apt update
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
```

Logs acotados y `live-restore` (que los contenedores sigan aunque se reinicie Docker):

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF

sudo systemctl enable --now docker
sudo docker run --rm hello-world
docker compose version      # Docker Compose v2.x
```

---

## 4. La plataforma backend (5 capacidades)

| # | Capacidad | Implementación | Puerto (solo localhost) |
|---|---|---|---|
| 1 | Base de datos | PostgreSQL 16 (Alpine) | 5432 |
| 2 | APIs automáticas | PostgREST 12.2 | 3000 |
| 3 | Autenticación | GoTrue (JWT HS256) | 9999 |
| 4 | File storage | Storage nativo en PG (tabla `files` + RLS + RPC binario) | vía PostgREST |
| 5 | Serverless | edge-runtime Deno | 9000 |

Más el gateway Caddy (8080) y la app (3001).

### 4.1 Estructura

```
deploy/
├── docker-compose.yml            # postgres + postgrest + gotrue
├── docker-compose.override.yml   # edge-runtime + caddy + app
├── caddy/Caddyfile               # rutas /rest/v1, /auth/v1, /storage/v1, /
├── functions/                    # funciones serverless (Deno)
│   ├── main/index.ts
│   └── storage/index.ts
└── scripts/                      # rotación de secretos, migración de fotos
```

### 4.2 Archivo `.env` (gitignored — todos los secretos viven acá)

```bash
cat > .env << 'EOF'
POSTGRES_PASSWORD=<password-de-db>
JWT_SECRET=<jwt-secret-aleatorio>
SERVICE_KEY=<jwt-service-role>
ANON_KEY=<jwt-anon-role>
CRON_SECRET=<secreto-del-cron>
EOF
chmod 600 .env
```

> ⚠️ **Nunca** pegues secretos en los `docker-compose*.yml` ni en el chat. Los yml referencian `${VAR}` y los valores se expanden desde `.env`.

### 4.3 Levantar

```bash
cd deploy
docker compose up -d
docker compose ps          # todo "running" / "healthy"
```

### 4.4 Arquitectura de auth y storage

- **Auth:** GoTrue firma el JWT (HS256 con `JWT_SECRET` compartido); PostgREST lo verifica y hace `SET ROLE authenticated` → RLS por fila (`anon` / `authenticated` / `authenticator`).
- **Storage:** patrón RPC binario (`upload_binary` octet-stream / `download_file`), dueño automático por `auth.uid()`, tamaños reales por columna generada. **MinIO/Garage/Kong descartados** (rate limit de registros + simplicidad).
- **Serverless:** el edge-runtime **necesita** el subcomando explícito `command: ["start", "--main-service", "/home/deno/functions/main"]` (sin él, imprime el help y hace crash loop). Funciones en `functions/<nombre>/index.ts`.
- **Caddy:** único punto de entrada: `/rest/v1` → PostgREST, `/auth/v1` → GoTrue, `/storage/v1` → edge-runtime, `/` → app.
- **Todo bindeado a `127.0.0.1`** — fuera del server no se expone nada sin túnel.

### 4.5 Trabajo en 2 máquinas

1. **El server hace RUN, no BUILD.** La imagen de la app se buildea en la PC (`docker build -t pedidos:v2 .`), se transfiere y se carga (`docker load`).
2. **Secretos por build-arg** cuando la imagen necesita claves.

---

## 5. Monitoreo: Cockpit

```bash
sudo apt install cockpit
```

Bindear a solo-localhost vía drop-in (no editar el socket base):

```bash
sudo mkdir -p /etc/systemd/system/cockpit.socket.d
sudo tee /etc/systemd/system/cockpit.socket.d/10-localhost.conf <<'EOF'
[Socket]
ListenStream=
ListenStream=127.0.0.1:9090
EOF
sudo systemctl daemon-reload
sudo systemctl restart cockpit.socket
```

Verificación:

```bash
ss -ltnp | grep 9090        # debe mostrar 127.0.0.1:9090
curl -k https://127.0.0.1:9090   # HTML de login de Cockpit
```

**Acceso desde la PC (túnel SSH):**

```bash
ssh -L 9090:localhost:9090 <usuario>@<IP-del-server>
# y en el navegador: https://localhost:9090 (aceptar el certificado self-signed)
```

Con eso ves CPU, RAM, disco, red, paquetes, services, logs y una terminal web.

---

## 6. Acceso remoto: SSH + Tailscale

### 6.1 Instalar Tailscale en el server

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up                          # te da un URL de login → abrilo en el browser
sudo tailscale set --operator=$USER        # para usar tailscale sin sudo después
```

### 6.2 Exponer Cockpit dentro de la tailnet

Cockpit corre en `https://127.0.0.1:9090` con **certificado self-signed**, así que el target del proxy debe ser `https+insecure://` (Tailscale termina el TLS con certificado válido en el lado de afuera):

```bash
tailscale serve --https=9090 --bg https+insecure://127.0.0.1:9090
```

Salida esperada:

```
Available within your tailnet:
https://hp-server.<tu-tailnet>.ts.net:9090/
|-- proxy https+insecure://127.0.0.1:9090
```

### 6.3 Abrir desde el celular

1. App **Tailscale** en el celu → verificar que dice **Connected**.
2. Browser → `https://hp-server.<tu-tailnet>.ts.net:9090/`
3. Login con el usuario y contraseña **del sistema** (`<usuario>`).

HTTPS válido (certificado de Tailscale), sin warnings. Funciona desde 4G o cualquier WiFi.

### 6.4 Comandos de gestión del tunnel

```bash
tailscale serve status        # ver el proxy activo
tailscale serve --https=9090 off         # apagarlo
# levantar de nuevo (ej. después de cambios):
tailscale serve --https=9090 --bg https+insecure://127.0.0.1:9090
tailscale ip -4               # IP estática de la tailnet (100.x.y.z)
```

### 6.5 Alternativa: túnel SSH desde la PC (sin Tailscale)

```bash
ssh -L 9090:localhost:9090 <usuario>@<IP-del-server>
# navegador: https://localhost:9090
```

> Si perdés la conexión SSH, reconectás y con `tmux attach -t trabajo` volvés exactamente donde estabas. **Nunca corras trabajos largos en una terminal "pelada"**: `tmux new -s trabajo` primero.

---

## 7. Operación diaria

### Reinicio (procedimiento oficial — NO usar `reboot`)

```bash
sudo poweroff
# esperar 10 segundos → botón de encendido → arranca solo
```

### Mapa de puertos (todos en `127.0.0.1`)

| Puerto | Servicio |
|---|---|
| 5432 | PostgreSQL |
| 3000 | PostgREST |
| 9999 | GoTrue |
| 9000 | edge-runtime (storage shim + serverless) |
| 8080 | Caddy (gateway) |
| 3001 | App (Next.js standalone) |
| 9090 | Cockpit (dashboard) |
| 9443 | Portainer (opcional) |

### Comprobaciones rápidas

```bash
docker compose ps                      # estado de la plataforma
journalctl -u cockpit -f               # logs de Cockpit
docker logs -f <contenedor>            # logs de un servicio
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:3000/  # postgrest
```

---

## Seguridad y secretos

- **Todos los secretos en `.env`** (gitignored, `chmod 600`). Los yml solo referencian `${VAR}`.
- **SSH solo con llave** (`PasswordAuthentication no`).
- **Nada expuesto fuera de `127.0.0.1`** — el acceso externo es exclusivamente por SSH tunnel o Tailscale (tailnet privada).
- **Rotación de secretos** con los scripts de `deploy/scripts/` (`rotate-db-passwords.sh` con `dry`/`go`, `tier2-cutover.sh` para JWT/keys).
- **Un backup en el mismo disco no es backup** — falta pendiente: backups cifrados fuera del SSD.

---

## Reglas del proyecto

1. **El server hace RUN, no BUILD** — se buildea en la PC y se transfiere.
2. **Inspeccionar antes de actuar** (`ls`, `lsblk`, `dpkg -l`) antes de cualquier comando que cree o borre.
3. **Un servicio por vez**, verificado antes de sumar el siguiente.
4. **Un backup en el mismo disco no es backup.**
5. **Nunca `disable` el display manager** — alcanza con `systemctl set-default multi-user.target`.

---

## Troubleshooting

| Problema | Causa | Solución |
|---|---|---|
| `<usuario> is not in the sudoers file` | El instalador solo agrega a `sudo` si la clave de root queda vacía | `su -` → `usermod -aG sudo <usuario>` → relogin |
| No arranca la gráfica | GNOME/Wayland sobre GMA 4500MHD | Usar XFCE/Xorg |
| Swap de solo ~1 GB | Particionado guiado | Partición de 8 GiB o swapfile de 6-8 GB |
| GNOME instalado sin querer | Live ISO o task-desktop marcado | `apt purge task-gnome-desktop` + `task-xfce-desktop` desde TTY |
| `reboot` se cuelga | Firmware ACPI de 2009 | `sudo poweroff` + botón |
| GoTrue: `required key API_EXTERNAL_URL missing value` | El prefijo `GOTRUE_` duplica el nombre | Usar `API_EXTERNAL_URL` sin prefijo |
| GoTrue: `schema "auth" does not exist` | Postgres pelado no trae el esquema | `CREATE SCHEMA auth AUTHORIZATION platform;` |
| PostgREST: `no matches found in the schema cache` | Nadie notifica el DDL en PG pelado | `NOTIFY pgrst, 'reload schema';` después de cada DDL |
| `42501 permission denied` con config correcta | El JWT vence a la hora (3600 s) | Renovar el token antes de diagnosticar |
| URI de PostgREST rota | `@` en el password rompe el parseo | Passwords sin `@` `:` `/` |
| Cockpit: "conexión fallida" desde el celu | Tailscale serve apuntaba a HTTP en vez de HTTPS | `tailscale serve --https=9090 --bg https+insecure://127.0.0.1:9090` |
| Corromper comandos al pegar por SSH | Pegado de bloques largos | Pegar de una, verificar con `grep`/`docker compose config`, o usar `scp` |

---

## Estructura del repo

```
.
├── README.md                        # este archivo
├── PLAN-DE-TRABAJO-SERVER.md        # plan de trabajo completo con historial
├── deploy/
│   ├── docker-compose.yml           # core: postgres + postgrest + gotrue
│   ├── docker-compose.override.yml  # edge-runtime + caddy + app
│   ├── caddy/Caddyfile
│   ├── functions/                   # serverless (Deno)
│   └── scripts/                     # rotación de secretos, migraciones
└── .gitignore
```

---

## Pendientes

- [ ] Firewall (`ufw`) — hoy todo en 127.0.0.1 + túneles, pero falta la capa defensiva
- [ ] Backups `pg_dump` cifrados **fuera** del SSD
- [ ] Reservar IP fija en el router
- [ ] Upgrade a 8 GB de RAM (2×4 GB DDR2-800)
- [ ] Baja de Vercel + Supabase cuando la migración esté 100% confirmada
