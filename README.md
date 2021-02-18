# lightsail-snapshot.sh
this script creates a new lightsail instance snapshot and deletes the oldest snapshots up to the specified maximum number of retained snapshots

## EXAMPLE
`lightsail-snapshot.sh -l /var/log/lightsail-snapshot/lightsail-snapshot.log -m 2 -b "Ubuntu-1GB-London-1-Auto" -i "Ubuntu-1GB-London-1" -a Admin`

---
## Dependencies
this script uses the [aws command line interface](https://aws.amazon.com/cli "cli") to manage lightsail instance snapshots.

You will need an IAM user with the folliowing permissions:

* lightsail:CreateInstanceSnapshot
* lightsail:DeleteInstanceSnapshot
* lightsail:GetInstanceSnapshots

... and a [named profile](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-profiles.html "AWS CLI named profiles") containing the access key for this account.  You can specify the profile name on the command line.

make sure you understand the security implications of storing access keys.

email notifications:

You need to configure AWS [SES](https://aws.amazon.com/ses/pricing/ "SES")mail if you want to use the email notification option. The IAM account will need ses:SendEmail permission.  

---
## Schedule a timer to run the script (directories per Ubuntu 20.04)
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

The timer is enabled by:

```
sudo systemctl enable lightsail-snapshot.service
sudo systemctl enable lightsail-snapshot.timer
```

check status:
```
systemctl status lightsail-snapshot.service
systemctl status lightsail-snapshot.timer
```

enable log roation: /etc/logrotate.d/lightsail-snapshot

```
/var/log/lightsail-snapshot/*.log {
    rotate 14
    weekly
    missingok
}



```
