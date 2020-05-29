# ![logo](docs/assets/logo_full.png)

Duplicate and run live databases, any size, instantly !

**DISCLAIMER**
This project is not supported anymore, this was an internal project released as "giftware".
Do what you want with it !
It won't see any major changes except maybe a few bugfixes or documentation upgrades.
It will be replaced by a much more advanced project called "Replikant" that will be released ... when it's done ;)

## Description

Replikator is bash script which can create instant running replicas from a living MySQL database, whatever it's size.

What could be the use cases ?
Well ... depends on your needs but you can imagine plenty of them :
- development process with instant copy of databases to provide to your dev teams (much quicker than doing dumps/restore)
- CI process with dynamic environments when testing feature branches (associate the new code with a real database)
- reproducing bugs with real data/volumetry in sandboxed environments
- snapshoting for backup/point in time recoveries
- queries optimization
- database modifications playground (run alter scripts on real data without damaging your production DB and estimating running time)
- whatever you may imagine ... 

## Requirements

Replikator don't have many requirements except :
- any MySQL server version (tested with 5.5, 5.7 and 8.0 but should work identical with MariaDB)
- ZFS and a ZFS zpool (the faster storage type you can get, the better)
- Bash
- (optional) an external MySQL server to replicate (if running in SLAVE mode)
- (optional) Vagrant (for testing/develoment purpose)


## Getting started

Before anything else, it is important to have the glossary in mind :
- **replikator-ctl** : a bash script managing a "replikator" system.
- **replikator** : a "replikator" is a server (bare metal or VM) running a MySQL (or MariaDB) service with its data stored on a ZFS storage pool and executinf the "replikator-ctl" script.
- **base process** : the main MySQL/MariaDB instance running on a "replikator", this is the MySQL/MariaDB instance from which we will create "instant replicas".
- **replica** : a "replica" is a newly instanciated running copy of a "base process" instance.
- **backup replica** : a stopped replica that is used for backup/point in time recovery purpose. These replicas are always done in "safe mode".
- **safe/normal/unsafe mode** : depending on the selected mode, a new replica can take more or less time to be instanciated and you could potentially lose some data in the process (typically the last second or the last transaction).
- **external source** : a third party MySQL/MariaDB server acting as a MASTER in a SLAVE mode scenario.

Even if installing the script is easy, Replikator needs a specific host setup to work properly.

- [Principles](docs/principles.md) : Some basics
- [Testing with Vagrant](docs/vagrant.md) : if you just want to test quickly and don't want to bother with the details
- [Installation](docs/installation.md) : Let's get the real thing !
- [Usage](docs/usage.md) : CLI references
- [SLAVE mode](docs/slave_mode.md) : Configuring a SLAVE mode setup
- [Examples](docs/examples.md) 
