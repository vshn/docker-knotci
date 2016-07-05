#!/usr/bin/env bash
. lib.sh

if [ -z "$SSH_USER" ]; then
  SSH_USER="knot"
fi
if [ -z "$DEST_DIR" ]; then
  DEST_DIR="zones"
fi

if [ -z "$NS_HIDDENMASTER" ]; then
  echo "FAILED - NS_HIDDENMASTER not set - don't know where to sync to"
  exit 1
fi
if [ -z "$SSH_PRIVATE_KEY" ]; then
  echo "FAILED - SSH_PRIVATE_KEY not set - cannot sync without SSH key"
  exit 1
fi

MAGIC_STRING=" ; SERIALAUTOUPDATE"

# Set up SSH
log_info1 "setting up a temporary SSH agent for ${SSH_USER}@${NS_HIDDENMASTER}"
eval "$(ssh-agent -s)" > /dev/null 2>&1
ssh-add <(echo "$SSH_PRIVATE_KEY") > /dev/null 2>&1
mkdir -p ~/.ssh && echo -e "Host *\n\tStrictHostKeyChecking no\n\tLogLevel=quiet\n\n" > ~/.ssh/config
  
# Fetch zone files from master
rm -rf current
mkdir current
log_info1 "fetching current zone files from ${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/"
scp "${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/*.zone" current/
rc=$?; if [[ $rc != 0 ]]; then echo "scp failed with $rc"; exit 1; fi

# Reset serial numbers in zone files copied from master. Required for diff-ing.
for file in current/*.zone; do
  if ! grep -q "[0-9]\+${MAGIC_STRING}" "${file}"; then
    log_info1 "reverting serial to 1 not possible, magic string not found in ${file}. Skipping."
  else
    if ! grep -q "1${MAGIC_STRING}" "${file}"; then
      log_info1 "reverting serial to 1 in ${file}"
      sed -i "s/[0-9]\+${MAGIC_STRING}/1${MAGIC_STRING}/" "${file}"
    fi
  fi
done

# Reset serial numbers in local zone files. Should not be necessary, but makes the script more reliable (easier local testing)
for file in *.zone; do
  if ! grep -q "[0-9]\+${MAGIC_STRING}" "${file}"; then
    log_info1 "reverting serial to 1 not possible, magic string not found in ${file}. Skipping."
  else
    if ! grep -q "1${MAGIC_STRING}" "${file}"; then
      log_info1 "reverting serial to 1 in ${file}. Please fix the zone file (zone files with magic string must have serial number 1)"
      sed -i "s/[0-9]\+${MAGIC_STRING}/1${MAGIC_STRING}/" "${file}"
    fi
  fi
done

modified=()
modified_ok=()
modified_error_format=()
modified_error_serial=()

# Checking for modifications
for file in *.zone; do
  diff "${file}" "current/${file}" > /dev/null 2>&1
  if [ $? != 0 ]; then
    log_info1 "changes found in ${file}"
    modified+=($file)
  fi
done

# Setting new serial numbers
zoneserial=$(date +"%s")
for file in "${modified[@]}"; do
  if ! grep -q "[0-9]\+${MAGIC_STRING}" "${file}"; then
    log_info1 "setting serial to ${zoneserial} not possible, magic string not found in ${file}. Skipping."
  else
    log_info1 "setting serial to ${zoneserial} in ${file}"
    sed -i "s/[0-9]\+${MAGIC_STRING}/${zoneserial}${MAGIC_STRING}/" "${file}"
  fi
done

# Validate modified zones
for file in "${modified[@]}"; do
  zone="${file%.zone}"

  # Zone format check
  named-checkzone -i local "${zone}" "${file}" > /dev/null
  if [ $? -ne 0 ]; then
    log_info2 "NOT PASSED - ${zone} - not a valid zone file"
    modified_error_format+=($file)
    continue
  fi

  # Find current active serial on hidden master - skip check if not there
  current_serial="$(dig +short "${zone}" soa "@${NS_HIDDENMASTER}" | awk '{print $3}')"
  if [ -z "${current_serial}" ]; then 
    log_info1 "SKIPPING - ${zone} - current serial not found"
    modified_ok=($file)
    continue
  fi

  # Find new serial
  new_serial="$(named-checkzone -i none "${zone}" "${file}" | grep "loaded serial" | awk '{print $5}' | tr -cd 0-9)"
  if [ "${new_serial}" == "" ]; then 
    log_info2 "NOT PASSED - ${zone} - new serial not found"
    modified_error_serial+=($file)
    continue
  fi

  # Compare new and active serial
  if [ "${new_serial}" -gt "${current_serial}" ]; then
    log_info1 "PASSED - ${zone} - new serial ${new_serial} is higher than currently active serial ${current_serial}"
    modified_ok+=($file)
  elif [ $(( current_serial + 2147483647 )) -ge 4294967296 ] && [ $(( (current_serial + 2147483647) % 4294967296 )) -ge "${new_serial}" ]; then
    log_info1 "PASSED - ${zone} - new serial ${new_serial} rolled over from current serial ${current_serial}"
    modified_ok+=($file)
  else
    log_info2 "NOT PASSED - ${zone} - new serial ${new_serial} is NOT higher than currently active serial ${current_serial}"
    modified_error_serial+=($file)
  fi
done

# Copy zone files
if [ ${#modified_ok[@]} -gt 0 ]; then
  log_info1 "copying modified and valid zones to ${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}"
  scp "${modified_ok[@]}" "${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/"
  rc=$?; if [[ $rc != 0 ]]; then echo "scp failed with $rc"; exit 1; fi
else
  log_info1 "no modified and valid zone files"
fi

# Reload zones
for file in "${modified_ok[@]}"; do
  zone="${file%.zone}"
  log_info1 "reloading zone ${zone} with knotc"
  ssh "$SSH_USER"@"$NS_HIDDENMASTER" "bash -c 'sudo knotc zone-reload \"${zone}\"; sudo knotc zone-status \"${zone}\"'"
  rc=$?; if [[ $rc != 0 ]]; then echo "zone reload failed with $rc"; finalrc=1; fi
done

# Log broken zones (again)
exitcode=0
for file in "${modified_error_format[@]}"; do
  log_info2 "FIX IT: zone format of ${file}"
  exitcode=1
done
for file in "${modified_error_serial[@]}"; do
  log_info2 "FIX IT: serial number in ${file}"
  exitcode=1
done
log_info1 "all done"

exit $exitcode
