# Usage

```
Usage: /usr/local/bin/replikator-ctl [OPTION]

Options
 -h, --help                            Show this help
 -v, --verbose                         Increase verbosity
 -q, --quiet                           Disable output completely
 -c, --create <NAME>:<MEM>:<PORT>      Create a replica
                                       (optionnal) <MEM> sets memory size limit for instance (default 1 GB)
                                       (optionnal) <PORT> define fixed port for instance
 -b, --backup                          Create a backup replica
 -e, --exec                            Execute a post replica hook script
                                       (replica's port will be given as hook script parameter)
 -f, --from-ip <IPADDR>                IP address for source IP based port redirect (3306 to running instance port)
 -F, --from-replica <SOURCE>           If you want to create a replica based on another specific one
 -l, --list                            List all created replicas
 -L, --list-backups                    List all created backup replicas
 -g, --get-status <NAME>               Get detailed replica informations
 -d, --delete <NAME>                   Delete a replica
 -p, --purge                           Delete every declared replicas (running or not)
 -P, --purge-all                       Delete every declared replicas (running or not), including backup replicas
 -r, --run <NAME>                      Start a replica
 -R, --refresh <NAME>                  Refresh an existing replica
 -x, --stop <NAME>                     Stop a replica
 -w, --add-redirect <NAME>             Add IP based redirect (3306 to running replica port)
 -y, --del-redirect <NAME>             Delete IP based redirect (3306 to running replica port)
 -z, --purge-redirects                 Delete every IP based redirects
 -m, --add-metas <NAME>:<JSON>         Add metas informations in JSON format
 -t, --stop-replication                Stop the SLAVE replication process
 -T, --start-replication               Start the SLAVE replication process
 -o, --output <FORMAT>                 Define output format (stdout|json), stdout is default
 -n, --noconfirm                       Assume Yes to all queries and do not prompt
 -M, --monitor                         Autorefresh with <DELAY> seconds
```

## `-c, --create <NAME>:<MEM>:<PORT>` : Create a new replica
Creating a replica is as simple as typing `replikator-ctl -c myreplica`.
Doing so will create a new replica with a dedicated port starting from [BASEPORT](../conf/replikator.conf.dist) and with a [MEMPERINSTANCE](../conf/replikator.conf.dist) memory allocation.

It is possible to specify another value for PORT and MEMORY size by using this kind of command : `replikator-ctl -c myreplica:4:5555`.
This will create a replica called "myreplica" with 4GB memory on port 5555.

MEM must be < [MEMLIMIT](../conf/replikator.conf.dist) minus the sum of the already running replicas.
You can see your memory availability with `replikator-ctl -l`

## `-b, --backup` : Create a backup replica
Create a "backup" replica.
Backup replicas are normal replicas except that :
- they are not started after creation
- they don't count for memory allocation
- they are done in "safe mode" (which means data are consistent)
- their name is auto-generated (backup-yyyymmdd-hhmm)
- they are hidden in the replicas list (you must use `-L` to see them)

## `-e, --exec` : Execute a script after new replica creation
Execute a script after a new replica has been created.
Typically, this can be used to apply some anonimyzation script on a set of data each time a new replica is spawned.
Script can be in any language which interpreter is installed on the Replikator server.

## `-f, --from-ip <IPADDR>` : Redirect port 3306 to replica's port from source IP
Sometimes, you might not be able/or don't want to change the default MySQL port and keep using 3306 instead of an alternate port.
In order to achieve that, you can declare a source port redirection by using this additional parameter providing the source client IP.

Example : `replikator-ctl -c test -f <IPADDR>` (where IPADDR is the IP of the connecting client)

## `-F, --from-replica <SOURCE>` : Create a replica based on a replica
Create a replica based on an already existing replica.
This can be useful if, for some reason, you want to clone a modified replica instead of the original data source.

Example : `replikator-ctl -c test -F <SOURCE>` (where <SOURCE> is the source replica's name)

## `-l, --list` : List replicas
List all the created replicas, their status and the status of the replikator service.
This command don't display the "backup" replicas.

## `-L, --list-backups` : List backup replicas
List the backup replicas.
This command don't display the normal replicas.

## `-g, --get-status <NAME>` : Display detailed replica's informations
Display detailed informations about a replica

## `-d, --delete <NAME>` : Delete a replica
Delete a replica instance.

## `-p, --purge` : Delete all replicas except backups
Delete all replicas but not the "backup" ones.

## `-P, --purge-all` : Delete all replicas including backups
Delete all replicas including the "backup" ones.

## `-r, --run <NAME>` : Start a stopped replica
Start a stopped replica.

## `-R, --refresh <NAME>` : Refresh replica data
 A replica is based on a snapshot of a MySQL database, so it's data set is as old as the time the replica has been spawned.
 By the time, the source database can change with newly or modified data that are not synced with the replica.
 Refreshing a replica means deleting and recreating the same replica, with same name, same memory allocation and same running port.
 It just automates the process of re-creating a same replica instead of doing it by hand.

 ## `-x, --stop <NAME>` : Stop a running replica
 Stop a running replica.
 This stops the replica's MySQL process but it doesn't delete any data.

## `-w, --add-redirect <NAME>` : Add IP based redirect
This switch lets you add a port redirection from a source IP to an existing replica.
This is the same thing as the `--from-ip` switch but for an existing replica.
This switch must be combined with the `--from-ip` switch.

Example : `replikator-ctl --add-redirect test --from-ip x.x.x.x`

## `-y, --del-redirect <NAME>` : Delete IP based redirect
This switch lets you remove a port redirection.
This switch must be combined with the `--from-ip` switch.

Example : `replikator-ctl --del-redirect test --from-ip x.x.x.x`

## `-z, --purge-redirects` : Delete every IP based redirects
Delete every IP based port redirections.

## `-m, --add-metas <NAME>:<JSON>` : Add metas informations in JSON format
Lets you add some meta informations associated to a replica.
These informations can be seen using the `--get-status` switch.
Any information can be added, only requirement is that it must be a valid json formatted text.

Example : `replikator-ctl --add-metas test:'{"mykey": "myvalue"}'`

## `-t, --stop-replication` : Stop the SLAVE replication process
When running in SLAVE mode, this switch lets you stop the replication process between the Replikator's base process and an external Master server.

## `-T, --start-replication` : Start the SLAVE replication process
When running in SLAVE mode, this switch lets you resume the replication process between the Replikator's base process and an external Master server.

## `-o, --output <FORMAT>` : Define the output format
Define the output format (stdout|json), stdout is default

## `-n, --noconfirm` : Assume Yes to all queries and do not prompt
Don't ask any question and assume yes to everything (usefull for batches).

## `-M, --monitor <DELAY> : Autorefresh with <DELAY> seconds
This is equivalent to `watch -n<DELAY> replikator-ctl -l`