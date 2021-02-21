# lightsail utils 
utility scripts for Wordpress websites deployed on a linux [AWS Lightsail](https://aws.amazon.com/lightsail/) instance.

* [wp-backup.sh](https://github.com/nickabs/lightsail-utils/wiki/_new#wp-backupsh): Create a daily archive of Wordpress database, systems files and uploaded content with an option to store the backups remotely on Google Drive
* [lightsail-snapshot.sh](https://github.com/nickabs/lightsail-utils/wiki/_new#lightsail-snapshotsh): Enable automatic daily snapshots of your AWS lightsail instance (this is an alternative to the AWS Lightsail _Automatic Snapshots_ feature, which is hard coded to retain 7 snapshots).
 
***
# wp-backup.sh

The script creates 3 gzip archives and places them in a subdirectory named YYYY-YY-DD, e.g
```
2021-02-19/2021-02-19-database.sql.gz # mysql database dump
2021-02-19/2021-02-19-content.tar.gz # uploaded content (images etc)
2021-02-10/2021-02-19-system.tar.gz # system files, including plugins
```
the script will deletes the oldest archive directories up to the specified maximum number of retained snapshots.  

note the system archive contains the WP config file (wp-config.php) and this file contains the Wordpress database access credentials in plain text.  There is an option to encrypt this archive file if you are going to keep it in a remote location.

## EXAMPLE
```
wp-backup.sh -w /var/www/wordpress -l wp.log -b /data/backups/wordpress -m 7 -r -g 1v3ab123_ddJZ1f_yGP9l6Fed89QSbtyw -c project123-f712345a860a.json -f wp-backup@example.com -t example@mail.com -a LightsailAdmin
```
See usage statement for more details

## Remote storage - service accounts
The remote storage option will upload the backup archives to Google Drive using a [service account](https://cloud.google.com/iam/docs/service-accounts).  Service account are created in the API section of the [Google Developer Console](https://console.developers.google.com/apis) and are identified by an email address e.g example@project-id.iam.gserviceaccount.com.  These accounts have their own storage quota on Google Drive (as of early 2021, the quota is 15 GiB).

limitations:
1. Service accounts can only access Google Drive files that they own  
1. The service account's Google Drive storage quota can't be increased
1. Service accounts can't login via a browser 

### service account storage
Consequently the only way to manage a service account's Google Drive data is via the [Google Drive API](https://developers.google.com/drive/api/v3/about-sdk).  

However, it is still possible to view the Google Drive data created by service accounts in a user account's Google Drive by uploading to a folder that was created by the user account and then shared with the service account (you can specify a shared folder id as a parameter to the script).

Note that if you use your user Google account to create files in one of the backup directories created by this script then the script will no longer be able to remove the directory once it becomes older than the maximum retention date specified at run time.  This is because Google Drive attempts to removes all the files contained in the folder when it is deleted.  Since the service account is only permitted to remove files it owns, the parent directory can't be removed unless all the user created files have been removed first.

Note also that the backup files can't be removed by your Google user account (deleting the file from the shared folder just removes the link to the original file owned by the service account). 

As noted above you can't purchase additional Google Drive storage for a service account, so you are limited to storing as many daily backups as can be stored in the 15GiB storage allowed for these accounts.    The script will produce a warning if the estimated storage requirements exceed the available space.

### authentication
Service accounts are associated with private/public key pairs and these are used to authenticate to Google.  The private key can be generated in the API console and saved - along with other details about the account - as a Google [JSON credentials file](https://cloud.google.com/docs/authentication/getting-started#cloud-console).  The credentials file must be stored on the machine where the script will run (the location of the file is specified at runtime).   

### authorisation
The service account email address and private key in the credentials file are used to authorise the account to access the Google Drive API using [Oauth2.0](https://developers.google.com/identity/protocols/oauth2/service-account).
![server to server authorisation flow](https://developers.google.com/identity/protocols/oauth2/images/flows/jwt.png)

The backup script creates a JWT _request token_ that is sent to Google's Oauth 2.0 service.  Assuming Google can validate that the token was signed by the private key associated with the public key it holds for the account it will return an _access token_.  The access token is valid for one hour and is used to access the resources requested in the scope specified in the original JWT access request (the backup script requests the scope needed to read/write to the service account's Google Drive storage).

The service account can also be used to access Google Cloud Platform (GCP) services and you therefore need to specify (or create) a GCP [IAM role](https://cloud.google.com/iam/docs/understanding-roles) when you create the account.  It is good practice to limit access to the minimum set of resources needed by an account to do its work, however, since Google Drive is part of Google Workspace and not GCP, there are no IAM permissions that apply to the Google Drive API.  There is no obvious way to prevent service accounts created solely for Google Drive access from also being used to access GCP services other than by creating a profile with an impossible to fulfil set of conditions.

### protecting your account 
Although the service account can't access your personal user data, anyone in possession of the service account's private key can access all the GCP resources allowed by the profile assigned to it - potentially allowing them to rack up unwanted bills - and of course they will also be able to access your backups.  You should learn about keeping your keys safe.

### dependencies
**curl** is used to access the Google Drive REST API

The script uses various linux utilities that will be found on any modern linux distro (it was developed on unbuntu 20.4)

the script has been tested with a Wordpress instance using **mysql**.  The database extract is done with **mysqldump**.

**jq** is used to parse the json returned by the Google APIs.  If jq is not available for your distribution you can find installation instructions on the [github project](https://stedolan.github.io/jq/)

email:
there is an option to send an email when the script completes or in the case of an error.  

To use this option you need to configure [AWS SES mail](https://aws.amazon.com/ses/pricing/ "AWS SES pricing + free tier").

The email is sent using the [aws command line interface](https://aws.amazon.com/cli "aws cli") and you must supply a [named aws cli profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html) at runtime.  The IAM account associated with the profile will need ses:SendEmail permission.

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

## Schedule a timer to run the script 
These instructions work on Ubuntu 20.04.

1. create lightsail-lighthouse service unit file:  /etc/systemd/system/lightsail-snapshot.service:

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

```

2. create a timer unit file: /etc/systemd/system/lightsail-snapshot.timer
```
[Unit]
Description=Timer for lightsail-snapshot.sh (AWS lightsail snapshot management)

[Timer]
#Run on first Monday of the month at 23:10
OnCalendar=Mon *-*-01..07 23:10:00
Persistent=true

[Install]
WantedBy=timers.target
```

The timer is associated with the _timers_ target (this target sets up all timers that should be active after boot )

The systemd configuration above results in a new snapshot being created on the first Monday of every month and the previous version being retained for one month.

enable the timer

```
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

3. enable log rotation: /etc/logrotate.d/lightsail-snapshot

```
/var/log/lightsail-snapshot/*.log {
    rotate 14
    weekly
    missingok
}
```
---

***

