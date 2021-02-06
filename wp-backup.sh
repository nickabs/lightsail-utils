#!/bin/bash
# back up wordpress database and files

trap "errorExit process terminated" SIGTERM SIGINT SIGQUIT SIGKILL

function usage() {
    echo "Usage: $SCRIPT  -l log file -w wordpress dir -b backup dir 
        [ -s (silent) ] 
        [ -p passphrase ] (when specified this will be used as a key to encrypt the systems archive )
        [ -f email from -t email to ]

        e.g:
        $SCRIPT -w /var/www/wordpress -l wp.log -b /data/backups/wordpress
        " 1>&2; exit 1;
}

function isRoot() {
    if [ "$(whoami)" != 'root' ]; then
        return 1
    fi
}

function log() {
    echo LOG: "$@" >> $LOG_FILE
    if [ ! "$SILENT" ]; then
        echo LOG: "$@"
    fi
}

function errorExit() {
    echo "ERROR: $@" >> $LOG_FILE
    exec 2>&2
    echo "$SCRIPT: ERROR: $@" 
    if [ "$EMAIL" ];then
        if ! email "$SCRIPT: FAILED" ; then
            echo "$SCRIPT: ERROR: could not send email" 2>&1
        fi
    fi
    exit -1
}


function createDatabaseArchive() {
    db_name=$((grep DB_NAME | cut -d \' -f 4) < $WP_CONFIG_FILE)
    user=$((grep DB_USER | cut -d \' -f 4) < $WP_CONFIG_FILE)
    host=$((grep DB_HOST | cut -d \' -f 4) < $WP_CONFIG_FILE)

    # avoids supplying password on command line
    export MYSQL_PWD=$((grep DB_PASSWORD | cut -d \' -f 4) < $WP_CONFIG_FILE)

	mysqldump --no-tablespaces --user=$user --host=$host $db_name  | gzip > $DATABASE_ARCHIVE_FILE
}


function createContentArchive() {
    # backup the user content directory
    tar czf $CONTENT_ARCHIVE_FILE --transform="s,${WP_ROOT_DIR#/}/,,"  $WP_ROOT_DIR/wp-content
}
function createSystemArchive() {
    # backup the system files
    tar czf $SYSTEM_ARCHIVE_FILE --transform="s,${WP_ROOT_DIR#/}/,," --exclude $WP_ROOT_DIR/wp-content $WP_ROOT_DIR 

    if [ ! -z "$PASSPHRASE" ] ; then
        gpg --symmetric --passphrase $PASSPHRASE --batch -o ${SYSTEM_ARCHIVE_FILE}.gpg  $SYSTEM_ARCHIVE_FILE && rm $SYSTEM_ARCHIVE_FILE
    fi
}

# main
export SCRIPT=$(basename $0)
while getopts "sw:l:b:t:f:p:" o; do
        case "$o" in
        s) SILENT=true ;; # disable screen output
        l) LOG_FILE=$OPTARG ;; 
        b) BACKUP_ROOT_DIR=${OPTARG%/} ;; 
        f) FROM_EMAIL=$OPTARG ;;
        t) TO_EMAIL=$OPTARG ;;
        w) WP_ROOT_DIR=${OPTARG%/} ;;
        p) PASSPHRASE=$OPTARG ;;
        *) usage ;;
        esac
done

if [ ! "$LOG_FILE" ] || [ ! "$WP_ROOT_DIR" ]  || [ ! "$BACKUP_ROOT_DIR" ]; then
    usage
fi

if [  "$FROM_EMAIL" ] || [ "$TO_EMAIL" ]; then
    if [ ! "$FROM_EMAIL" ] || [ ! "$TO_EMAIL" ]; then
        echo "specify both from and to emails" >&2
        usage
    fi
    EMAIL=true
fi

if ! isRoot ;then
    errorExit "this script must be run as root"
fi

if touch "$LOG_FILE" 2>/dev/null ;then
    exec 2>>$LOG_FILE
else
    echo "$SCRIPT: ERROR exit: can't write to log file $LOG_FILE" 2>&1
    exit -1
fi

DT=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')

WP_CONFIG_FILE="${WP_ROOT_DIR}/wp-config.php"

if [ ! -r $CONFIG_FILE ]; then
    errorExit "Can't read WP config file: $CONFIG_FILE"
fi

if [ ! -w $BACKUP_ROOT_DIR ]; then
    errorExit "Can't write to backup directory: $BACKUP_ROOT_DIR"
fi

BACKUP_DIR=${BACKUP_ROOT_DIR}/${DATE}

if [ -d $BACKUP_DIR ]; then
    errorExit "Backup directory already exits: $BACKUP_DIR"
fi

if ! mkdir $BACKUP_DIR ; then
    errorExit "can't create backup directory: $BACKUP_DIR"
fi

DATABASE_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-database.sql.gz 
CONTENT_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-content.tar.gz 
SYSTEM_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-system.tar.gz 

echo "============================================" >>$LOG_FILE
log $(printf "%s %s starting" "$DT" "$SCRIPT")


log "Creating database archive: $DATABASE_ARCHIVE_FILE"
if ! createDatabaseArchive ; then
    errorExit "could not create database archive"
fi

log "Creating content archive: $CONTENT_ARCHIVE_FILE"
if ! createContentArchive ; then
    errorExit "could not create content archive"
fi

log "Creating system archive: $SYSTEM_ARCHIVE_FILE"
if ! createSystemArchive ; then
    errorExit "could not create system archive"
fi

log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT completed"
if [ "$EMAIL" ];then
    if ! email "$SCRIPT: completed without errors" ; then
        errorExit "could not send email"
    fi
fi
