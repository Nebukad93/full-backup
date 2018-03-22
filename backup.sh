#!/bin/bash

# @(#) Nom du script .. : backup.sh
# @(#) Version ........ : 1.00
# @(#) Date ........... : 19/09/2014
#      Auteurs ........ : Hardware

#~
#~ @(#) Description : Script de sauvegarde d'un système sous linux

# --------------------------------------------------------------------
# Adresse email de reporting
REPORTING_EMAIL=

# Paramètres de connexion au serveur FTP
HOST=''
USER=''
PASSWD=''
PORT=
# --------------------------------------------------------------------

CDAY=$(date +%Y%m%d-%H%M)
NB_MAX_BACKUP=
BACKUP_PARTITION=/home/backup/local
BACKUP_FOLDER=$BACKUP_PARTITION/backup-$CDAY
ERROR_FILE=$BACKUP_FOLDER/errors.log
FTP_FILE=$BACKUP_FOLDER/ftp.log
ARCHIVE=$BACKUP_FOLDER/backup-$CDAY.tar.gz
LOG_FILE=/var/log/backup.log
FTP_REMOTE_PATH='/'

# Définition des variables de couleurs
CSI="\033["
CEND="${CSI}0m"
CRED="${CSI}1;31m"
CGREEN="${CSI}1;32m"
CPURPLE="${CSI}1;35m"
CCYAN="${CSI}0;36m"

##################################################

# Upload de l'archive sur un serveur distant
uploadToRemoteServer() {

# La commande ftp n'est pas compatible avec SSL/TLS donc on utilise lftp à la place
lftp -d -e "cd $FTP_REMOTE_PATH;         \
            lcd $BACKUP_FOLDER;          \
            put backup-$CDAY.tar.gz;     \
            bye" -u $USER,$PASSWD -p $PORT $HOST 2> "$FTP_FILE" > /dev/null

FILES_TRANSFERRED=$(grep -ci "226" "$FTP_FILE")

# On vérifie que le fichier a bien été transféré
if [[ $FILES_TRANSFERRED -ge 1 ]]; then
    echo "OK"
fi

}

sendErrorMail() {

/home/pi/scripts/telegram.sh $2

}

##################################################

if [[ $EUID -ne 0 ]]; then
    echo ""
    echo -e "${CRED}/!\ ERREUR: Vous devez être connecté en tant que root pour pouvoir exécuter ce script.${CEND}" 1>&2
    echo ""
    exit 1
fi

echo "" | tee -a $LOG_FILE
echo -e "${CCYAN}                $(date "+%d/%m/%Y à %Hh%M")        ${CEND}" | tee -a $LOG_FILE
echo -e "${CCYAN}###################################################${CEND}" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE
echo -e "${CCYAN}          DEMARRAGE DU SCRIPT DE BACKUP            ${CEND}" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE
echo -e "${CCYAN}###################################################${CEND}" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE

if [[ ! -d "$BACKUP_PARTITION" ]]; then
    mkdir -p "$BACKUP_PARTITION" > /dev/null 2>&1
fi

if [[ -e "$BACKUP_FOLDER" ]]; then
    rm -rf "$BACKUP_FOLDER"
fi

mkdir "$BACKUP_FOLDER"

# On vérifie que le fichier .excluded-paths existe bien
if [[ ! -f /opt/full-backup/.excluded-paths ]]; then
    echo -e "\n${CRED}/!\ ERREUR: Le fichier${CEND} ${CPURPLE}/opt/full-backup/.excluded-paths${CEND} ${CRED}n'existe pas !${CEND}" | tee -a $LOG_FILE
    echo -e "" | tee -a $LOG_FILE
    exit 1
fi

echo -n "> Compression des fichiers système" | tee -a $LOG_FILE
#tar --warning=none --use-compress-program=pigz -cpPf "$ARCHIVE" --exclude-from=/opt/full-backup/.excluded-paths / 2> "$ERROR_FILE"
tar --warning=none -cpzPf "$ARCHIVE" --exclude-from=/opt/full-backup/.excluded-paths / 2> "$ERROR_FILE"

# Si une erreur survient lors de la compression
if [[ -s "$ERROR_FILE" ]]; then
    echo -e "\n${CRED}/!\ ERREUR: Echec de la compression des fichiers système.${CEND}" | tee -a $LOG_FILE
    echo -e "" | tee -a $LOG_FILE
    sendErrorMail "$ERROR_FILE" "Echec de la compression des fichiers systeme."
    exit 1
fi

echo -e " ${CGREEN}[OK]${CEND}" | tee -a $LOG_FILE

# Récupère la taille de l'archive en octets
SIZE=$(wc -c "$ARCHIVE" | cut -f 1 -d ' ')
# HUMANSIZE=$(echo ${SIZE} | awk '{ sum=$1 ; hum[1024**3]="Go";hum[1024**2]="Mo";hum[1024]="Ko"; \
#             for (x=1024**3; x>=1024; x/=1024){ if (sum>=x) { printf "%.2f %s\n",sum/x,hum[x];break } }}')

# 2147483648 = 2GB = 2Go
if [[ "$SIZE" -gt 2147483648 ]]; then
    echo -e "\n${CRED}/!\ ATTENTION: L'archive est très volumineuse.${CEND}" | tee -a $LOG_FILE
    echo -e "\n${CRED}/!\ Vous devriez exclure d'avantage de répertoires dans le fichier d'exclusion.${CEND}" | tee -a $LOG_FILE
    echo -e "" | tee -a $LOG_FILE
#    sendErrorMail "Archive trop volumineuse, merci de vérifier le fichier d'exclusion."
fi

NB_ATTEMPT=1

echo -n "> Transfert de l'archive vers le serveur distant" | tee -a $LOG_FILE
while [[ -z $(uploadToRemoteServer) ]]; do
    if [[ "$NB_ATTEMPT" -lt 4 ]]; then
        echo -e "\n${CRED}/!\ ERREUR: Echec du transfert... Tentative $NB_ATTEMPT${CEND}" | tee -a $LOG_FILE
        let "NB_ATTEMPT += 1"
        sleep 10
    else
        echo -e "\n${CRED}/!\ ERREUR: Echec du transfert de l'archive vers le serveur distant.${CEND}" | tee -a $LOG_FILE
        echo "" | tee -a $LOG_FILE
        sendErrorMail "$FTP_FILE" "Echec du transfert de l'archive vers le serveur distant."
        exit 1
    fi
done
echo -e " ${CGREEN}[OK]${CEND}" | tee -a $LOG_FILE

# Retrouve le nombre de sauvegardes effectuées
nbBackup=$(find $BACKUP_PARTITION -type d -name 'backup-*' | wc -l)

if [[ "$nbBackup" -gt $NB_MAX_BACKUP ]]; then

    # Recherche l'archive la plus ancienne
    oldestBackupPath=$(find $BACKUP_PARTITION -type d -name 'backup-*' -printf '%T+ %p\n' | sort | head -n 1 | awk '{print $2}')
    oldestBackupFile=$(find $BACKUP_PARTITION -type d -name 'backup-*' -printf '%T+ %p\n' | sort | head -n 1 | awk '{split($0,a,/\//); print a[5]}')

    echo -en "> Suppression de l'archive la plus ancienne (${CPURPLE}$oldestBackupFile.tar.gz${CEND})" | tee -a $LOG_FILE

    # Supprime le répertoire du backup
    rm -rf "$oldestBackupPath"

    # Supprime l'archive sur le serveur FTP
    lftp -d -e "cd $FTP_REMOTE_PATH;             \
                rm $oldestBackupFile.tar.gz;     \
                bye" -u $USER,$PASSWD -p $PORT $HOST 2>> "$FTP_FILE" > /dev/null

    FILES_REMOVED=$(grep -ci "250\(.*\)dele" "$FTP_FILE")

    # On vérifie que le fichier a bien été supprimé
    if [[ "$FILES_REMOVED" -ne 1 ]]; then
        MESSAGE="Echec lors de la suppression de la sauvegarde le serveur FTP."
        echo -e "\n${CRED}/!\ ERREUR: ${MESSAGE}${CEND}" | tee -a $LOG_FILE
        echo "" | tee -a $LOG_FILE
        sendErrorMail "$FTP_FILE" "$MESSAGE"
        exit 1
    fi

    echo -e " ${CGREEN}[OK]${CEND}" | tee -a $LOG_FILE
fi

echo -e "${CGREEN}> Sauvegarde terminée avec succès !${CEND}" | tee -a $LOG_FILE
echo "" | tee -a $LOG_FILE

exit 0
