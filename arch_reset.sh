#!/usr/bin/env bash
# arch_reset.sh
# Vorsicht: zerstörerisch. Bitte vorher lesen.
# Erstellt Backups (in /root/arch_reset_backups/) und entfernt dann alles außer base/base-devel.
# Fragt ab, ob /home erhalten werden soll.

set -euo pipefail
IFS=$'\n\t'

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/arch_reset_backups/$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

if [ "$(id -u)" -ne 0 ]; then
  echo "Dieses Script muss als root ausgeführt werden. Benutze: sudo ./arch_reset.sh"
  exit 1
fi

cat <<'WARN'
###############################################
!!! EXTREM WICHTIG !!!
Dieses Script löscht Pakete und viele System- und Benutzerkonfigurationen.
Du wirst Daten verlieren, wenn du fortfährst.

Das Script:
 - erstellt Backups in /root/arch_reset_backups/
 - entfernt alle Pakete außer denen in den Gruppen "base" und "base-devel"
 - leert /etc und /var u.ä. (außer dem Backup-Ordner)
 - (optional) löscht oder behält /home
 - installiert base, linux, linux-firmware neu
 - deaktiviert gängige Display Manager

Wenn du nicht 100% sicher bist: STOPP jetzt.
###############################################
WARN

read -rp "Willst du fortfahren? (Tippe EXACT: RESET) " CONF
if [ "$CONF" != "RESET" ]; then
  echo "Abgebrochen. Du musst 'RESET' tippen, um fortzufahren."
  exit 0
fi

# Ask whether to preserve /home
read -rp "Sollen /home-Inhalte BEWAHRT werden? (y/n) " KEEP_HOME
if [[ "$KEEP_HOME" =~ ^[Yy] ]]; then
  PRESERVE_HOME=true
else
  PRESERVE_HOME=false
fi

echo "== Backup wird erstellt in: $BACKUP_DIR =="
mkdir -p "$BACKUP_DIR"

# Save pacman explicit and full package lists
pacman -Qqe > "$BACKUP_DIR/pacman-explicit-$(date +%s).txt" || true
pacman -Qq > "$BACKUP_DIR/pacman-all-$(date +%s).txt" || true

# Save /etc and /home (if present) into tarballs
echo "== Backup: /etc =="
tar -czf "$BACKUP_DIR/etc.tar.gz" /etc || true

if [ -d /home ]; then
  echo "== Backup: /home =="
  tar -czf "$BACKUP_DIR/home.tar.gz" /home || true
fi

# Save list of groups base/base-devel packages (best-effort)
echo "== Ermitteln der base / base-devel Pakete =="
SAFE_PKGS_FILE="$BACKUP_DIR/safe-packages.txt"
# Try to get groups; tolerate failures
if pacman -Qqg base base-devel &>/dev/null; then
  pacman -Qqg base base-devel > "$SAFE_PKGS_FILE" || true
else
  # fallback: try reading group members in a safer way
  pacman -Sg base base-devel &>/dev/null || true
  pacman -Qqg base 2>/dev/null > "$SAFE_PKGS_FILE" || true
fi

# Always ensure pacman itself is preserved in case group lookup failed
grep -qxF "pacman" "$SAFE_PKGS_FILE" || echo "pacman" >> "$SAFE_PKGS_FILE"

echo "Sichere Pakete (werden NICHT entfernt):"
cat "$SAFE_PKGS_FILE" || true

# Build list of installed packages to remove (exclude safe packages)
echo "== Erstelle Liste der zu entfernenden Pakete =="
ALL_PKGS_FILE="$BACKUP_DIR/all-packages.txt"
pacman -Qq > "$ALL_PKGS_FILE" || true

# Use grep -vx -f to filter out safe packages; if safe file empty, do nothing risky
REMOVABLE_LIST="$BACKUP_DIR/to-remove.txt"
if [ -s "$SAFE_PKGS_FILE" ]; then
  grep -vx -f "$SAFE_PKGS_FILE" "$ALL_PKGS_FILE" > "$REMOVABLE_LIST" || true
else
  # If safe file missing or empty, abort to avoid full system wipe
  echo "FEHLER: Konnte sichere Paketliste nicht bestimmen. Abbruch."
  exit 1
fi

if [ ! -s "$REMOVABLE_LIST" ]; then
  echo "Keine Pakete zum Entfernen gefunden. (Oder alles ist bereits sicher.)"
else
  echo "Pakete, die entfernt werden:"
  head -n 200 "$REMOVABLE_LIST" || true
  echo "..."
  read -rp "Möchtest du diese Pakete jetzt entfernen? (y/n) " CONF2
  if [[ "$CONF2" =~ ^[Yy] ]]; then
    # Feed the list into pacman -Rns --noconfirm - ; pacman reads '-' stdin
    printf '%s\n' "$(cat "$REMOVABLE_LIST")" | pacman -Rns --noconfirm - || true
  else
    echo "Entfernen übersprungen. Du kannst die Datei $REMOVABLE_LIST prüfen."
  fi
fi

# Remove configuration directories (but keep our backup dir)
echo "== Lösche System-Configs (außer Backup-Verzeichnis) =="
# Be VERY explicit about what we delete.
rm -rf /etc/* || true
# Ensure our backup dir remains accessible
mkdir -p "$BACKUP_DIR"

# Handle /var - we keep journal and backup dir out for safety; but we can clean most
rm -rf /var/cache/pacman/pkg/* || true
# careful: don't rm -rf /var entirely as systemd may need some runtime dirs
find /var -mindepth 1 -maxdepth 2 -not -path "$BACKUP_DIR/*" -exec rm -rf {} + || true

# Handle /root - keep backup and leave root account usable
# Remove everything in /root except our backup dir
shopt -s extglob
if [ -d /root ]; then
  for f in /root/*; do
    case "$f" in
      "$BACKUP_DIR"*) ;;
      *) rm -rf "$f" || true ;;
    esac
  done
fi

# Handle /home according to preference
if [ "$PRESERVE_HOME" = true ]; then
  echo "Erhalte /home wie gewünscht."
else
  echo "Lösche /home (Benutzerdaten werden entfernt) ..."
  rm -rf /home/* || true
fi

# Reinstall minimal base packages
echo "== Installiere minimalen Basis-Stack (base, linux, linux-firmware) =="
pacman -S --noconfirm base linux linux-firmware || true

# Deaktivieren gängiger Display Manager (sollte keinen Desktop mehr starten)
for svc in gdm sddm lightdm lxdm; do
  systemctl disable --now "$svc" 2>/dev/null || true
done

echo "== Fertig == "
echo "Backups liegen in: $BACKUP_DIR"
echo "Prüfe das Backup bevor du neu startest. Du kannst jetzt per 'pacman -S' Pakete nachinstallieren."
read -rp "Neustart durchführen? (y/n) " REBOOT
if [[ "$REBOOT" =~ ^[Yy] ]]; then
  echo "Rebooting..."
  exec systemctl reboot
else
  echo "Beende Script. Starte bei Bedarf später neu."
fi
