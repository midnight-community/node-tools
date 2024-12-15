#!/bin/bash
#shellcheck disable=SC2086,SC2154
#shellcheck source=/dev/null

# Authors & Attribution:
# - This script is inspired by the maintainers and collaborators of the Cardano Community.
#   https://github.com/cardano-community/guild-operators/blob/alpha/scripts/cnode-helper-scripts/logMonitor.sh
# - illuminatus (http://github.com/TrevorBenson)

. "$(dirname $0)"/env

######################################
# User Variables - Change as desired #
# Common variables set in env file   #
######################################


######################################
# Do NOT modify code below           #
######################################

# Default values
container_runtime=$(command -v docker-compose)
use_journald=false
use_container=false
INIT=false

# Declare global variables
epoch=""
epoch_start_at=""
current_epoch=""
no_epoch_count=0

# Function to display usage
# return: void
usage() {
    echo "Usage: $0 [OPTIONS] [service|container]"
    echo "Options:"
    echo "  -h              Display this help message."
    echo "  -d              Run in daemon mode."
    echo "  -i              Initialize blocklog DB (deletes existing blocklog DB and syncs available logs)."
    echo "  -c [container]  Use container runtime (docker, podman, or docker-compose) to follow logs. Default: docker-compose."
    echo '  -r [runtime]    Specify container runtime (docker, podman, or docker-compose). Default: docker-compose.'
    echo "  -j [service]    Use journald (journalctl) to follow Systemd logs."
    echo "  -D              Deploy Midnight Node Log Monitor Systemd service."
}

# Function to calculate epoch stats
# return: void
calculate_epoch_stats() {
  local epoch=$1
  local working_epoch=$((epoch - 2))
  
  # Get the count of all blocks from epoch = $working_epoch with status = 'imported'
  local imported_count
  imported_count=$(sqlite3 "${BLOCKLOG_DB}" "SELECT COUNT(*) FROM blocklog WHERE epoch = ${working_epoch} AND status = 'imported';")
  
  # Calculate the chain_density percentage value to 2 decimal places
  local chain_density
  chain_density=$(awk "BEGIN {printf \"%.2f\", (${imported_count} / 7200) * 100}")
  
  # Update the epochdata table with the calculated chain_density
  sqlite3 "${BLOCKLOG_DB}" "UPDATE epochdata SET chain_density = '${chain_density}' WHERE epoch = ${working_epoch};"
  
  echo "[INFO] Calculated chain density for epoch ${working_epoch}: ${chain_density}%"
}

# Function to create blocklog DB
# return: int
create_blocklog_db() {
    if ! mkdir -p "${BLOCKLOG_DIR}" 2>/dev/null; then echo "[ERROR] failed to create directory to store blocklog: ${BLOCKLOG_DIR}" && return 1; fi
    
    rm -f ${BLOCKLOG_DB}
    if ! sqlite3 ${BLOCKLOG_DB} <<-EOF
				CREATE TABLE blocklog (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, epoch INTEGER NOT NULL, slot INTEGER NOT NULL, block INTEGER NOT NULL DEFAULT 0, ancestor_block INTEGER NOT NULL DEFAULT 0, to_block INTEGER NOT NULL DEFAULT 0, hash TEXT NOT NULL DEFAULT '', status TEXT NOT NULL);
				CREATE INDEX idx_blocklog_epoch ON blocklog (epoch);
				CREATE INDEX idx_blocklog_status ON blocklog (status);
				CREATE TABLE epochdata (id INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, epoch INTEGER NOT NULL, start_block INTEGER NOT NULL, chain_density TEXT, UNIQUE(epoch, at, start_block));
				CREATE INDEX idx_epochdata_epoch ON epochdata (epoch);
				CREATE INDEX idx_start_block ON epochdata (start_block);
				PRAGMA user_version = 1;
				EOF
    then
        echo "[ERROR] failed to create blocklog DB: ${BLOCKLOG_DB}"
        return 1
    else
      echo "SQLite blocklog DB created: ${BLOCKLOG_DB}"
    fi
    return 0
}

deploy_monitoring_service() {
  echo -e "[Re]Installing Midnight Node Log Monitor service.."
  local after="After=network-online.target"
  local binds_to=""
  local exec_start=""

  if $use_journald; then
    after+=" ${target}.service"
    binds_to="BindsTo=${target}.service"
    exec_start="/bin/bash -l -c \"./logMonitor.sh -d -j ${target}\""
  elif $use_container; then
    exec_start="/bin/bash -l -c \"./logMonitor.sh -d -c ${target}\""
  else
    echo "Error: Either -j or -c must be specified with -D."
    exit 1
  fi

  sudo bash -c "cat <<-EOF > /etc/systemd/system/midnight-node-log-monitor.service
[Unit]
Description=Midnight Node Log Monitor
Wants=network-online.target
${after}
${binds_to}

[Service]
Type=simple
Restart=always
RestartSec=5
User=${USER}
WorkingDirectory=${MNODE_HOME}/scripts
ExecStart=${exec_start}
KillSignal=SIGINT
SuccessExitStatus=143
TimeoutStopSec=5
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF"
  sudo systemctl daemon-reload \
    && sudo systemctl enable midnight-node-log-monitor.service &>/dev/null \
    && sudo systemctl restart midnight-node-log-monitor.service &>/dev/null
  echo -e "Done!!"
}

# Function to get epoch start
# return: string
get_epoch_start() {
  # When no epoch_start_at set, or the time difference between the current epoch and the
  # last epoch is approaching the 2 hour epoch window, set the epoch_start_at value from at
  if [[ -z ${epoch_start_at} ]]; then
    epoch_start_at=${at}
  else
    epoch_start_at_seconds=$(date -d "${epoch_start_at}" +%s)
    at_seconds=$(date -d "${at}" +%s)
    if [[ $((at_seconds - epoch_start_at_seconds)) -gt 7000 ]]; then
      epoch_start_at=${at}
    fi
  fi
  echo ${epoch_start_at}
}

# Function to get lost blocks during a reorg event
get_lost_blocks() {
  local ancestor_block=$1
  local to_block=$2
  local epoch=$3
  local at=$4

  # Select blocks from blocklog where status = 'prepared' or 'presealed' and block > ancestor_block or <= to_block
  local blocks
  blocks=$(sqlite3 "${BLOCKLOG_DB}" "SELECT block FROM blocklog WHERE (status = 'prepared' OR status = 'presealed') AND (block > ${ancestor_block} OR block <= ${to_block});")

  # Convert the blocks to a bash array
  IFS=$'\n' read -r -d '' -a block_array <<< "$blocks"

  # Sort the array uniquely
  mapfile -t sorted_unique_blocks < <(printf "%s\n" "${block_array[@]}" | sort -nu)

  # Check if the length of the array is greater than 0
  if [[ ${#sorted_unique_blocks[@]} -gt 0 ]]; then
    #echo "[WARNING] Lost block due to reorg in epoch ${epoch} at ${at}"
    log_output "WARNING" "Lost block due to reorg in epoch ${epoch}" "${at}"
  fi
}

# Function to get slot
# return: int
get_slot() {
  local at_seconds=$1
  local epoch_start_at_seconds=$2
  local slot=$((at_seconds - epoch_start_at_seconds))
  echo ${slot}
}

log_output() {
  local log_level=$1
  local message=$2
  local timestamp
  if [[ -z ${DAEMON} ]]; then
    timestamp="${3}: "
  else
    timestamp=""
  fi
  case $log_level in
    "INFO")
      echo "[INFO] ${timestamp}${message}"
      ;;
    "WARNING")
      echo "[WARNING] ${timestamp}${message}"
      ;;
    "ERROR")
      echo "[ERROR] ${timestamp}${message}"
      ;;
    *)
      echo "${timestamp}${message}"
      ;;
  esac
}

# Function to print no epoch error
# return: string
log_no_epoch() {
  if [[ $((no_epoch_count % 100)) -eq 0 ]] || [[ ${no_epoch_count} -eq 1 ]]; then
    #echo "${1} at ${2}, count ${no_epoch_count}"
    log_output "WARNING" "${1}" "${2}"
  fi
  no_epoch_count=$((no_epoch_count + 1))
}


# Function to parse options
# return: void
parse_options() {
  # Parse options
  while getopts ":c:dhij:r:D" opt; do
    case $opt in
      d)
        DAEMON=true
        ;;
      i)
        INIT=true
        ;;
      j)
        use_journald=true
        target="$OPTARG"
        ;;
      c)
        use_container=true
        target="$OPTARG"
        ;;
      r)
        runtime="$OPTARG"
        if [[ "$runtime" == "docker" || "$runtime" == "podman" || "$runtime" == "docker-compose" ]]; then
          container_runtime=$(command -v "$runtime")
          if [[ -z "$container_runtime" ]]; then
            echo "Error: $runtime is not installed or not found in PATH."
            exit 1
          fi
        else
          echo "Error: Invalid container runtime specified. Expected 'docker', 'podman', or 'docker-compose'."
          exit 1
        fi
        ;;
      D)
        deploy_service=true
        ;;
      h)
        usage
        exit 0
        ;;
      \?)
        echo "Error: Invalid option -$OPTARG"
        usage
        ;;
      :)
        echo "Error: Option -$OPTARG requires an argument."
        usage
        exit 1
        ;;
    esac
  done

  # Validate options
  if $use_journald && $use_container; then
    echo "Error: Cannot use both -j and -c options simultaneously."
    usage
  fi
}

# Function to process log entries
# return: void
process_logs() {
  no_epoch_count=0
  while IFS= read -r logentry; do
    # Extract the timestamp
    at=$(echo "$logentry" | grep -oP '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
    at_seconds=$(date -d "${at}" +%s)
    case "$logentry" in
      *"New epoch"* )
        if [[ "$BLOCKLOG_ENABLED" = true ]]; then
          epoch_start_at=$(get_epoch_start)
          epoch_start_at_seconds=$(date -d "${epoch_start_at}" +%s)
          epoch=$(echo "$logentry" | grep -oP 'New epoch \K[0-9]+')
          start_block=$(echo "$logentry" | grep -oP 'starting at block \K[0-9]+')
          log_output "INFO" "New epoch ${epoch} starting at block ${start_block}" "${at}"

          # Set current_epoch if undefined
          if [[ -z "${current_epoch}" ]]; then
            current_epoch=${epoch}
          fi

          # Update current_epoch and calculate epoch stats if needed
          if [[ $((current_epoch + 1)) -eq ${epoch} ]]; then
            calculate_epoch_stats ${epoch}
            current_epoch=${epoch}
          fi

          # Check if the epoch already exists in the database
          existing_start_block=$(sqlite3 "${BLOCKLOG_DB}" "SELECT start_block FROM epochdata WHERE epoch = ${epoch};")
          if [[ -n "${epoch}" ]] && [[ -n "${epoch_start_at}" ]]; then
            if [[ -z ${existing_start_block} ]]; then
              # Insert a new entry for the epoch when there is no existing entry
              sqlite3 "${BLOCKLOG_DB}" "INSERT INTO epochdata (epoch, start_block,at ) VALUES (${epoch}, ${start_block}, '${at}');"
            else
              if [[ ${start_block} -lt ${existing_start_block} ]]; then
                # Update the entry with the new start block when the new start block is less than the existing start block
                sqlite3 "${BLOCKLOG_DB}" "UPDATE epochdata SET start_block = ${start_block} WHERE epoch = ${epoch};"
                log_output "INFO" "Epoch ${epoch} start block rolled back to ${start_block} from previous start block: ${existing_start_block}" "${at}"
              fi
            fi
          fi
        fi
        ;;
      *"Prepared block for proposing"* )
        if [[ "$BLOCKLOG_ENABLED" = true ]]; then
          prepared_block=$(echo "$logentry" | grep -oP 'Prepared block for proposing at \K[0-9]+')
          slot=$(get_slot ${at_seconds} ${epoch_start_at_seconds})
          log_output "INFO" "Prepared block number: ${prepared_block} slot: ${slot}" "${at}"
          if [[ -n "${epoch}" ]] && [[ -n "${epoch_start_at}" ]]; then
            sqlite3 "${BLOCKLOG_DB}" "INSERT OR IGNORE INTO blocklog (epoch, slot, block, status, at) values (${epoch},  ${slot}, ${prepared_block},'prepared', '${at}');"
          else
            log_no_epoch "The epoch or epoch_start_at are not set, logging will commence at start of next epoch." "${at}"
          fi
        fi
        ;;
      *"Pre-sealed block for proposal"* )
              if [[ "$BLOCKLOG_ENABLED" = true ]]; then
                presealed_block=$(echo "$logentry" | grep -oP 'Pre-sealed block for proposal at \K[0-9]+')
                epoch_start_at_seconds=$(date -d "${epoch_start_at}" +%s)
                slot=$(get_slot $at_seconds $epoch_start_at_seconds)
                log_output "INFO" "Pre-sealed block number: ${presealed_block}, slot: ${slot}" "${at}"
                if [[ -n "${epoch}" ]] && [[ -n "${epoch_start_at}" ]]; then
                  sqlite3 "${BLOCKLOG_DB}" "INSERT INTO blocklog (epoch, slot, block, status, at) values (${epoch}, ${slot}, ${presealed_block}, 'presealed', '${at}');"
                  echo "Inserted pre-sealed block number: ${presealed_block} at ${at}, slot: ${slot}"
                else
                  log_no_epoch "The epoch or epoch_start_at are not set, logging will commence at start of next epoch." "${at}"
                fi
              fi
              ;;
      *"Imported #"* )
              if [[ "$BLOCKLOG_ENABLED" = true ]]; then
                imported_block=$(echo "$logentry" | grep -oP '#\K[0-9]+')
                epoch_start_at_seconds=$(date -d "${epoch_start_at}" +%s)
                slot=$(get_slot $at_seconds $epoch_start_at_seconds)
                if [[ -n "${epoch}" ]] && [[ -n "${epoch_start_at}" ]]; then
                  sqlite3 "${BLOCKLOG_DB}" "INSERT INTO blocklog (epoch, slot, block, status, at) values (${epoch}, ${slot}, ${imported_block}, 'imported', '${at}');"
                else
                  log_no_epoch "The epoch or epoch_start_at are not set, logging will commence at start of next epoch." "${at}"
                fi
              fi
              ;;
      *"Reorg on #"* )
        if [[ "$BLOCKLOG_ENABLED" = true ]]; then
          log_output "INFO" "Reorg detected" "${at}"
          reorg_block=$(echo "$logentry" | grep -oP 'Reorg on #\K[0-9]+')
          to_block=$(echo "$logentry" | grep -oP ' to #\K[0-9]+')
          ancestor_block=$(echo "$logentry" | grep -oP 'common ancestor #\K[0-9]+')
          slot=$(get_slot $at_seconds $epoch_start_at_seconds)
          log_output "INFO" "Reorg occurred for epoch ${epoch}. Reorg block: ${reorg_block} from ancestor ${ancestor_block} to ${to_block}" "${at}"
          if [[ -n "${epoch}" ]] && [[ -n "${epoch_start_at}" ]]; then
            sqlite3 "${BLOCKLOG_DB}" "INSERT INTO blocklog (epoch, slot, block, ancestor_block, to_block, status, at) values (${epoch}, ${slot}, ${reorg_block}, ${ancestor_block}, ${to_block}, 'reorg', '${at}');"
          else
            log_no_epoch "The epoch or epoch_start_at are not set, logging will commence at start of next epoch." "${at}"
          fi
        fi
        ;;
      * ) : ;; # ignore
    esac
  done
}


#####################################
#              Main                 #
#####################################

parse_options "$@"

# Check if blocklog is enabled, default to true when undefined
[[ -z "${BLOCKLOG_ENABLED}" ]] && BLOCKLOG_ENABLED=true

# Deploy systemd service if -D is used
if [[ "${deploy_service}" = true ]]; then
  deploy_monitoring_service
  exit 0
fi

# Check if blocklog DB exists or if initialization is requested
if [[ ! -f ${BLOCKLOG_DB} ]] || [[ "${INIT}" = true ]]; then 
  # Create a fresh DB with latest schema
  if ! create_blocklog_db ; then
    echo "Error: Failed to create blocklog DB."
    exit 1
  fi
fi

if $use_journald; then
  if [[ $INIT = true ]]; then
    LINES="all"
  else
    LINES="1"
  fi
  journalctl --no-pager -f --lines ${LINES} -u "${target}.service" | process_logs
elif $use_container; then
  if [[ -z "$container_runtime" ]]; then
    echo "Error: No container runtime found."
    exit 1
  fi
  if [[ "$INIT" = true ]]; then
    LINES="-1"
  else
    LINES="1"
  fi
  "$container_runtime" container logs -f --tail ${LINES} "${target}" 2>&1 | process_logs
else
  echo "Error: Either -j or -c must be specified."
  usage
fi