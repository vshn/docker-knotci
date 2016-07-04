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
finalrc=0

log_info1 "setting up a temporary SSH agent for ${SSH_USER}@${NS_HIDDENMASTER}"
eval "$(ssh-agent -s)" > /dev/null 2>&1
ssh-add <(echo "$SSH_PRIVATE_KEY") > /dev/null 2>&1
mkdir -p ~/.ssh && echo -e "Host *\n\tStrictHostKeyChecking no\n\tLogLevel=quiet\n\n" > ~/.ssh/config
  
rm -rf current
mkdir current
log_info1 "fetching current zone files from ${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/"
scp "${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/*.zone" current/
rc=$?; if [[ $rc != 0 ]]; then echo "scp failed with $rc"; exit 1; fi

for file in current/*.zone; do
  if ! grep -q "[0-9]\+${MAGIC_STRING}" "${file}"; then
    log_info1 "magic string not found in ${file}. This problem should fix itself after a correct zone file is deployed."
  else
    if ! grep -q "1${MAGIC_STRING}" "${file}"; then
      log_info1 "reverting serial to 1 in ${file}"
      sed -i "s/[0-9]\+${MAGIC_STRING}/1${MAGIC_STRING}/" "${file}"
    fi
  fi
done

for file in *.zone; do
  if ! grep -q "[0-9]\+${MAGIC_STRING}" "${file}"; then
    log_info2 "magic string not found in ${file}. Please fix this zone file!"
    finalrc=1
  else
    if ! grep -q "1${MAGIC_STRING}" "${file}"; then
      log_info1 "reverting serial to 1 in ${file}. Please fix this zone file!"
      sed -i "s/[0-9]\+${MAGIC_STRING}/1${MAGIC_STRING}/" "${file}"
    fi
  fi
done

modified=()

for file in *.zone; do
  diff "${file}" "current/${file}" > /dev/null 2>&1
  if [ $? != 0 ]; then
    log_info1 "changes found in ${file}"
    modified+=($file)
  fi
done

zoneserial=$(date +"%s")
for file in "${modified[@]}"; do
  log_info1 "setting serial to ${zoneserial} in ${file}"
  sed -i "s/[0-9]\+${MAGIC_STRING}/${zoneserial}${MAGIC_STRING}/" "${file}"
done

for file in "${modified[@]}"; do
  zone="${file%.zone}"

  # Find current active serial on hidden master - skip check if not there
  current_serial="$(dig +short "${zone}" soa "@${NS_HIDDENMASTER}" | awk '{print $3}')"
  if [ -z "${current_serial}" ]; then log_info1 "SKIPPING - ${zone} - current serial not found"; continue; fi

  # Find new serial
  new_serial="$(named-checkzone -i none "${zone}" "${file}" | grep "loaded serial" | awk '{print $5}' | tr -cd 0-9)"
  if [ "${new_serial}" == "" ]; then log_info2 "NOT PASSED - ${zone} - new serial not found"; finalrc=1; continue; fi

  # Compare new and active serial
  if [ "${new_serial}" -gt "${current_serial}" ]; then
    log_info1 "PASSED - ${zone} - new serial ${new_serial} is higher than currently active serial ${current_serial}."
  elif [ $(( current_serial + 2147483647 )) -ge 4294967296 ] && [ $(( (current_serial + 2147483647) % 4294967296 )) -ge "${new_serial}" ]; then
    log_info1 "PASSED - ${zone} - new serial ${new_serial} rolled over from current serial ${current_serial}."
  else
    log_info2 "NOT PASSED - ${zone} - new serial ${new_serial} is NOT higher than currently active serial ${current_serial}."
    finalrc=1
  fi
done

if [ ${#modified[@]} -gt 0 ]; then
  log_info1 "copying modified zones to ${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}"
  scp "${modified[@]}" "${SSH_USER}@${NS_HIDDENMASTER}:${DEST_DIR}/"
  rc=$?; if [[ $rc != 0 ]]; then echo "scp failed with $rc"; exit 1; fi
else
  log_info1 "no modified zone files"
fi

for file in "${modified[@]}"; do
  zone="${file%.zone}"
  log_info1 "reloading zone ${zone} with knotc"
  ssh "$SSH_USER"@"$NS_HIDDENMASTER" "bash -c 'sudo knotc zone-reload \"${zone}\"; sudo knotc zone-status \"${zone}\"'"
  rc=$?; if [[ $rc != 0 ]]; then echo "zone reload failed with $rc"; finalrc=1; fi
done

log_info1 "all done"

exit $finalrc
