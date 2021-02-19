#!/usr/bin/env bash
# see https://github.com/nickabs/lightsail-utils

set -o pipefail
# ERR trap for subshells
set -o errtrace 
trap "errorExit process terminated" SIGTERM SIGINT SIGQUIT SIGKILL ERR

function usage() {
    echo "Usage: $SCRIPT  -l log file -w wordpress dir -b backup dir -m days (max daily backups to retain)
        [ -s (silent) ]
        [ -p passphrase ] (when specified this will be used as a key to encrypt the systems archive )
        [ -f email from -t email to -a aws profile name ]
		[ -r remote storage -g google drive id -c credential json file for service account]
		when specifying remote storage the backups are managed in the specified google drive and the local copy is deleted.

        e.g:
        $SCRIPT -w /var/www/wordpress -l wp.log -b /data/backups/wordpress -m 7 -r -g 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -c project123-f712345a860a.json -f lightsail-snapshot@smallworkshop.co.uk -t nick.abson@googlemail.com -a LightsailSnapshotAdmin
        " 1>&2; exit 1;
}

function checkOptions() {
	if [ ! "$LOG_FILE" ] || [ ! "$WP_ROOT_DIR" ]  || [ ! "$BACKUP_ROOT_DIR" ] || [ ! $MAX_DAYS_TO_RETAIN ]; then
		return 1
	fi

	if [  "$FROM_EMAIL" ] || [ "$TO_EMAIL" ]; then
		if [ ! "$FROM_EMAIL" ] || [ ! "$TO_EMAIL" ]; then
			echo "specify both from and to emails" >&2
			return 1
		fi
		if [ ! "$AWS_PROFILE" ]; then
			echo "specify an AWS CLI profile when using the email option" >&2
			return 1
		fi
		EMAIL=true
	fi

    if [ "$REMOTE" ];then
        if [ -z "$REMOTE_ROOT_DIR_ID" ] || [ -z "$SERVICE_ACCOUNT_CREDENTIALS_FILE" ];then
            echo "please specify the remote root directory id and a service account credentials file when using remote storage" >&2
            return 1
        fi
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
	log "$SCRIPT: ERROR with status code $exit_status : $@ "
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
		msg="$SCRIPT: WARNING: completed with errors"
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
	local db_name=$(gawk 'BEGIN {RS=";" } /DB_NAME/ {print gensub(/.*,[ \t]*\047(.*)\047[ \t]*)/,"\\1","g")}' < $WP_CONFIG_FILE)
	local user=$(gawk 'BEGIN {RS=";" } /DB_USER/ {print gensub(/.*,[ \t]*\047(.*)\047[ \t]*)/,"\\1","g")}' < $WP_CONFIG_FILE)
	local host=$(gawk 'BEGIN {RS=";" } /DB_HOST/ {print gensub(/.*,[ \t]*\047(.*)\047[ \t]*)/,"\\1","g")}' < $WP_CONFIG_FILE)

    # setting this env variable avoids supplying password on command line
    export MYSQL_PWD=$(gawk 'BEGIN {RS=";" } /DB_PASSWORD/ {print gensub(/.*,[ \t]*\047(.*)\047[ \t]*)/,"\\1","g")}' < $WP_CONFIG_FILE)
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

# removes all directories older than max retention days
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


function deleteOldestDailyBackupsRemote() {
	local folders folder backup_date backup_id backup_count estimated_backup_size available_space estimated_space_required backups_pending
    
	# find folders named YYYY-MM-DD
	readarray -t folders < <(gdriveListFiles $REMOTE_ROOT_DIR_ID "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]" application/vnd.google-apps.folder)
	if [ -z "$folders" ]; then
		log "no backup folders found in remote root dir"
		return
	fi

    backup_count=0

	for folder in "${folders[@]}"
	do
		backup_date=$( echo $folder | gawk '{ print $3 }')
		backup_id=$( echo $folder | gawk '{ print $1 }')
	   	if [ $( daysBetween $DATE $backup_date ) -ge $MAX_DAYS_TO_RETAIN ] ;then  
			if gdriveDeleteFile $backup_id ; then
				log "removing remote folder: \"$backup_date\" id=\"$backup_id\""
			else
				log "WARNING: could not delete folder $i from remote root directory $REMOTE_ROOT_DIR_ID"
				WARNING_FLAG=true
                backup_count=$((++backup_count))
			fi
        else
            backup_count=$((++backup_count))
		fi
	done
    # check there is enough space for the next backup
    estimated_backup_size=$(du -sb $BACKUP_DIR |gawk '{print $1}')
    available_space=$(showAvailableStorageQouta)
    backups_pending=$(( MAX_DAYS_TO_RETAIN - backup_count ))
    estimated_space_required=$(( estimated_backup_size  * backups_pending ))

    log "$backup_count backups found, $backups_pending pending"

    log $(checkAvailableStorageQuota  "$estimated_space_required" "$available_space")

    if [ "$estimated_space_required" -gt "$available_space" ];then
        WARNING=true
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

# $1 parent folder id $2 folder name
# prints id of created folder and returns zero if successful
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

# $1 = parent dir $2 = regex match pattern [ $3 = mimeType ]
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
	( cat  <<-! && cat $file && echo -en "\n\n--$boundary--\n" ) \
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
        printf("%.2f GB available, future space needed estimated to be %.2f GB\n", avail/gb,$1/gb)  
    else
        printf("WARNING: %.2f GB available, future space requirement estimated to be %.2fGB\n", avail/gb,$1/gb)  

    }' avail=$2
}

# main
export SCRIPT=$(basename $0)
while getopts "rsw:l:b:t:f:p:m:g:c:a:" o; do
        case "$o" in
        s) export SILENT=true ;; # disable screen output
        l) export LOG_FILE=$OPTARG ;; 
        m) export MAX_DAYS_TO_RETAIN=$OPTARG ;; 
        b) export BACKUP_ROOT_DIR=${OPTARG%/} ;; 
        f) export FROM_EMAIL=$OPTARG ;;
        t) export TO_EMAIL=$OPTARG ;;
        a) export AWS_PROFILE=$OPTARG ;;
        w) export WP_ROOT_DIR=${OPTARG%/} ;;
        p) export PASSPHRASE=$OPTARG ;;
        g) export REMOTE_ROOT_DIR_ID=$OPTARG;; # google drive folder id
        c) export SERVICE_ACCOUNT_CREDENTIALS_FILE=$OPTARG;; # service account credentials file from https://console.developers.google.com/
        r) export REMOTE=true ;;
        *) usage ;;
        esac
done

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

#env checks
export AT # google auth token
export WARNING_FLAG # when true send warning email about non critical errors
export SILENT
DATE=$(date '+%Y-%m-%d') # working directory for backup files

WP_CONFIG_FILE="${WP_ROOT_DIR}/wp-config.php"

if [ ! -r $WP_CONFIG_FILE ]; then
    errorExit "Can't read WP config file: $WP_CONFIG_FILE"
fi

if [ ! -w $BACKUP_ROOT_DIR ]; then
    errorExit "Can't write to backup directory: $BACKUP_ROOT_DIR"
fi

BACKUP_DIR=${BACKUP_ROOT_DIR}/${DATE}

if [ ! -d $BACKUP_DIR ]; then
    if ! mkdir $BACKUP_DIR ; then
        errorExit "can't create backup directory: $BACKUP_DIR"
    fi
fi

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

DATABASE_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-database.sql.gz 
CONTENT_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-content.tar.gz 
SYSTEM_ARCHIVE_FILE=$BACKUP_DIR/${DATE}-system.tar.gz 

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

log "Creating system archive: $SYSTEM_ARCHIVE_FILE"
if ! createSystemArchive ; then
    errorExit "could not create system archive"
fi

# remove old local files and exit 
if [ ! "$REMOTE" ];then
	log "removing local daily backups older than $MAX_DAYS_TO_RETAIN days old"
	deleteOldestDailyBackupsLocal
	completionMessages
	exit
fi
# remote storage
log "starting remote storage processing"
log "service account: $SERVICE_ACCOUNT_EMAIL"

if q=$(showAvailableStorageQouta) ; then
    log "$(echo $q|gawk '{  printf("Storage quota avaialble: %.2f MB\n",$1/1024/1024/1024) }')"
else
    errorExit "could not access the Google Drive API: $q"
fi

# attempt to remove backup dir(s) with today's date in case of reruns
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

# create a directory for today's backup files (YYYY-DD-MM)
if REMOTE_DIR_ID=$(gdriveCreateFolder "$REMOTE_ROOT_DIR_ID" "$DATE"); then
	log "backup dir created, name=\"$DATE\", id=\"$REMOTE_DIR_ID\""
else	
	errorExit "could not create backup dir $TODAY"
fi

# upload the backup files
readarray -t files < <(find $BACKUP_DIR -name '*.gz')
for i in "${files[@]}"
do
	if UPLOAD_FILE_ID=$(gdriveUploadFile $i $REMOTE_DIR_ID application/gzip); then
		log "$i uploaded, id=\"$UPLOAD_FILE_ID\""
	else
		errorExit "could not upload file $i to backup dir, id=\"$REMOTE_DIR_ID\""
	fi
done

log "removing remote daily backups older than $MAX_DAYS_TO_RETAIN days old"
deleteOldestDailyBackupsRemote

log "removing local backup files from $BACKUP_DIR"
rm -rf $BACKUP_DIR
completionMessages
