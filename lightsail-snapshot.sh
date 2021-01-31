#!/bin/bash
# maintain a set of lightsail instance snapshots
# dependencies:
#   awscli
#   if using email alerts the account must be configured for SES and you must use validated email addresses

trap "error_exit process terminated" SIGTERM SIGINT SIGQUIT SIGKILL

function usage() {
    echo "Usage: $SCRIPT  -l log file -b basename -m max snapshots -i lightsail instance name -a aws profile [ -s (silent) ] [ -f email from -t  email to ]

    - new snapshots will be named basename_YYYY_MMTDD_HH_MI
    - the most recent snapshots matching this pattern will be retained up to the max specified
    - optional email alert sent via SES (email addresses must be validated)
    " 1>&2; exit 1;
}

function isRoot() {
    if [ "$(whoami)" != 'root' ]; then
        return 1
    else 
        return 0
    fi
}

function log() {
    echo LOG: "$@" >> $LOG_FILE
    if [ ! "$SILENT" ]; then
        echo LOG: "$@"
    fi
}

function error_exit() {
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

function delete_snapshot() {
     aws lightsail delete-instance-snapshot --instance-snapshot $1 --output json  --profile $AWS_PROFILE  >> $LOG_FILE
}

function create_snapshot() {
     aws lightsail create-instance-snapshot --instance-name $1 --instance-snapshot-name $2 --output json --profile $AWS_PROFILE >> $LOG_FILE
}

function pending_snapshots() {
    aws lightsail get-instance-snapshots --output yaml --profile Admin |grep pending >/dev/null 
}

function email(){
    aws ses send-email --from $FROM_EMAIL --subject "$@" --text "see $LOG_FILE for more info"  --to $TO_EMAIL --profile $AWS_PROFILE >/dev/null
}

function snapshot_query() {
    gawk ' BEGIN { 
        ct=0 
        name="name"
        createdAt="createdAt"
        fromInstanceName="fromInstanceName"
        createdAtDt="createdAtDt"
    }

    function write_log(msg) {
        if(log_file)
            printf("LOG: %s", msg) >> log_file
    }

    /^ *name: / { 
            snapshots[ct][name]=$2 
    }

    /^ *createdAt: / { 
        date=substr($2,2,26) 
        tmp=date
        gsub("[T:-]"," ",tmp)
        snapshots[ct][createdAt]=date
        dt = mktime(sprintf("%s 0",tmp))
        snapshots[ct][createdAtDt]=dt
    }

    /^ *fromInstanceName: / { 
            snapshots[ct][fromInstanceName]=$2 }

    /^-/ { ct++ }

    { next }

    END {
            oldest=0
            o_ct=ct
            for (i=1; i <= o_ct ; i++) {
                if (snapshots[i][name] ~ sprintf("^%s.*",snapshot_base_name) && snapshots[i][fromInstanceName]==instance_name) {
                    write_log(sprintf("matching snapshot found: name %s, created %s, instance name %s\n", snapshots[i][name] , snapshots[i][createdAt] , snapshots[i][fromInstanceName]))
                    if (snapshots[i][createdAtDt]<=oldest || oldest ==0)
                        oldest=snapshots[i][createdAtDt]
                }
                else {
                    write_log(sprintf("snapshot skipped (no match): name %s, created %s, instance name %s\n", snapshots[i][name] , snapshots[i][createdAt] , snapshots[i][fromInstanceName]))
                    delete snapshots[i]
                    ct--
                }
             }

            asort(snapshots)

            if (opt=="count") 
                print ct

            for (i=1; i<=ct ; i++) {
                if (snapshots[i][createdAtDt]==oldest && opt=="oldest")
                        print snapshots[i][name]
            }
    }' instance_name=$INSTANCE_NAME snapshot_base_name=$SNAPSHOT_BASE_NAME opt=$1 log_file=$2

}

# main
export SCRIPT=$(basename $0)
while getopts "l:b:i:m:a:f:t:s" o; do
        case "$o" in
        s) SILENT=true ;; # disable screen output
        l) LOG_FILE=$OPTARG ;; 
        b) SNAPSHOT_BASE_NAME=$OPTARG ;; 
        i) INSTANCE_NAME=$OPTARG ;; 
        m) MAX_SNAPSHOTS=$OPTARG ;; 
        a) AWS_PROFILE=$OPTARG ;;
        f) FROM_EMAIL=$OPTARG ;;
        t) TO_EMAIL=$OPTARG ;;
        *) usage ;;
        esac
done

if [ ! "$LOG_FILE" ] || [ ! "$SNAPSHOT_BASE_NAME" ] || [ ! "$INSTANCE_NAME" ] || [ ! "$MAX_SNAPSHOTS" ] || [ ! "$AWS_PROFILE" ];then
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
    error_exit "this script must be run as root"
fi

if touch "$LOG_FILE" 2>/dev/null ;then
    exec 2>>$LOG_FILE
else
    echo "$SCRIPT: ERROR exit: can't write to log file $LOG_FILE" 2>&1
    exit -1
fi

DATE=$(date '+%Y-%m-%d %H:%M:%S')

echo "============================================" >>$LOG_FILE
log $(printf "%s %s starting" "$DATE" "$SCRIPT")

if pending_snapshots ; then
     error_exit "snapshot already in progress. Exiting" 
fi

SNAPSHOT_COUNT=$(aws lightsail get-instance-snapshots --profile $AWS_PROFILE --output yaml|snapshot_query count $LOG_FILE)
log "$SNAPSHOT_COUNT matching snapshots found (max allowed = $MAX_SNAPSHOTS)" 

NEW_SNAPSHOT=${SNAPSHOT_BASE_NAME}-"$(date '+%Y-%m-%dT%H-%M-%S')"
log "creating a new snapshot $NEW_SNAPSHOT" 
if ! create_snapshot $INSTANCE_NAME $NEW_SNAPSHOT; then
       error_exit "could not create snapsnot $NEW_SNAPSHOT of $INSTANCE_NAME"
fi

if [ "$SNAPSHOT_COUNT" -ge "$MAX_SNAPSHOTS" ];then
    let  "nuber_of_deletions = $SNAPSHOT_COUNT - $MAX_SNAPSHOTS +1"
    log "deleting x$nuber_of_deletions oldest snapshots"
    ct=0
    SNAPSHOT=""
    while [ $ct -lt $nuber_of_deletions ];do
        SNAPSHOT=$(aws lightsail get-instance-snapshots --profile $AWS_PROFILE --output yaml|snapshot_query oldest)  
        log "deleting snapshot : $SNAPSHOT "
        if ! delete_snapshot "$SNAPSHOT"; then
            error_exit "delete snapshot failed on: $SNAPSHOT "
        fi
        let ct=ct+1
    done
fi
log "$(date '+%Y-%m-%d %H:%M:%S') $SCRIPT completed"

if [ "$EMAIL" ];then
    if ! email "$SCRIPT: completed without errors" ; then
        error_exit "could not send email"
    fi
fi
