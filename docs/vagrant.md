# Testing with Vagrant

If you just want to try or if you want to do some improvements to the script, there is a Vagrant setup which creates a small Replikator VM configured in MASTER mode (a standalone MySQL server).
The architecture is this :
- one VM with 2 vCPUs, 4GB RAM
- 1 "system" disk (/dev/sda, operating system + applications)
- 1 8GB "data" disk (/dev/sdb, dedicated to ZFS)
- 1 private network interface with IP 10.2.3.4

A zpool called "myzpool" is created over /dev/sdb.
A subvolume called "myzpool/mysql-data/mysql" is mounted directly into "/var/lib/mysql" and stores the base process data.
The base process runs on port 3306 (default MySQL port).
You can connect the MySQL server instance and the replicas from your local workstation through the private network IP (eg. `mysql -u testuser -p -h 10.2.3.4 -P 3306`)

To start the box :
- clone the repo
- go to the root of the cloned repo folder
- start the box, be patient, it will take some time to complete because of the Ansible provisionning that is executed the first time : `vagrant up`
- get into the box : `vagrant ssh`

`replikator-ctl` needs privileges, use sudo, as an example, type `sudo replikator-ctl --list` you should get something similar to this picture :

![Replikator service with empty set](assets/rpk-list-empty.png)

If it is the case, then you can now start playing, just take a look at [Usage](usage.md) or [Examples](examples.md).

:warning: Ansible provisionning might fail sometimes, in case you have errors, you can force provisionning once your VM is started by using the `vragrant provision` command.

:warning: A secondary drive is created for the box. This drive will be dedicated to the ZFS storage but in case you destroy the box and re-create it, Vagrant will probably fail. In order to avoid that, you must delete the **datadir.vdi** virtual hard drive that has been created at the root of the project's folder.