#!/usr/bin/env bash
# see https://github.com/nickabs/lightsail-utils

set -o pipefail
# ERR trap for subshells
set -o errtrace 
trap "errorExit process terminated" SIGTERM SIGINT SIGQUIT SIGKILL ERR

function usage() {
    echo "Usage: $SCRIPT -m archive|restore|retrieve -l log file -a archive directory -o all|config|content|database
        [ -g ghost dir ] (archive|restore mode: ghost installation directory containing ghost config file)
        [ -k keep days ] (archive mode: maximum number of daily archives to keep)
        [ -r -G google drive id -C credential config file for google service account] (remote storage options)
        [ -d YYYY-MM-DD ] (retrieve|restore date)
        [ -s (silent) ]
        [ -p passphrase ] (when specified this will be used as a key to encrypt the database and config archives )  
        [ -f email from -t email to -A aws profile name ] (send email using Amazon SES on completion)
        [ -x ] (local development installation)

        EXAMPLE

        1. archive ghost files and copy the archive to remote storage (when specifying remote storage the archives are managed in the specified google drive and the local archive files are deleted)

        $SCRIPT -m archive -l ghost.log -a /data/archives/ghost -g /var/www/ghost -k 7 -o all -r -G 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -C project123-f712345a860a.json

        2. archive ghost files to the local directory specified with -a and send an email after the script completes

        $SCRIPT -m archive -l ghost.log -a /data/archives/ghost -g /var/www/ghost -k7 -o all -r -f backup@example.com -t staff@example.com -A aws_ses_profile

        3. restore the config, content and database archives from 1st February 2022 
        $SCRIPT -m restore -l ghost.log -g /var/www/ghost -l -a /data/archives/ghost -d 2022-02-01 -o all

        4. retrieve the remote archive archives from 1st February 2022 but do not restore them (the archives are retrieved to the directory specified with -a)
        $SCRIPT -m retrieve -l ghost.log -a /data/archives/ghost -r -g 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -c project123-f712345a860a.json -d 2022-02-01 -o all

        see https://github.com/nickabs/lightsail-utils for more information
        " 1>&2
        exit 1
}

function checkOptions() {

    if [ "$DEV_INSTALL" ] && [ "$MODE" == "archive" ]; then
        echo -e "ERROR: archive mode can't be used on development installations"
        return 1
    fi

    if [ "$DEV_INSTALL" ] && [ "$MODE" == "restore" ] && [[ "$ARCHIVE_OPTION" =~ all|database ]]; then
        echo -e "ERROR: can't restore database or config files on development installations"
        return 1
    fi

    if ! [[ "$MODE" =~ ^archive$|^restore$|^retrieve$ ]]; then
        echo -e "ERROR: you must specify either archive, restore or retrieve with the mode (-m) option"
        return 1
    fi

	if [ ! "$LOG_FILE" ]; then
        echo -e "ERROR: you must specify a log file\n" >&2
		return 1
	fi
    
    if ! [[ "$ARCHIVE_OPTION" =~ ^all$|^config$|^database$|^content$ ]];then
        echo -e "ERROR: you must specify one of these options with the -o flag : all, config, database or content\n" >&2
        return 1
    fi

    if [  "$MODE" != "retrieve" ]; then
        if [ ! "$GHOST_ROOT_DIR" ]; then
            echo -e "ERROR: you must specify the ghost root directory when backing up or restoring\n" >&2
            return 1
        fi

    fi

    if [ ! "$ARCHIVE_ROOT_DIR" ]; then
        echo -e "ERROR: you must specify a local directory for the archive files\n" >&2
		return 1
	fi

    if [ "$MODE" != "archive" ] && [ "$MAX_DAYS_TO_KEEP" ]; then
            echo -e "ERROR: you can only use the -k option when in archive mode\n"
            return 1
    fi

    if [ "$GHOST_ROOT_DIR" == "$ARCHIVE_ROOT_DIR" ]; then
        echo -e "ERROR: can't create archive files in the ghost root directory\n" >&2 
        return 1
    fi

    if [ "$MODE" == "retrieve" ] && [ ! "$REMOTE" ];then
        echo -e "ERROR: retrieve mode can only be used with the -r (remote) parameters \n"
        return 1
    fi

    if [ "$REMOTE" ];then
        if [ -z "$REMOTE_ROOT_DIR_ID" ] || [ -z "$SERVICE_ACCOUNT_CREDENTIALS_FILE" ];then
            echo -e "ERROR: please specify the remote root directory id and a service account credentials file when using remote storage\n" >&2
            return 1
        fi
    fi

    if [[ "$MODE" =~ restore|retrieve ]]; then
        if [[ ! "$ARCHIVE_DATE" =~ [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] ]];then
            echo -e "ERROR: use the -d otion with an archive date formatted as YYYY-MM-DD when in $MODE mode\n" ; >&2
            return 1
        fi
    fi

	if [  "$FROM_EMAIL" ] || [ "$TO_EMAIL" ]; then
        if [ "$MODE" != "archive" ];then
			echo -e "ERROR: email notifications are only available when archiving data\n" >&2
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

    if [ "$PASSPHRASE" ] && [ "$MODE" == "content" ];then
        echo -e "ERROR: only the config and database files can be encrypted"
        exit 1
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

# the datbase functions only work on mysql installations
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
	# archive the content directory with archive paths relative to the content dir
	tar --exclude "*.log" -czf $CONTENT_ARCHIVE_FILE --directory $GHOST_CONTENT_DIR .
}

function createConfigArchive() {
	# copy the config Config file
	# use tar to create the archive so it can be restored with the same owner
    tar -czf $CONFIG_ARCHIVE_FILE --directory $GHOST_ROOT_DIR ${GHOST_CONFIG_FILE##*/}
}

# removes all directories older than max retention days - for local archives this is run *after* a archive has been created sucessfully
function deleteOldestDailyarchivesLocal() {
	local archive_date
	for d in ${ARCHIVE_ROOT_DIR}/????-??-??/ ; do
		archive_date=$(basename $d)
	   	if [ $( daysBetween $DATE $archive_date ) -ge $MAX_DAYS_TO_KEEP ] ;then  
			log "removing $d"
			if ! rm -rf $d ; then
				errorExit "error could not remove $d"
			fi
	   	fi
	done
}

# to maximise the use of space in the remote storage location the script will remove old archives before the new one is copied
function deleteOldestDailyarchivesRemote() {
	local folders folder archive_date archive_id archive_count estimated_archive_size available_space estimated_space_required archives_pending deleted_count
    
	# find folders named YYYY-MM-DD
	readarray -t folders < <(gdriveListFiles $REMOTE_ROOT_DIR_ID "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" application/vnd.google-apps.folder)
	if [ -z "$folders" ]; then
		log "no archive folders found in remote root dir"
		return
	fi

    archive_count=0
    deleted_count=0

	for folder in "${folders[@]}"
	do
		archive_date=$( echo $folder | awk '{ print $3 }')
		archive_id=$( echo $folder | awk '{ print $1 }')
	   	if [ $( daysBetween $DATE $archive_date ) -ge $MAX_DAYS_TO_KEEP ] ;then  
			if gdriveDeleteFile $archive_id ; then
				log "removing remote folder: \"$archive_date\" id=\"$archive_id\""
                deleted_count=$((++deleted_count))
			else
				log "WARNING: could not delete folder $i from remote root directory $REMOTE_ROOT_DIR_ID"
				WARNING_FLAG=true
			fi
		fi
        archive_count=$((++archive_count))
	done

    sleep 60 # wait 60 seconds since qouta usage is not updated immediately after a deletion
    # check there is enough space for the next archive
    estimated_archive_size=$(du -sb $ARCHIVE_DIR |awk '{print $1}')
    available_space=$(showAvailableStorageQouta)
    archives_pending=$(( MAX_DAYS_TO_KEEP - (archive_count - deleted_count) ))
    estimated_space_required=$(( estimated_archive_size  * archives_pending ))

    log "$archive_count archives found, $deleted_count deleted, $archives_pending pending"

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
	if [ -z "$at" ] || [ "$at" == "null" ];then
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

        # download_size=$(stat -c%s "$2") # not supported on mac
        download_size=$(wc -c "$2" |awk '{print $1}' ) 

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
# note that standard errors like "out of space" are returned by google as json, server errors are html
function gdriveCheckForErrors() {
    local response=$(cat -)
    local e
    
    e=$(echo $response | gawk '/<html>/ { print gensub(/.*<title>(.*)<\/title>.*/,"gdrive error: \\1","g") }')
    if [ -z "$e" ] || [[ "$e" =~ ^null ]]; then
        local e=$(jq -r '"\(.error.code)"+" "+.error.message')
    fi

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
    echo $1 |awk '{
    gb=1024*1024*1024

    if (avail > $1 )
        printf("%.2f GiB available, future space needed estimated to be %.2f GiB\n", avail/gb,$1/gb)  
    else
        printf("WARNING: %.2f GiB available, future space requirement estimated to be %.2f GiB\n", avail/gb,$1/gb)  

    }' avail=$2
}

# download files 
function downloadRemoteArchiveFiles() {
    local encrypted=""
    local target_file=""

    if [ ! -d "$ARCHIVE_DIR" ] && ! mkdir $ARCHIVE_DIR ;then
        errorExit "could not create $ARCHIVE_DIR"
    fi
    
    # get the folder id for the directory containing the archive files
    local folder_id="$(gdriveListFiles $REMOTE_ROOT_DIR_ID $DATE application/vnd.google-apps.folder  | awk '{print $1}' )"

    if [ -z "$folder_id"  ]; then
        errorExit "Can't find remote archive directory: $DATE"
    fi

    # get a list of the gzipped archives 
    # The array is indexed by file name and the value is the google fileid
    declare -A a="( $(gdriveListFiles $folder_id "${DATE}.*.gz.*$" application/gzip | awk '{ printf "[%s]=%s ", $3, $1  }') )"

    # if the returned filenames have  *.gpg suffixes then they are encrypted
    if [[ "${!a[@]}" =~ $ENCRYPTED_FILE_SUFFIX ]]; then
        encrypted=true
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|database ]];then

        if [ $encrypted ];then
            # download to a file with the .gpg suffix
            target_file="${DATABASE_ARCHIVE_FILE}${ENCRYPTED_FILE_SUFFIX}"
        else
            target_file="${DATABASE_ARCHIVE_FILE}"
        fi
        key=${target_file##*/} # remove parent dirs
        id=${a[${key}]}
        
        log "downloading database archive file $id to $target_file"
        if ! gdriveDownloadFile $id $target_file ; then
            errorExit "remote download failed"
        fi  
        # check if the file is encrypted and decrypt if needed
        decryptArchive "$DATABASE_ARCHIVE_FILE"
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|config ]];then

        if [ $encrypted ];then
            # download to a file with the .gpg suffix
            target_file="${CONFIG_ARCHIVE_FILE}${ENCRYPTED_FILE_SUFFIX}"
        else
            target_file="$CONFIG_ARCHIVE_FILE"
        fi
        key=${target_file##*/}
        id=${a[${key}]}
        
        log "downloading config archive file $id to $target_file"
        if ! gdriveDownloadFile $id $target_file ; then
            errorExit "remote download failed"
        fi  
        # check if the file is encrypted and decrypt if needed
        decryptArchive "$CONFIG_ARCHIVE_FILE"
    fi

    # the content file is not encrypted
    if [[ "$ARCHIVE_OPTION" =~ all|content ]];then
        key=${CONTENT_ARCHIVE_FILE##*/}
        id=${a[${key}]}
        log "downloading content archive file $id to $CONTENT_ARCHIVE_FILE"
        if ! gdriveDownloadFile $id $CONTENT_ARCHIVE_FILE ; then
            errorExit "remote download failed"
        fi  
    fi
}

function decryptArchive() {
    local file=$1
    local encrypted=""

    # check for an encrpted file
    if [ -f ${file}${ENCRYPTED_FILE_SUFFIX} ] ; then
        encrypted=true
    fi
   
    if [ ! $encrypted ]; then
        if [ "$PASSPHRASE" ] ;then
            log "WARNING: passcode supplied but unecrypted archive found: $file"
        fi
        return
    else 
        if [ -z "$PASSPHRASE" ]; then
            if [ "$MODE" == "restore" ]; then
                errorExit "encrypted file $file found but no passcode supplied to decrypt it"
            else 
                # when mode is "retrieve", download the file with out decrypting
                log "WARNING: encrypted file $file found but no passphrase supplied to decrypt it"
                return
            fi
        fi
    fi

    if ! gpg --decrypt --passphrase $PASSPHRASE --batch ${file}${ENCRYPTED_FILE_SUFFIX} > $file ; then
        log "could not decrypt file - check your passphrase"
        return 1
    else
        log "file  decrypted: $DATABASE_ARCHIVE_FILE"
    fi
}

function restoreDatabaseArchive() {
    if [ ! -f $DATABASE_ARCHIVE_FILE ]; then
        log "can't find $DATABASE_ARCHIVE_FILE"
        return 1
    fi

    log "unzipping $DATABASE_ARCHIVE_FILE"
    if ! gunzip -k $DATABASE_ARCHIVE_FILE ; then
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
    log "running $f on host: $host user: $user database: $database"
    mysql -h $host -u $user $database <  $f
}

function restoreConfigArchive() {
    log "extracting $CONFIG_ARCHIVE_FILE to $GHOST_CONFIG_FILE"
    tar -xf $CONFIG_ARCHIVE_FILE --directory $GHOST_ROOT_DIR --same-owner 
}

function restoreContentArchive() {
    log "extracting $CONTENT_ARCHIVE_FILE to $GHOST_CONTENT_DIR"

    if [ ! -d "$GHOST_CONTENT_DIR" ] ; then
        
        if ! mkdir $GHOST_CONTENT_DIR ; then
            errorLog "content directory missing, failed to create new directory: $GHOST_CONTENT_DIR"
        else
            log "content directory missing, created new directory: $GHOST_CONTENT_DIR"
        fi
        
    fi
    if [ "$DEV_INSTALL" ]; then
        log "development installation: note that the themes, logs and data directories are not restored when restoring to a local development installation"
        tar xf $CONTENT_ARCHIVE_FILE --directory $GHOST_CONTENT_DIR --exclude ./themes --exclude ./data --exclude ./logs
    else
        tar xf $CONTENT_ARCHIVE_FILE --directory $GHOST_CONTENT_DIR --same-owner
    fi
}

#
# main
#
export SCRIPT=$(basename $0)
while getopts "xrsm:l:k:a:g:G:C:f:t:A:p:d:o:" o; do
        case "$o" in
        m) export MODE=$OPTARG ;; 
        l) export LOG_FILE=$OPTARG ;; 
        a) export ARCHIVE_ROOT_DIR=${OPTARG%/} ;; 
        g) export GHOST_ROOT_DIR=${OPTARG%/} ;;
        k) export MAX_DAYS_TO_KEEP=$OPTARG ;; 
        r) export REMOTE=true ;;
        G) export REMOTE_ROOT_DIR_ID=$OPTARG;; # google drive folder id
        C) export SERVICE_ACCOUNT_CREDENTIALS_FILE=$OPTARG;; # service account credentials file from https://console.developers.google.com/
        f) export FROM_EMAIL=$OPTARG ;;
        t) export TO_EMAIL=$OPTARG ;;
        A) export AWS_PROFILE=$OPTARG ;;
        p) export PASSPHRASE=$OPTARG ;;
        s) export SILENT=true ;; # disable screen output
        o) export ARCHIVE_OPTION=$OPTARG ;;
        d) export ARCHIVE_DATE=$OPTARG ;;
        x) export DEV_INSTALL=true;;
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

#
# set env vars
#
export AT # google auth token
export WARNING_FLAG # when true send warning email about non critical errors
export SILENT
export ENCRYPTED_FILE_SUFFIX=".gpg"
export DATE

# working directory for archive files - when restoring|retrieving use the date specified on the command line
if [ "$ARCHIVE_DATE" ];then
    DATE=$ARCHIVE_DATE
else
    DATE=$(date '+%Y-%m-%d') 
fi

export ARCHIVE_DIR=${ARCHIVE_ROOT_DIR}/${DATE}
export DATABASE_ARCHIVE_FILE=$ARCHIVE_DIR/${DATE}-database.sql.gz 
export CONTENT_ARCHIVE_FILE=$ARCHIVE_DIR/${DATE}-content.tar.gz 
export CONFIG_ARCHIVE_FILE=$ARCHIVE_DIR/${DATE}-json.tar.gz 
export GHOST_CONFIG_FILE

if [ "$DEV_INSTALL" ]; then
    GHOST_CONFIG_FILE="${GHOST_ROOT_DIR}/config.development.json"
else
    GHOST_CONFIG_FILE="${GHOST_ROOT_DIR}/config.production.json"
fi

# get credentials for remote storage
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


echo "============================================" >>$LOG_FILE
log $(printf "%s %s starting $SCRIPT")

#
# download archives from remote location 
#
if [[ "$MODE" =~ retrieve|restore ]] && [ "$REMOTE" ] ; then
    log "downloading remote archive files"
    if  ! downloadRemoteArchiveFiles ; then
        errorExit "Could not download remote archive files"
    fi

    log "download complete"

    # exit if in retrieve mode
    if [ "$MODE" == "retrieve" ]; then 
        exit
    fi
fi

#
# get the ghost config file (contains the database credentials and location of content dir
#
if [ "$MODE" == "restore" ]; then

    # if in restore mode and the config file is included in the archives to be restored,
    # the script assumes this is the config that should be used to find the location of the content and database.
    # Restore the config file now so the config parameters are used to set the ghost config variables below
    if [[ "$ARCHIVE_OPTION" =~ all|config ]]; then
        decryptArchive "$CONFIG_ARCHIVE_FILE"
        if ! restoreConfigArchive ; then
            errorExit "could not restore config archive" 
        else
            log "config archive restored"
        fi
    fi

    if [ ! -r "$GHOST_CONFIG_FILE" ];then
        errorExit "Can't find ghost config: $GHOST_CONFIG_FILE"
    fi
fi

# get the location of the content directory and database credentials from config
GHOST_CONTENT_DIR=$(jq -r ".paths.contentPath" < $GHOST_CONFIG_FILE)
GHOST_CONTENT_DIR=${GHOST_CONTENT_DIR%/} # in case there is a trailing / then remove it
if [[ $GHOST_CONTENT_DIR =~ ^[^/] ]];then # add root directory if content dir is relative
    GHOST_CONTENT_DIR=${GHOST_ROOT_DIR}/$GHOST_CONTENT_DIR
fi

if [ ! -w $ARCHIVE_ROOT_DIR ]; then # both restore and archive options need to be able to write to this directory
    errorExit "Can't write to archive directory: $ARCHIVE_ROOT_DIR"
fi

#
# if restoring, restore from archive and then exit
# if the config file was requested it was already restored above
#
if [ "$MODE" == "restore" ] ; then
    log "Restoring ghost archive: $ARCHIVE_DATE"

    if [[ "$ARCHIVE_OPTION" =~ all|database ]] ; then
        decryptArchive "$DATABASE_ARCHIVE_FILE"
        if ! restoreDatabaseArchive ; then
            errorExit "could not restore database archive" 
        else
            log "database archive restored"
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

#
# create archives
#
if [ "$MODE" == "archive" ] ; then
    if [ ! -d $ARCHIVE_DIR ]; then
        if ! mkdir $ARCHIVE_DIR ; then
            errorExit "can't create archive directory: $ARCHIVE_DIR"
        fi
    fi

    echo "============================================" >>$LOG_FILE
    log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT starting"

    if [[ "$ARCHIVE_OPTION" =~ all|database ]];then
        log "Creating database archive: $DATABASE_ARCHIVE_FILE"
        if ! createDatabaseArchive ; then
            errorExit "could not create database archive"
        fi
        if [ ! -z "$PASSPHRASE" ] ; then
            log "encrypting $DATABASE_ARCHIVE_FILE"
            gpg --symmetric --passphrase $PASSPHRASE --batch -o ${DATABASE_ARCHIVE_FILE}.gpg  $DATABASE_ARCHIVE_FILE && rm $DATABASE_ARCHIVE_FILE
            if [ $? -ne 0 ]; then
                errorExit "could not encrypt $DATABASE_ARCHIVE_FILE"
            fi
        fi
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|content ]];then

        log "Creating content archive: $CONTENT_ARCHIVE_FILE"
        if [ ! -d "$GHOST_CONTENT_DIR" ]; then
            errorExit "Can't find ghost content directory: $GHOST_CONTENT_DIR"
        fi
        if ! createContentArchive ; then
            errorExit "could not create content archive"
        fi
    fi

    if [[ "$ARCHIVE_OPTION" =~ all|config ]];then
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
        fi
    fi

    # remove old local files and exit 
    if [ ! "$REMOTE" ];then
        log "removing local daily archives older than $MAX_DAYS_TO_KEEP days old"
        deleteOldestDailyarchivesLocal
        completionMessages 

        exit # end of local back up process
    fi

    # remote storage
    log "starting remote storage processing"
    log "service account: $SERVICE_ACCOUNT_EMAIL"

    if q=$(showAvailableStorageQouta) ; then
        log "$(echo $q|awk '{  printf("Storage quota avaialble: %.2f GiB\n",$1/1024/1024/1024) }')"
    else
        errorExit "could not access the Google Drive API: $q"
    fi

    # attempt to remove any remote archive dir(s) with today's date in case of reruns
    ids="$(gdriveListFiles $REMOTE_ROOT_DIR_ID $DATE application/vnd.google-apps.folder  | awk '{print $1}' 2>/dev/null)"
    if [ ! -z "$ids" ];then
        for i in ${ids[@]}; do
            if gdriveDeleteFile $i ; then
                log "existing \"$DATE\" folder  id=\"$i\" deleted"
            else
                log "WARNING: could not delete folder $i from archive root directory $REMOTE_ROOT_DIR_ID"
                WARNING_FLAG=true
            fi
            done 
    fi

    log "removing remote daily archives older than $MAX_DAYS_TO_KEEP days old"
    deleteOldestDailyarchivesRemote

    # create a directory for today's archive files (YYYY-DD-MM)
    if REMOTE_DIR_ID=$(gdriveCreateFolder "$REMOTE_ROOT_DIR_ID" "$DATE"); then
        log "archive dir created, name=\"$DATE\", id=\"$REMOTE_DIR_ID\""
    else	
        errorExit "could not create archive dir $TODAY"
    fi

    # upload the archive files
    readarray -t files < <(find $ARCHIVE_DIR -name '*.gz' -o -name '*.gpg' )
    for i in "${files[@]}"
    do
        if UPLOAD_FILE_ID=$(gdriveUploadFile $i $REMOTE_DIR_ID application/gzip); then
            log "$i uploaded, id=\"$UPLOAD_FILE_ID\""
        else
            errorExit "could not upload file $i to archive dir, id=\"$REMOTE_DIR_ID\""
        fi
    done

    log "removing local archive files from $ARCHIVE_DIR"

    rm -rf $ARCHIVE_DIR
    completionMessages
fi
