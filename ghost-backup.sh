#!/usr/bin/env bash
# see https://github.com/nickabs/lightsail-utils

set -o pipefail
# ERR trap for subshells
set -o errtrace 
trap "errorExit process terminated" SIGTERM SIGINT SIGQUIT SIGKILL ERR

function usage() {
    echo "Usage: $SCRIPT  -l log file -w ghost dir -b backup dir
        [ -m days (max daily backups to retain) ]
        [ -s (silent) ]
        [ -p passphrase ] (when specified this will be used as a key to encrypt the database and config archives )  
        [ -f email from -t email to -a aws profile name ]
		[ -r remote storage -g google drive id -c credential config file for service account]
        [ -R YYYY-MM-DD (restore from backup directory) -o all|config|content|database (specifies which archives to restore) ]
        [ -d YYYY-MM-DD -o all|config|content|database (used with the -r option, download the remote backup archives without restoring ) ] 

        EXAMPLE
        1. backup ghost files and copy to remote storage (note when specifying remote storage the backups are managed in the specified google drive and the local copy is deleted)

        $SCRIPT -w /var/www/ghost -l ghost.log -b /data/backups/ghost -m 7 -r -g 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -c project123-f712345a860a.json -f lightsail-snapshot@example.com -t example@mail.com -a LightsailSnapshotAdmin

        2. to restore the backup from 1st February 2021 
        $SCRIPT -w /var/www/ghost -l ghost.log -b /data/backups/ghost -R 2021-02-01 -o all

        when using the restore option with the remote storage options (see backup example) the archive files will be retrieved from the specified google drive

        3. get the remote backup archives from 1st February 2021 but do not restore them
        $SCRIPT -w /var/www/ghost -l ghost.log -b /data/backups/ghost -r -g 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -c project123-f712345a860a.json -d 2021-02-01 -o all

        see https://github.com/nickabs/lightsail-utils for more information
        " 1>&2
        exit 1
}

function checkOptions() {
	if [ ! "$LOG_FILE" ]; then
        echo -e "ERROR: you must specify a log file\n" >&2
		return 1
	fi

    if [ ! "$GHOST_ROOT_DIR" ]; then
        echo -e "ERROR: you must specify the ghost root directory\n" >&2
		return 1
	fi

    if [ ! "$BACKUP_ROOT_DIR" ]; then
        echo -e "ERROR: you must specify a backup dir\n" >&2
		return 1
	fi

    if [ ! "$MAX_DAYS_TO_RETAIN" ] && [ ! "$ARCHIVE_DATE" ]; then
        echo -e "ERROR: you must specify the number of retention days when creating a new backup\n" >&2
		return 1
	fi

    if [ "$RESTORE" ] && [ "$MAX_DAYS_TO_RETAIN" ]; then
        echo -e "ERROR: you can't use the -m and -R options at the same time"
        return 1
    fi

    if [ "$GHOST_ROOT_DIR" == "$BACKUP_ROOT_DIR" ]; then
        echo -e "ERROR: can't create backup files in the ghost root directory\n" >&2 
        return 1
    fi

    if [ "$DOWNLOAD" ] && [ "$RESTORE" ]; then
        echo -e "ERROR: you can't use the -d (download) option with the -R (restore) option  \n" >&2 
        return 1
    fi

    if [ "$DOWNLOAD" ] && [ -z "$REMOTE" ]; then
        echo -e "ERROR: you can only use the download option with the -r (remote) flag \n" >&2 
        return 1
    fi

    if [ "$REMOTE" ];then
        if [ -z "$REMOTE_ROOT_DIR_ID" ] || [ -z "$SERVICE_ACCOUNT_CREDENTIALS_FILE" ];then
            echo -e "ERROR: please specify the remote root directory id and a service account credentials file when using remote storage\n" >&2
            return 1
        fi
    fi

    if [ "$RESTORE" ]|| [ "$DOWNLOAD" ] ; then
        if [[ ! "$ARCHIVE_DATE" =~ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]];then
            echo -e "ERROR: restore directory should be specified as YYYY-MM-DD\n" ; >&2
            return 1
        fi
    fi

    if [ "$RESTORE" ] || [ "$DOWNLOAD" ]; then 
        if [[ ! "$ARCHIVE_OPTION" =~ ^all$|^config$|^database$|^content$ ]];then
            echo -e "ERROR: you must specify one of these options with the -o flag : all, config, database or content\n" >&2
            return 1
        fi
    fi


	if [  "$FROM_EMAIL" ] || [ "$TO_EMAIL" ]; then
        if [ "$RESTORE" ];then
			echo -e "ERROR: email notifications not available when restoring data\n" >&2
			return 1
		fi

		if [ ! "$FROM_EMAIL" ] || [ ! "$TO_EMAIL" ]; then
			echo -e "ERROR: specify both from and to emails\n" >&2
			return 1
		fi
		if [ ! "$AWS_PROFILE" ]; then
			echo -e "ERROR: specify an AWS CLI profile when using the email option\n" >&2
			return 1
		fi
		EMAIL=true
	fi

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
	local exit_status=$?
	log "$SCRIPT: ERROR: $@ "
	if [ "$EMAIL" ];then
        local msg="$SCRIPT: ERROR: $@"
		if ! email "$msg";then
			echo "$SCRIPT: ERROR: could not send email" 2>&1
       	fi
    fi
	if [ "$REMOTE" ] && [ -d $BACKUP_DIR ]; then
		log "removing working dir $BACKUP_DIR following error"
		rm -rf $BACKUP_DIR
	fi
	exit $exit_status
}

function completionMessages() {
	local msg
	if [ $WARNING_FLAG ]; then
		msg="$SCRIPT: WARNING: completed with warnings"
		log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT completed with warnings"
	else
		msg="$SCRIPT: completed"
		log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT completed"
	fi

   	if [ "$EMAIL" ];then
		if ! email "$msg"; then
			errorExit "could not send email"
		fi
	fi
}

function email() { aws ses send-email --from $FROM_EMAIL --subject "$@" --text "see $LOG_FILE for more info"  --to $TO_EMAIL --profile $AWS_PROFILE >/dev/null ; }

function daysBetween() {
	date1=$( date '+%s' -d $1)
	date2=$( date '+%s' -d $2)
	s=$((date1 - date2))
	echo $((s/86400))
}

function createDatabaseArchive() {

    local_client=$(jq -r '.database.client' $GHOST_CONFIG_FILE)
    if [ -z "$local_client" ]; then
        log "can't  read the database client from $GHOST_CONFIG_FIILE"
        return 1
    fi

    if [ "$local_client" != "mysql" ];then
        log "database.client is $local_client.  This script only supports mysql"
        return 1
    fi

    local database=$(jq -r '.database.connection.database' $GHOST_CONFIG_FILE)
    local user=$(jq -r '.database.connection.user' $GHOST_CONFIG_FILE)
    local host=$(jq -r '.database.connection.host' $GHOST_CONFIG_FILE)

    # setting this env variable avoids supplying password on command line
    export MYSQL_PWD=$(jq -r '.database.connection.password' $GHOST_CONFIG_FILE)
    
	mysqldump --no-tablespaces --user=$user --host=$host $database  | gzip > $DATABASE_ARCHIVE_FILE
}

function createContentArchive() {
	# backup the content directory
	tar czf $CONTENT_ARCHIVE_FILE --transform="s,${GHOST_ROOT_DIR#/}/,,"  $GHOST_ROOT_DIR/content
}

function createConfigArchive() {
	# copy the config Config file

    gzip -c $GHOST_CONFIG_FILE > $CONFIG_ARCHIVE_FILE
}

# removes all directories older than max retention days - for local backups this is run *after* a backup has been created sucessfully
function deleteOldestDailyBackupsLocal() {
	local backup_date
	for d in ${BACKUP_ROOT_DIR}/????-??-??/ ; do
		backup_date=$(basename $d)
	   	if [ $( daysBetween $DATE $backup_date ) -ge $MAX_DAYS_TO_RETAIN ] ;then  
			log "removing $d"
			if ! rm -rf $d ; then
				errorExit "error could not remove $d"
			fi
	   	fi
	done
}


# to maximise the use of space in the remote storage location the script will remove old backups before the new one is copied
function deleteOldestDailyBackupsRemote() {
	local folders folder backup_date backup_id backup_count estimated_backup_size available_space estimated_space_required backups_pending deleted_count
    
	# find folders named YYYY-MM-DD
	readarray -t folders < <(gdriveListFiles $REMOTE_ROOT_DIR_ID "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" application/vnd.google-apps.folder)
	if [ -z "$folders" ]; then
		log "no backup folders found in remote root dir"
		return
	fi

    backup_count=0
    deleted_count=0

	for folder in "${folders[@]}"
	do
		backup_date=$( echo $folder | gawk '{ print $3 }')
		backup_id=$( echo $folder | gawk '{ print $1 }')
	   	if [ $( daysBetween $DATE $backup_date ) -ge $MAX_DAYS_TO_RETAIN ] ;then  
			if gdriveDeleteFile $backup_id ; then
				log "removing remote folder: \"$backup_date\" id=\"$backup_id\""
                deleted_count=$((++deleted_count))
			else
				log "WARNING: could not delete folder $i from remote root directory $REMOTE_ROOT_DIR_ID"
				WARNING_FLAG=true
			fi
		fi
        backup_count=$((++backup_count))
	done

    sleep 60 # wait 60 seconds since qouta usage is not updated immediately after a deletion
    # check there is enough space for the next backup
    estimated_backup_size=$(du -sb $BACKUP_DIR |gawk '{print $1}')
    available_space=$(showAvailableStorageQouta)
    backups_pending=$(( MAX_DAYS_TO_RETAIN - (backup_count - deleted_count) ))
    estimated_space_required=$(( estimated_backup_size  * backups_pending ))

    log "$backup_count backups found, $deleted_count deleted, $backups_pending pending"

    log $(checkAvailableStorageQuota  "$estimated_space_required" "$available_space")

    if [ "$estimated_space_required" -gt "$available_space" ];then
        WARNING_FLAG=true
    fi

}

	    
function getGoogleAccessToken() { 
	local jwt_header=$(jwtHeader)
	local jwt_header_b64="$(echo -n "$jwt_header" | base64Encode)"

	local jwt_payload=$(jwtPayload)
	local jwt_payload_b64="$(echo -n "$jwt_payload" | base64Encode)"

	local unsigned_jwt="$jwt_header_b64.$jwt_payload_b64"

	local signature=$(echo -n "$unsigned_jwt" | signature | base64Encode)

	local jwt_assertion="${jwt_header_b64}.${jwt_payload_b64}.${signature}"

	# retrieve access token
	local response=$(curl --silent --data "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=$jwt_assertion" https://oauth2.googleapis.com/token )
	local at=$(echo "$response"|jq -r '.access_token')
	if [ -z "$at" ] || [ "$at" = "null" ];then
	 	echo "ouath error: " $(echo  "$response"|jq -r '.error_description' ) >&2
		return 1
	else
		echo $at	
	fi
}

function jwtHeader() { echo '{"alg":"RS256","typ":"JWT"}' ; }

function jwtPayload() { 
	local iat=$(date '+%s')
	local exp=$(($iat + 3600))

	cat  <<!
	{
		"iss": "$SERVICE_ACCOUNT_EMAIL",
		"scope": "https://www.googleapis.com/auth/drive.file",
		"aud": "https://oauth2.googleapis.com/token",
		"exp": $exp,
		"iat": $iat
	}
!
}

function base64Encode() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '=' ; }

function signature() { openssl dgst -binary -sha256 -sign <(jq -r '.private_key' < $SERVICE_ACCOUNT_CREDENTIALS_FILE ) ; }

# $1 = file id
# no output
function gdriveDeleteFile() {
	local response="$(curl --silent \
	--request DELETE \
	--header "Authorization: Bearer $AT" \
	--header 'Accept: application/json' \
	https://www.googleapis.com/drive/v3/files/$1
	)"
	if echo $response | gdriveCheckForErrors  ; then
		return 1 
	fi
}

# downloads a file from google drive 
# $1 id $2 output file name
function gdriveDownloadFile() {
        local gdrive_size=0
        local download_size=0
    
        # get the remote file size
		local response="$(
            curl  --silent \
            --header "Authorization: Bearer $AT" \
            --header 'Accept: application/json' \
            https://www.googleapis.com/drive/v3/files/${1}?fields=size
        )"
        if echo $response | gdriveCheckForErrors  ; then
            return 1 
        else
            gdrive_size=$(echo $response |jq -r '.size')
        fi

        # get the file
		curl -o $2 --silent \
		--header "Authorization: Bearer $AT" \
		--header 'Accept: application/json' \
        --compressed \
        https://www.googleapis.com/drive/v3/files/${1}?alt=media

        download_size=$(stat -c%s "$2")

        download_size="${download_size:-0}"
        gdrive_size="${gdrive_size:-0}"
        if [  "$download_size" -eq 0 ]; then
            errorExit "$2 download failed"
        fi

        if [ "$download_size" -eq "$gdrive_size" ] ; then
            log "downloaded $2: $download_size bytes"
        else
            errorExit "$2 download failed: expected $gdrive_size bytes got $download_size bytes"
        fi
}

# prints id of created folder and returns zero if successful
# $1 parent folder id $2 folder name
function gdriveCreateFolder() {
	local response="$(
		curl --silent \
		--header "Authorization: Bearer $AT" \
		--header 'Content-Type: application/json'  \
		--header 'Accept: application/json' \
		--data "{
			\"name\": \"$2\",
			\"mimeType\": \"application/vnd.google-apps.folder\",
			\"parents\": [ \"$1\" ]
		}"  \
		https://www.googleapis.com/drive/v3/files
	)"
	if echo $response | gdriveCheckForErrors  ; then
		return 1 
	else
		echo $response |jq -r '.id' 
	fi
}

# prints id mimeType name for files matching the regex
function gdriveListFiles() {

	if [ ! -z "$3" ];then
		local m=" and mimeType=\"$3\" "
	fi
	local response="$(curl --silent \
	--get https://www.googleapis.com/drive/v3/files?orderBy=name \
	--header "Authorization: Bearer $AT" \
	--header 'Accept: application/json' \
	--data-urlencode "q=parents in \"$1\" $m"
	)"

	if echo $response | gdriveCheckForErrors  ; then
		return 1 
	else
		echo "$response" |jq -r ".files[] | .id + \" \" + .mimeType + \" \" + .name | select(test(\"$2\"))"  
	fi
}

# returns true if http error code found in response and prints error message to STDERR
function gdriveCheckForErrors() {
	local e=$(jq -r '"\(.error.code)"+" "+.error.message')

	if [ -z "$e" ] || [[ "$e" =~ ^null ]]; then
		return  1 # no error found
	else
		echo $e >&2 # redirected to log
        if [ ! "$SILENT" ]; then
		    echo $e # show on screen
        fi
	fi
}

function gdriveUploadFile() {
	# random string to delimit sections in multipart data 
	local boundary="boundary_7a4cd99a13eaf0b5b10798a"
	local file="$1"
	local filename="$(basename $1)"
	local parent_id="$2"
	local mimeType="$3"

	response=$( 
	( cat  <<-! && cat $file && echo -en "\n--$boundary--" ) \
		|curl --silent \
		--request POST \
		--header "Authorization: Bearer $AT" \
		--header "Content-Type: multipart/related; boundary=$boundary" \
		--header "Cache-Control: no-cache" \
		--header "Tranfer-Encoding: chunked" \
		--upload-file - \
		"https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart" 
	--$boundary
	Content-Type: application/json; charset=UTF-8

	{ 
		"name": "$filename",
		"parents": ["$parent_id"] 
	}

	--$boundary
	Content-Type: $mimeType

!
)
	if echo $response | gdriveCheckForErrors  ; then
		return 1 
	else
		echo $response |jq -r '.id'
	fi
}

# returns available storage in bytes
function showAvailableStorageQouta() {
	local response=$(curl --silent \
	  'https://www.googleapis.com/drive/v3/about?fields=storageQuota' \
	  --header "Authorization: Bearer $AT" \
	  --header 'Accept: application/json' )
	if echo $response | gdriveCheckForErrors  ; then
		return 1 
	else
        echo $response |jq -r '(.storageQuota.limit|tonumber)-(.storageQuota.usage|tonumber)' 
	fi
}

# $1 = estimated back up size $2 = available storage quota
function checkAvailableStorageQuota() {
    echo $1 |gawk '{
    gb=1024*1024*1024

    if (avail > $1 )
        printf("%.2f GiB available, future space needed estimated to be %.2f GiB\n", avail/gb,$1/gb)  
    else
        printf("WARNING: %.2f GiB available, future space requirement estimated to be %.2f GiB\n", avail/gb,$1/gb)  

    }' avail=$2
}

function downloadRemoteArchiveFiles() {

        if [ ! -d "$BACKUP_DIR" ] && ! mkdir $BACKUP_DIR ;then
                errorExit "could not create $BACKUP_DIR"
        fi
        # get the folder id for the directory containing the archive files
        local folder_id="$(gdriveListFiles $REMOTE_ROOT_DIR_ID $DATE application/vnd.google-apps.folder  | awk '{print $1}' )"

        if [ -z "$folder_id"  ]; then
            errorExit "Can't find remote backup directory: $DATE"
        fi

        # get a list of the gzipped archives and download  them
        declare -A a="( $(gdriveListFiles $folder_id "${DATE}.*.gz$" application/gzip | awk '{ printf "[%s]=%s ", $3, $1  }') )"

        if [[ "$ARCHIVE_OPTION" =~ all|database ]];then
            key=${DATABASE_ARCHIVE_FILE##*/}
            id=${a[${key}]}
            log "downloading database archive file $id to $DATABASE_ARCHIVE_FILE"
            if ! gdriveDownloadFile $id $DATABASE_ARCHIVE_FILE ; then
                errorExit "remote download failed"
            fi  
        fi
        if [[ "$ARCHIVE_OPTION" =~ all|config ]];then
            key=${CONFIG_ARCHIVE_FILE##*/}
            id=${a[${key}]}
            log "downloading config archive file $id to $CONFIG_ARCHIVE_FILE"
            if ! gdriveDownloadFile $id $CONFIG_ARCHIVE_FILE ; then
                errorExit "remote download failed"
            fi  
        fi
        if [[ "$ARCHIVE_OPTION" =~ all|content ]];then
            key=${CONTENT_ARCHIVE_FILE##*/}
            id=${a[${key}]}
            log "downloading content archive file $id to $CONTENT_ARCHIVE_FILE"
            if ! gdriveDownloadFile $id $CONTENT_ARCHIVE_FILE ; then
                errorExit "remote download failed"
            fi  
        fi
}

function restoreDatabaseArchive() {
    
    if [ ! -f $DATABASE_ARCHIVE_FILE ]; then
        log "can't find $DATABASE_ARCHIVE_FILE"
        return 1
    fi

    log "unzipping $DATABASE_ARCHIVE_FILE"
    if ! gunzip $DATABASE_ARCHIVE_FILE ; then
        log "can't unzip $DATABASE_ARCHIVE_FILE"
        return 1
    fi

    local database=$(jq -r '.database.connection.database' $GHOST_CONFIG_FILE)
    local user=$(jq -r '.database.connection.user' $GHOST_CONFIG_FILE)
    local host=$(jq -r '.database.connection.host' $GHOST_CONFIG_FILE)

    # setting this env variable avoids supplying password on command line
    export MYSQL_PWD=$(jq -r '.database.connection.password' $GHOST_CONFIG_FILE)
    
    f="${DATABASE_ARCHIVE_FILE%.gz}"
    if [ ! -f "$f" ]; then
        log "can't open unzipped archive $f"
        return 1
    fi
    log "running $f on host: $host user: $user database: $db_name"
    mysql -h $host -u $user $database <  $f
}

function restoreConfigArchive() {
    log "unzippling $CONFIG_ARCHIVE_FILE to $GHOST_ROOT_DIR"
    gunzip -c $CONFIG_ARCHIVE_FILE > $GHOST_CONFIG_FILE
}

function restoreContentArchive() {
    log "extracting $CONTENT_ARCHIVE_FILE to $GHOST_ROOT_DIR"
    tar xf $CONTENT_ARCHIVE_FILE -C $GHOST_ROOT_DIR --same-owner
}

# main

# todo passphrase on restore
export SCRIPT=$(basename $0)
while getopts "rsw:l:b:t:f:p:m:g:c:a:R:o:d:" o; do
        case "$o" in
        s) export SILENT=true ;; # disable screen output
        l) export LOG_FILE=$OPTARG ;; 
        m) export MAX_DAYS_TO_RETAIN=$OPTARG ;; 
        b) export BACKUP_ROOT_DIR=${OPTARG%/} ;; 
        f) export FROM_EMAIL=$OPTARG ;;
        t) export TO_EMAIL=$OPTARG ;;
        a) export AWS_PROFILE=$OPTARG ;;
        w) export GHOST_ROOT_DIR=${OPTARG%/} ;;
        p) export PASSPHRASE=$OPTARG ;;
        g) export REMOTE_ROOT_DIR_ID=$OPTARG;; # google drive folder id
        c) export SERVICE_ACCOUNT_CREDENTIALS_FILE=$OPTARG;; # service account credentials file from https://console.developers.google.com/
        r) export REMOTE=true ;;
        R) export RESTORE=true;ARCHIVE_DATE=$OPTARG ;;
        o) export ARCHIVE_OPTION=$OPTARG ;;
        d) export DOWNLOAD=true;ARCHIVE_DATE=$OPTARG ;;
        *) usage ;;
        esac
done

if [ $# -eq 0 ] ; then
	usage
fi

if ! checkOptions ; then
    usage
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

#env 
export AT # google auth token
export WARNING_FLAG # when true send warning email about non critical errors
export SILENT

# working directory for backup files - when restoring use the date specified on the command line
if [ "$ARCHIVE_DATE" ];then
    DATE=$ARCHIVE_DATE
else
    DATE=$(date '+%Y-%m-%d') 
fi

GHOST_CONFIG_FILE="${GHOST_ROOT_DIR}/config.production.json"

if [ ! -r $GHOST_CONFIG_FILE ]; then
    errorExit "Can't read ghost config file: $GHOST_CONFIG_FILE"
fi

BACKUP_DIR=${BACKUP_ROOT_DIR}/${DATE}
DATABASE_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-database.sql.gz 
CONTENT_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-content.tar.gz 
CONFIG_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-json.gz 

if [ "$REMOTE" ]; then
	if [ ! -r "$SERVICE_ACCOUNT_CREDENTIALS_FILE" ] ; then
		errorExit "can't open credentials file: $SERVICE_ACCOUNT_CREDENTIALS_FILE"
	fi

	export SERVICE_ACCOUNT_EMAIL=$(jq -r ".client_email" < "$SERVICE_ACCOUNT_CREDENTIALS_FILE") 
	if [ -z "$SERVICE_ACCOUNT_EMAIL" ];then
		errorExit "can't read client_email from : $SERVICE_ACCOUNT_CREDENTIALS_FILE"
	fi
	if ! AT=$(getGoogleAccessToken) ;then
		errorExit "could not get access token"
	fi
fi

if [ ! -w $BACKUP_ROOT_DIR ]; then # both restore and backup options need to be able to write to this directory
    errorExit "Can't write to backup directory: $BACKUP_ROOT_DIR"
fi

# download backup archives
if [ "$DOWNLOAD" ] ; then
    log "downloading remote archive files"
    if  ! downloadRemoteArchiveFiles ; then
        errorExit "Could not download remote archive files"
    fi
    log "download complete"
    exit
fi


# restore ghost from backup
if [ "$RESTORE" ];then
    if [ "$REMOTE" ]; then 
        log "downloading remote archive files"
        if  ! downloadRemoteArchiveFiles ; then
            errorExit "Could not download remote archive files"
        fi
    fi

    log "Restoring ghost archive: $ARCHIVE_DATE"

    if [[ "$ARCHIVE_OPTION" =~ all|database ]] ; then
        if ! restoreDatabaseArchive ; then
            errorExit "could not restore database archive" 
        else
            log "database archive restored"
        fi
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|config ]]; then
        if ! restoreConfigArchive ; then
            errorExit "could not restore config archive" 
        else
            log "config archive restored"
        fi
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|content ]]; then
        if ! restoreContentArchive ; then
            errorExit "could not restore content archive" 
        else
            log "content archive restored"
        fi
    fi

    log "restore complete"
    exit
fi

# create backup
if [ ! -d $BACKUP_DIR ]; then
    if ! mkdir $BACKUP_DIR ; then
        errorExit "can't create backup directory: $BACKUP_DIR"
    fi
fi

echo "============================================" >>$LOG_FILE
log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT starting"

log "Creating database archive: $DATABASE_ARCHIVE_FILE"
if ! createDatabaseArchive ; then
    errorExit "could not create database archive"
fi

log "Creating content archive: $CONTENT_ARCHIVE_FILE"
if ! createContentArchive ; then
    errorExit "could not create content archive"
fi

log "Creating config archive: $CONFIG_ARCHIVE_FILE"
if ! createConfigArchive ; then
    errorExit "could not create config archive"
fi


if [ ! -z "$PASSPHRASE" ] ; then

    log "encrypting $CONFIG_ARCHIVE_FILE"
    gpg --symmetric --passphrase $PASSPHRASE --batch -o ${CONFIG_ARCHIVE_FILE}.gpg  $CONFIG_ARCHIVE_FILE && rm $CONFIG_ARCHIVE_FILE
    if [ $? -ne 0 ]; then
        errorExit "could not encrypt $CONFIG_ARCHIVE_FILE"
    fi

    log "encrypting $DATABASE_ARCHIVE_FILE"
    gpg --symmetric --passphrase $PASSPHRASE --batch -o ${DATABASE_ARCHIVE_FILE}.gpg  $DATABASE_ARCHIVE_FILE && rm $DATABASE_ARCHIVE_FILE
    if [ $? -ne 0 ]; then
        errorExit "could not encrypt $DATABASE_ARCHIVE_FILE"
    fi

fi

# remove old local files and exit 
if [ ! "$REMOTE" ];then
	log "removing local daily backups older than $MAX_DAYS_TO_RETAIN days old"
	deleteOldestDailyBackupsLocal
	completionMessages 

    exit # end of local back up process
fi

# remote storage
log "starting remote storage processing"
log "service account: $SERVICE_ACCOUNT_EMAIL"

if q=$(showAvailableStorageQouta) ; then
    log "$(echo $q|gawk '{  printf("Storage quota avaialble: %.2f GiB\n",$1/1024/1024/1024) }')"
else
    errorExit "could not access the Google Drive API: $q"
fi

# attempt to remove any remote backup dir(s) with today's date in case of reruns
ids="$(gdriveListFiles $REMOTE_ROOT_DIR_ID $DATE application/vnd.google-apps.folder  | awk '{print $1}' 2>/dev/null)"
if [ ! -z "$ids" ];then
    for i in ${ids[@]}; do
        if gdriveDeleteFile $i ; then
            log "existing \"$DATE\" folder  id=\"$i\" deleted"
        else
            log "WARNING: could not delete folder $i from backup root directory $REMOTE_ROOT_DIR_ID"
            WARNING_FLAG=true
        fi
        done 
fi

log "removing remote daily backups older than $MAX_DAYS_TO_RETAIN days old"
deleteOldestDailyBackupsRemote

# create a directory for today's backup files (YYYY-DD-MM)
if REMOTE_DIR_ID=$(gdriveCreateFolder "$REMOTE_ROOT_DIR_ID" "$DATE"); then
	log "backup dir created, name=\"$DATE\", id=\"$REMOTE_DIR_ID\""
else	
	errorExit "could not create backup dir $TODAY"
fi

# upload the backup files
readarray -t files < <(find $BACKUP_DIR -name '*.gz' -o -name '*.gpg' )
for i in "${files[@]}"
do
	if UPLOAD_FILE_ID=$(gdriveUploadFile $i $REMOTE_DIR_ID application/gzip); then
		log "$i uploaded, id=\"$UPLOAD_FILE_ID\""
	else
		errorExit "could not upload file $i to backup dir, id=\"$REMOTE_DIR_ID\""
	fi
done

log "removing local backup files from $BACKUP_DIR"
rm -rf $BACKUP_DIR
completionMessages
