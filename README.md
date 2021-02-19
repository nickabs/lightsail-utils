# lightsail utils 
utility scripts for Wordpress installations deployed on a linux AWS lightsail instance.

* wp-backup.sh: Create a daily archive of the wordpress database, systems files and uploaded content with an option to store the backups remotely on Google Drive
* lightsail-snapshot.sh: Enable automatic daily snapshots of your  AWS lightsail (this is an alternative to the AWS Lightsail _Automatic Snapshots_ feature, which is hard coded to retain 7 snapshots).
 
***
# wp-backup.sh
See usage statement for parameters.

The script creates 3 gzip archives and places them in a subdirectory named YYYY-YY-DD, e.g
```
2021-02-19/2021-02-19-database.sql.gz # mysql database dump
2021-02-19/2021-02-19-content.tar.gz # uploaded content (images etc)
2021-02-10/2021-02-19-system.tar.gz # system files, including plugins
```
note the system archive contains the WP config file (wp-config.php). This file contains the database access credentials in plain text.  There is an option to encrypt this archive file if you are going to keep it in a remote location.

## Remote storage - service accounts
The remote storage option will upload the backup archives to Google Drive using a [service account](https://cloud.google.com/iam/docs/service-accounts).  Service account are created in the API section of the [Google Developers Console](https://console.developers.google.com/apis) 

Service accounts are identified by an email address e.g example@project-id.iam.gserviceaccount.com and have their own storage quota on Google Drive (as of early 2021, the quota is 15 GiB)

limitations:
1. Service accounts can only access google drive files that they own  
1. The storage quota can't be increased
1. Service accounts can't login via a browser 

### service account storage
A result of the final limitation is that the only way to manage service account google drive data is via the [Google Drive API](https://developers.google.com/drive/api/v3/about-sdk).  

However, it is still possible to view the Google Drive data created by service accounts in your user account Drive if you specify and upload folder that was created by your user account and then shared with the service account (you can specify the shared folder id as a parameter to the script).

Note that if you use use your user google account to create a file in one of the backup directories that the script has created then the script will no longer be able to remove the directory once it becomes older than the maximum retention date specified at run time.  This is because when removing a folder Google Drive also removes all the files contained in the folder.  Since the service account is only permitted to remove files it owns, the parent directory can't be removed unless all the user created files have been removed first.

Note also that the backup files can't be removed by your Google user account (deleting the file from the shared drive just removes the link to the original file). 

As noted above you can't purchase additional Google Drive storage for a service account, so you are limited to storing as many daily backups as can be stored in the 15GiB storage allowed for these accounts.    The script will produce a warning if the estimated storage requirements exceed the available space.

### authentication
service accounts are associated with private/public key pairs and these are used to authenticate to Google.  The keys can be generated in the API console and need to be saved using as a JSON credential option on the machine where the script will run. 

The location of the credential file is specified at runtime.   

### authorisation
The service account email address and private key in the credentials file are used to authorise the account to access the Google Drive API using [Oauth2.0](https://developers.google.com/identity/protocols/oauth2/service-account).
![server to server authorisation flow](https://developers.google.com/identity/protocols/oauth2/images/flows/jwt.png)

the backup script creates a JWT access token that is sent to Google's Oauth 2.0 service.  Assuming Google can validate that the token was signed by the private key associated with the public key it has in its records it will return an access token.  The access token is valid for one hour and can be used by any application in possession to access the resources requested in the scope specified in the original JWT access request (the backup script requests the scope needed to read/write to the service account's Google Drive storage).

The service account can also be used to access Google Cloud Platform (GCP) resources and services and you therefore need to specify (or create) a GCP IAM profile when you create the account.  It is good practice to limit access to the minimum set of resources needed by the account to do its work, however, since Google Drive is part of Google Workspace and not GCP, there are no IAM permissions that apply to the Google Drive API.  There does not seem to be an obvious way to prevent service accounts that are onlin intended to be used for Google Drive access from also being used to access GCP services other than by creating a profile with an impossible to fulfil set of conditions.

### protecting your account 
Although the service account can't access your personal user data, anyone in possession of the service account's private key can access all the GCP resources allowed by the profile assigned to it - potentially allowing them to rack up unwanted bills - and of course they will also be able to access your backups.  You should learn about keeping your keys safe.

### dependencies

this script requires jq to parse the json returned by the Google APIs.  If jq is not avaialable for your distribution you can find installation instructions on the [github project](https://stedolan.github.io/jq/)

other than jq the script uses various linux utilities that will be found on any modern linux distro (it was developed on unbuntu 20.4)
***
# lightsail-snapshot.sh
this script creates a new lightsail instance snapshot and deletes the oldest snapshots up to the specified maximum number of retained snapshots.  See the usage statement for options.

## EXAMPLE
`lightsail-snapshot.sh -l /var/log/lightsail-snapshot/lightsail-snapshot.log -m 2 -b "Ubuntu-1GB-London-1-Auto" -i "Ubuntu-1GB-London-1" -a Admin`

## Dependencies
this script uses the [aws command line interface](https://aws.amazon.com/cli "aws cli") to manage lightsail instance snapshots.

You will need an IAM user with the following permissions:

* lightsail:CreateInstanceSnapshot
* lightsail:DeleteInstanceSnapshot
* lightsail:GetInstanceSnapshots

... and a [named profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html "AWS CLI named profiles") containing the access key for this account installed on the VM where the script is installed.  You can specify the profile name on the command line.

make sure you understand the security implications of storing access keys.

email notifications:

You need to configure AWS [SES](https://aws.amazon.com/ses/pricing/ "AWS SES pricing + free tier") mail if you want to use the email notification option. The IAM account will need ses:SendEmail permission.  

## Schedule a timer to run the script (file locations per Ubuntu 20.04)
create lightsail-lighthouse service unit:  /etc/systemd/system/lightsail-snapshot.service

```
[Unit]
Description=Service for lightsail-snapshot application

[Service]
EnvironmentFile=-/etc/environment
ExecStart=/bin/bash /root/utils/lightsail-snapshot.sh -l /root/lightsail-snapshot.sh.log -m 2 -b "Ubuntu-1GB-London-1-Auto" -i "Ubuntu-1GB-London-1" -a Admin
SyslogIdentifier=lightsail-snapshot
Restart=no
WorkingDirectory=/tmp
TimeoutStopSec=30
Type=oneshot

[Install]
WantedBy=multi-user.target
```

create a timer unit /etc/systemd/system/lightsail-snapshot.timer
```
[Unit]
Description=Timer for lightsail-snapshot.sh (AWS lightsail snapshot management)

[Timer]
# Run on Sunday at 2:10am
OnCalendar=Sun *-*-* 02:10:00
Persistent=true

[Install]
WantedBy=timers.target
```

the timer is associated with the timers target (this target sets up all timers that should be active after boot )
the service is associated with the multi-user target (services that should be active after a the system boots to multi user mode)

enabled service:

```
sudo systemctl enable lightsail-snapshot.service
sudo systemctl enable lightsail-snapshot.timer
```

test the service runs:
```
sudo systemctl start lightsail-snapshot.timer
sudo systemctl start lightsail-snapshot.service
```

check status:
```
systemctl status lightsail-snapshot.service
systemctl status lightsail-snapshot.timer
```

enable log rotation: /etc/logrotate.d/lightsail-snapshot

```
/var/log/lightsail-snapshot/*.log {
    rotate 14
    weekly
    missingok
}
```
---

***


