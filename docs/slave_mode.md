# SLAVE mode

SLAVE mode was the reason why Replikator was created at first.
We were a development team working on a huge "yellow pages" like website.
The backend was a big monolith dealing with a huge MySQL database (about 2TB in the last days) and it was very complicated to test every features with fixtures.
We were working with partial dumps we were doing from time to time and were sharing this "dev" database accross multiple development branches.
Doing a full dump for each developer was way too long and needed too much space, even a few tables dump was a pain.

Then, after playing with ZFS, came the idea of the Replikator.

So, end of the historical context, now, how do you do that ?

Well, a Replikator is "just" a normal MySQL server so you just need to configure it like any other MySQL slave server which means :
* create a replication user on both your MASTER and your Replikator database
* do a ``mysql> SHOW MASTER STATUS;` on the MASTER and note the values
* dump your MASTER database
* restore your MASTER database on the Replikator server
* configure your Replikator server to make it a slave (modify your `my.cnf` and add these lines)

```bash
server-id               = 2
relay-log               = /var/log/mysql/mysql-relay-bin.log
log_bin                 = /var/log/mysql/mysql-bin.log
# you can omit this line of you decided to replicate all the databases you have on your MASTER server, including the "mysql" database (not recommended)
binlog_do_db            = <YOUR_MASTER_DB>
```

* restart your Replikator MySQL service
* on the Replikator, run this (adjust the values with what you noted before):

```bash
mysql> CHANGE MASTER TO MASTER_HOST='<MASTER_IP>',MASTER_USER='slave_user', MASTER_PASSWORD='password', MASTER_LOG_FILE='mysql-bin.000001', MASTER_LOG_POS=  107;

```

* start the SLAVE process : `mysql> START SLAVE;`
* check replication is working correctly : `mysql> SHOW SLAVE STATUS\G`

This small tutorial is heavily inspired by this one : https://www.digitalocean.com/community/tutorials/how-to-set-up-master-slave-replication-in-mysql
