# Manual installation

## Requirements

`replikator-ctl` will run on any Linux system with MySQL/MariaDB and a ZFS enabled kernel with a dedicated ZFS zpool.
However, this setup has been thoroughly tested with MySQL 5.5 and 5.7 on Ubuntu 18.04.

I would recommend using the Ansible playbook against any fresh Ubuntu server 18.04 box but if you can't or don't want to deal with Ansible, here are the big steps (package names might change depending on your distribution):

* copy the `src/replicator-ctl.sh` script to somewhere in the PATH such as `/usr/local/bin/replikator-ctl`
* copy the `conf/replikator.conf.dist` example configuration file to `/etc/replikator.conf` and adjust your settings
* install ZFS (if not already done) and create a zpool for your setup (let's call it **myzpool**) :

```bash
# install ZFS
apt-get install zfs-dkms

# create the zpool (let's say you dedicate a device called /dev/sdb to ZFS)
zpool create -o ashift=12 -f myzpool /dev/sdb

# do some tuning on the zpool
zpool set autoexpand=on myzpool
zfs set compression=lz4 myzpool  # <== this one is VERY important !
zfs set atime=off myzpool
zfs set xattr=sa myzpool
zfs set recordsize=16k myzpool
zfs set primarycache=metadata myzpool
zfs set logbias=throughput myzpool
zfs set checksum=off myzpool
zfs set exec=off myzpool

# create some needed subvolumes
zfs create myzpool/mysql-data
zfs create myzpool/mysql-snapshots
# this one will host your base MySQL data and will be automaticaly mounted
# on /var/lib/mysql so that, as soon as you will install your MySQL/MariaDB
# service, the default database will be created directly in the right place
zfs create -o mountpoint=/var/lib/mysql -o canmount=on myzpool/mysql-data/mysql
```

* install MySQL/MariaDB

Each replica is a new MySQL process running on the same server as the base MySQL instance based on a ZFS clone of the datasets.
This means that each replica has an exact copy of the base data but that doesn't mean they have the same service configuration regarding memory allocation or performances tuning.
Each new replica process is created based on a templated configuration and this is this configuration that control the way your replicas are behaving.
The provided template tries to provide the best performances possible and is not meant to secure your data.
I wouldn't recommend to change anything in this file unless you know what you're doing or want to change that default behaviour.

* create the `/etc/mysql/snapshots.d` folder
* copy the `conf/00-snapshots.tpl.dist` template file to `/etc/mysql/snapshots.d/00-snapshots.tpl`

* start your MySQL service and create a user for `replikator-ctl`. Adjust with your own credentials and don't forget to report them in `/etc/replikator.conf`

```bash
mysql> CREATE USER 'rpkuser'@'localhost' IDENTIFIED BY 'rpkpass';
mysql> GRANT EVENT,LOCK TABLES,RELOAD,REPLICATION CLIENT,SELECT,SHOW DATABASES,SHUTDOWN,SUPER ON *.** TO 'rpkuser'@'localhost';
```
