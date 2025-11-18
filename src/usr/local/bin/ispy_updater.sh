#!/bin/bash

set -euo pipefail

##
# Required #
##

## sudo touch /var/log/agentdvr-updater.log
## sudo chown tonuser:tonuser /var/log/agentdvr-updater.log
## sudo apt install -y libxml2-utils   # pour xmllint

## example de fichier de config:
# FREE_USER="xxxxxxxx"
# FREE_API_KEY="xxxxxxxxxxxx"
# FREE_API_URL="https://smsapi.free-mobile.fr/sendmsg"


###########################################
#   CONFIGURATION
###########################################

CONFIG_FILE="$HOME/.ispy/config"
SMS_ENABLED=false

INSTALL_DIR="/opt/AgentDVR"
CONFIG_DIR="$INSTALL_DIR/Media/XML"
BACKUP_DIR="$HOME/Backups/agentdvr"
SERVICE_NAME="AgentDVR.service"
INSTALL_SCRIPT_URL="https://www.ispyconnect.com/install"

LOGFILE="/var/log/agentdvr-updater.log"
LOG_MAX_SIZE=$((1024 * 1024)) # 1 Mo

DATE=$(date +%Y-%m-%d_%H-%M)
ARCHIVE_NAME="config_backup_$DATE.tar.gz"
ARCHIVE_PATH="$BACKUP_DIR/$ARCHIVE_NAME"

# ➤ API Free Mobile pour envoi SMS (à personnaliser)
FREE_USER="14725496"
FREE_API_KEY="3vSZ1llcFzA2z1"
FREE_API_URL="https://smsapi.free-mobile.fr/sendmsg"

###########################################
#   COULEURS TERMINAL
###########################################
green='\e[32m'
red='\e[31m'
yellow='\e[33m'
blue='\e[34m'
reset='\e[0m'

###########################################
#   LECTURE CONFIG (~/.ispy/config)
###########################################
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Chargement configuration depuis $CONFIG_FILE"
    # Chargement sécurisé
    # Le fichier doit contenir des lignes du type :
    # FREE_USER="12345"
    # FREE_API_KEY="xxxx"
    # FREE_API_URL="https://smsapi.free-mobile.fr/sendmsg"
    source "$CONFIG_FILE"

    # Vérification des valeurs chargées
    if [[ -n "${FREE_USER:-}" && -n "${FREE_API_KEY:-}" ]]; then
        SMS_ENABLED=true
    else
        echo "⚠ Le fichier de config existe mais FREE_USER ou FREE_API_KEY est vide."
        SMS_ENABLED=false
    fi
else
    echo "⚠ Aucun fichier ~/.ispy/config, les SMS sont désactivés."
    SMS_ENABLED=false
fi

###########################################
#   ROTATION DES LOGS
###########################################
rotate_logs() {
    # Créer le fichier log si absent
    if [[ ! -f "$LOGFILE" ]]; then
        sudo touch "$LOGFILE"
        sudo chown "$(id -un)":"$(id -gn)" "$LOGFILE" || true
        return
    fi

    # Taille actuelle du log
    local size
    size=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)

    if (( size >= LOG_MAX_SIZE )); then
        local ts
        ts=$(date +%Y-%m-%d_%H-%M-%S)
        local rotated="${LOGFILE}.${ts}"

        sudo mv "$LOGFILE" "$rotated"
        sudo touch "$LOGFILE"
        sudo chown "$(id -un)":"$(id -gn)" "$LOGFILE" || true
    fi
}

###########################################
#   LOGGING
###########################################
log() {
    rotate_logs
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sudo tee -a "$LOGFILE" >/dev/null
}

###########################################
#   NOTIFICATION SMS FREE
###########################################
send_sms() {
    if ! $SMS_ENABLED; then
        log "SMS ignoré (pas de fichier de config détecté dans ~/.ispy/config)"
        return 0
    fi

    local MESSAGE="$1"

    curl -s \
        -G "$FREE_API_URL" \
        --data-urlencode "user=$FREE_USER" \
        --data-urlencode "pass=$FREE_API_KEY" \
        --data-urlencode "msg=$MESSAGE" >/dev/null || true

    log "SMS envoyé : $MESSAGE"
}

###########################################
#   GESTION DU SERVICE
###########################################
manage_service() {
    ACTION="$1"
    echo -e "${blue}🔧 Service $SERVICE_NAME → $ACTION...${reset}"
    sudo systemctl "$ACTION" "$SERVICE_NAME"
    log "Service $ACTION"
}

###########################################
#   SAUVEGARDE
###########################################
backup() {
    echo -e "${blue}📁 Sauvegarde de la configuration...${reset}"
    mkdir -p "$BACKUP_DIR"

    tar -czf "$ARCHIVE_PATH" -C "$INSTALL_DIR/Media" XML

    log "Backup créé : $ARCHIVE_PATH"
    send_sms "AgentDVR : sauvegarde créée ($ARCHIVE_NAME)"

    echo -e "${green}✔ Sauvegarde créée : $ARCHIVE_PATH${reset}"
}

###########################################
#   LISTE DES BACKUPS
###########################################
list_backups() {
    echo -e "${yellow}📦 Sauvegardes disponibles :${reset}"

    if ls "$BACKUP_DIR"/*.tar.gz >/dev/null 2>&1; then
        ls -1 "$BACKUP_DIR"/*.tar.gz
    else
        echo -e "${red}Aucun backup trouvé.${reset}"
    fi
}

###########################################
#   VÉRIFICATION XML
###########################################
check_xml_integrity() {
    ARCH="$1"

    echo -e "${blue}🔍 Vérification des fichiers XML...${reset}"
    TEMP_DIR=$(mktemp -d)

    tar -xzf "$ARCH" -C "$TEMP_DIR"

    # Nécessite xmllint (sudo apt install -y libxml2-utils)
    for FILE in "$TEMP_DIR"/XML/*.xml; do
        if ! xmllint --noout "$FILE" 2>/dev/null; then
            echo -e "${red}❌ XML corrompu : $FILE${reset}"
            rm -rf "$TEMP_DIR"
            return 1
        fi
    done

    rm -rf "$TEMP_DIR"
    echo -e "${green}✔ XML valide${reset}"
}

###########################################
#   RESTAURATION
###########################################
restore() {
    ARCHIVE="$1"

    if [[ ! -f "$ARCHIVE" ]]; then
        echo -e "${red}❌ Archive introuvable : $ARCHIVE${reset}"
        exit 1
    fi

    check_xml_integrity "$ARCHIVE" || {
        send_sms "AgentDVR : restauration annulée (XML corrompu)"
        exit 1
    }

    manage_service stop

    echo -e "${blue}📦 Restauration depuis : $ARCHIVE${reset}"
    tar -xzf "$ARCHIVE" -C "$INSTALL_DIR/Media"

    manage_service start

    log "Restauration effectuée depuis : $ARCHIVE"
    send_sms "AgentDVR : restauration réussie"

    echo -e "${green}✔ Restauration terminée.${reset}"
}

###########################################
#   MISE À JOUR (MODE AUTO AVEC EXPECT)
###########################################
update() {
    echo -e "${blue}🔄 Mise à jour AgentDVR (avec sauvegarde)...${reset}"
    backup
    manage_service stop

    echo -e "${blue}⬇ Téléchargement du script officiel...${reset}"
    TMP_SCRIPT="/tmp/agentdvr_install.sh"

    curl -sL "$INSTALL_SCRIPT_URL" -o "$TMP_SCRIPT"
    chmod +x "$TMP_SCRIPT"

    if [[ ! -s "$TMP_SCRIPT" ]]; then
        echo -e "${red}❌ Téléchargement échoué !${reset}"
        manage_service start
        return 1
    fi

    echo -e "${blue}⚙ Exécution automatique via EXPECT...${reset}"

    expect <<EOF
set timeout -1
spawn sudo bash "$TMP_SCRIPT"

# Réponse automatique à TOUTES les questions (y/n)
expect {
    "(y/n)" { send "y\r"; exp_continue }
    "Press any key" { send "\r"; exp_continue }
    "Continue?" { send "y\r"; exp_continue }
    eof
}
EOF

    manage_service start
    log "Mise à jour effectuée via EXPECT"
    send_sms "AgentDVR : mise à jour terminée"
    echo -e "${green}✔ Mise à jour terminée.${reset}"
}

###########################################
#   INSTALLATION DU CRON MENSUEL AUTOMATIQUE
###########################################
cron_install() {
    CRON_PATH="/home/klesk/ispy_updater.sh"   # <-- mets ton chemin ABSOLU ici
    CRON_LINE="0 3 1 * * $CRON_PATH --update >/dev/null 2>&1"

    echo -e "${blue}📅 Installation cron mensuel automatique...${reset}"

    # Vérification fichier
    if [[ ! -f "$CRON_PATH" ]]; then
        echo -e "${red}❌ Le script n'existe pas : $CRON_PATH${reset}"
        return 1
    fi

    # Export PATH dans cron pour éviter erreurs
    PREFIX="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    # Récupération crontab root actuelle
    CURRENT_CRON=$(sudo crontab -l 2>/dev/null || true)

    # Suppression ancienne entrée éventuelle
    CLEAN_CRON=$(echo "$CURRENT_CRON" | grep -v "ispy_updater.sh --update" || true)

    {
        echo "$PREFIX"
        echo "$CLEAN_CRON"
        echo "$CRON_LINE"
    } | sudo crontab -

    log "Cron mensuel installé : $CRON_LINE"
    send_sms "AgentDVR : cron mensuel installé (1er du mois à 03h00)"
    echo -e "${green}✔ Cron mensuel installé.${reset}"
}

###########################################
#   SUPPRESSION DU CRON
###########################################
cron_remove() {
    echo -e "${yellow}🗑 Suppression du cron AgentDVR...${reset}"

    CURRENT_CRON=$(sudo crontab -l 2>/dev/null || true)

    CLEAN_CRON=$(echo "$CURRENT_CRON" | grep -v "ispy_updater.sh --update" || true)

    echo "$CLEAN_CRON" | sudo crontab -

    log "Cron AgentDVR supprimé"
    send_sms "AgentDVR : cron mensuel supprimé"
    echo -e "${green}✔ Cron supprimé.${reset}"
}

###########################################
#   MENU INTERACTIF
###########################################
menu() {
    while true; do
        clear
        echo -e "${blue}====== MENU AGENT DVR ======${reset}"
        echo "1) Sauvegarder"
        echo "2) Restaurer"
        echo "3) Lister les backups"
        echo "4) Mise à jour"
        echo "5) Start service"
        echo "6) Stop service"
        echo "7) Restart service"
	echo "8) Installer le CRON (mensuel)"
	echo "9) Désinstaller le CRON"
        echo "0) Quitter"
        echo -n "Choix : "
        read -r CHOICE

        case "$CHOICE" in
            1) backup ;;
            2)
                list_backups
                echo "Archive à restaurer : "
                read -r FILE
                restore "$FILE"
                ;;
            3) list_backups ;;
            4) update ;;
            5) manage_service start ;;
            6) manage_service stop ;;
            7) manage_service restart ;;
	    8) cron_install ;;
	    9) cron_remove ;;
            0) exit 0 ;;
            *) echo "Choix invalide" ;;
        esac
        read -p "Appuie sur Entrée pour continuer..."
    done
}

###########################################
#   LOGIQUE DES COMMANDES
###########################################
case "${1-}" in
    --backup) backup ;;
    --update) update ;;
    --restore) restore "$2" ;;
    --start) manage_service start ;;
    --stop) manage_service stop ;;
    --restart) manage_service restart ;;
    --list-backups) list_backups ;;
    --cron-install) cron_install ;;
    --cron-remove) cron_remove ;;
    --test-sms)
        send_sms "Test SMS AgentDVR OK"
        echo "Test SMS envoyé (si config présente)."
        ;;
    --menu) menu ;;
    --help|"")
        echo "Usage : $0 [option]"
        echo ""
        echo "  --backup               Sauvegarde configuration"
        echo "  --update               Sauvegarde + mise à jour"
        echo "  --restore <archive>    Restaure un backup"
        echo "  --start                Démarre agentDVR"
        echo "  --stop                 Stoppe agentDVR"
        echo "  --restart              Redémarrage"
        echo "  --list-backups         Liste des sauvegardes"
        echo "  --menu                 Menu interactif"
        ;;
    *)
        echo -e "${red}Option inconnue : $1${reset}"
        exit 1
        ;;
esac

