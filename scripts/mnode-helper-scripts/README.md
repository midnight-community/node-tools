# Midnight Node Helper Scripts

This directory contains helper scripts for the Midnight Node. The env file is used to set the 
environment variables for the Midnight Node. The MNODE_HOME environment variable is used to set the
path to the directory used to store Midnight Node tools. Scripts would generally be stored in
`$MNODE_HOME/scripts/` path.

## logMonitor.sh

This script monitors the log file of the Midnight Node and adds details to the sqlite Blocklog DB.
It tracks data about each epoch and for block imported and created. It can be used to monitor if the
node is creating blocks as expected, how many blocks were created during a specific epoch, and in
which slot the block was created. It also trackes reorg events and the number of blocks that were
reverted. The script can be run manually, deployed as a systemd service.

Due to the log format of the Midnight node any logs starting in the middle of an epoch, or starting
the monitor in the middle of an epoch will not be able to track the number of blocks created in that
epoch. At the next epoch transition (every 2 hours in Testnet) the script will start tracking blocks
and inserting them into the database. Due to this a restart of the log monitor will stop inserting
new blocks into the database until the next epoch transition occurs and the script can accurately
determine the current epoch.


The database is stored as `${MNODE_HOME}/tools-db/blocklog/blocklog.db`.

### Usage

#### Options

* `-h` - Display the help message.
* `-d` - Daemonize the script. Drops the additional timestamp from log output as Systemd adds its
* `-i` - Initialize the sqlite database and import all logs from the Midnight Node. This will take a
    while to complete, based on how many days or weeks of logs you have available. 
* `-c` - The name of the container to monitor.
* `-j` - The name of the Systemd service to monitor.
* `-r` - The container runtime to use. Options are `docker`, `podman`, and `docker-compose`.
* `-D` - Deploy the script as a Systemd service.
  own.

#### Container Runtimes

When using container runtimes the script will use the `<runtime> logs` command to get the logs of
the container. The script will use `docker-compose` as the default runtime. To change the runtime to
`docker` or `podman` use the `-r` flag.

* Running the script manually for container runtimes (defaults to docker-compose):
```bash
./logMonitor.sh -c <container_name>
```

* Running the script manually changing the runtime to docker:
```bash
./logMonitor.sh -c <container_name> -r docker
```

* Running the script manually changing the runtime to podman:
```bash
./logMonitor.sh -c <container_name> -r podman
```

#### Systemd Service

When using Systemd services the script will use the `journalctl` command to get the logs of the
service. 

* Running the script manually for Systemd services:
```bash
./logMonitor.sh -j <service_name>
```

#### Deploying as a Systemd Service

To deploy the script as a Systemd service, the script will create a service file in the
`/etc/systemd/system/` directory. The service file will be named `midnight-node-log-monitor.service`.

* Deploying the script as a Systemd service monitoring container-runtime logs:
```bash
./logMonitor.sh -D -c <container_name>
```

* Deploying the script as a Systemd service monitoring Systemd service logs:
```bash
./logMonitor.sh -D -j <service_name>
```



### Database Queries


#### Get the number of blocks created in an epoch

* The number of blocks created so far in the current epoch:
```sql
SELECT COUNT(*) FROM blocklog WHERE epoch = (SELECT MAX(epoch) FROM blocklog);
```

* The number of blocks created in the last epoch:
```sql
SELECT COUNT(*) FROM blocklog WHERE epoch = (SELECT MAX(epoch) - 1 FROM blocklog);
```

* The number of blocks created in a specific epoch:
```sql
SELECT COUNT(*) FROM blocklog WHERE epoch = <epoch_number>;
```

#### Get the number of blocks prepared by your node

* The number of blocks prepared so far in the current epoch:
```sql
SELECT COUNT(*) FROM blocklog WHERE epoch = (SELECT MAX(epoch) FROM blocklog) AND status = 'prepared';
```

* The number of blocks prepared in the last epoch:
```sql
SELECT COUNT(*) FROM blocklog WHERE epoch = (SELECT MAX(epoch) - 1 FROM blocklog) AND status = 'prepared';
```

#### Get the number of blocks reverted due to reorg

* Get a count of all blocks reverted due to reorg:
```sql
WITH replaced_blocks AS (
    SELECT
        block AS start_block,
        to_block AS end_block
    FROM
        blocklog
    WHERE
        status = 'reorg'
),
affected_entries AS (
    SELECT
        b.*
    FROM
        replaced_blocks rb
    JOIN
        blocklog b
    ON
        b.block BETWEEN rb.start_block AND rb.end_block
    WHERE
        b.status IN ('prepared')
)
SELECT count(*)
FROM affected_entries;
```

* Get the number of blocks reverted due to reorg in the current epoch
```sql
WITH replaced_blocks AS (
    SELECT
        block AS start_block,
        to_block AS end_block
    FROM
        blocklog
    WHERE
        status = 'reorg' AND epoch = (SELECT MAX(epoch) FROM blocklog)
),
affected_entries AS (
    SELECT
        b.*
    FROM
        replaced_blocks rb
    JOIN
        blocklog b
    ON
        b.block BETWEEN rb.start_block AND rb.end_block
    WHERE
        b.status IN ('prepared')
)
SELECT count(*)
FROM affected_entries;
```

* Get a list of all blocks reverted due to reorg
```sql
WITH replaced_blocks AS (
    SELECT
        block AS start_block,
        to_block AS end_block
    FROM
        blocklog
    WHERE
        status = 'reorg'
),
affected_entries AS (
    SELECT
        b.*
    FROM
        replaced_blocks rb
    JOIN
        blocklog b
    ON
        b.block BETWEEN rb.start_block AND rb.end_block
    WHERE
        b.status IN ('prepared', 'presealed')
)
SELECT *
FROM affected_entries;
```