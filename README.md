# Automation Script for Knot CI

## CI/CD Flow

The script `build.sh` available in this Docker image can do the following tasks:

1. Get the current state from the master
  1. Download zone files via scp
  1. Reset serial numbers to 1 (needed to compare zone files with current versions)
1. Reset serial numbers in current versions of zone files (should not do anything, because serial should always be 1)
1. Compares current versions with state from the master
  1. Creates a list of modified zones
1. Update serial numbers of all modified zones to the current unix timestamp
1. Validate all modified zones
  1. Is the zone data valid?
  1. Is the serial number larger than the currently deployed serial number?
1. Copy all modified zones to the master
1. Reload all modified zones and get the status
1. Delete all orphaned zone files on the master

The CI process is configured in the hidden file `.gitlab-ci.yml` (see example below).

### Example `.gitlab-ci.yml`

```
image: communityrack/knotci

zonedelivery:
  script:
    - buildzones.sh
    - checkzones.sh
    - deployzones.sh
  artifacts:
    paths:
      - '*.zone'
  cache:
    paths:
      - .lasthash
      - .oldserials
  only:
    - master
```

## Manually running scripts

The CI tasks are executed in a Docker container, therefore just start a Docker image and
run the scripts in there:

`docker run --rm -it -v FULLPATHTOZONEFILES:/zones communityrack/knotci bash`

All scripts accept the argument `allzones`. If set, it will act on all zones, not only
on the changed ones.

### buildzones.sh

When executed without parameters, it updates the serial on all files changed since last HEAD
(`HEAD HEAD~1`) or since last push when `.lasthash` exists. The parameter `allzones` can be used
to update the serial on all zone files which contain the string `1 ; SERIALAUTOUPDATE`.
It also restores the last serials which it gets from the cached file `.oldserials`.

Environment variables used:

* `MAGICSTRING`: Magicstring for updating zone serial. Default: `1 ; SERIALAUTOUPDATE`

### checkzones.sh

This scripts validates the zonefiles with `named-checkzone` and compares the serial
to the hidden master. The hidden master is configured in the environment variable `NS_HIDDENMASTER`.
To run this script manually, set `NS_HIDDENMASTER` to the address of the hidden master. F.e.:

`NS_HIDDENMASTER=myns.myzone.tld checkzones.sh`

Environment variables used:

* `NS_HIDDENMASTER`: name of the DNS hidden master

### deployzones.sh

Rsyncs all changed files to the hidden master and cleans up the remote (`--delete` option).
The SSH key is taken from the envionment variable `SSH_PRIVATE_KEY` and the hidden master
from `NS_HIDDENMASTER`.

After a successfull sync, all changed zones are reloaded (same mechanism to detect changed zones
as in `buildzones.sh`). To make a full sync and reload all zones, use the `allzones` command line
parameter.

Environment variables used:

* `NS_HIDDENMASTER`: name of the DNS hidden master
* `SSH_USER`: name of the remote SSH user. Default: knot
* `SSH_PRIVATE_KEY`: Private key of the remote SSH user
* `RSYNC_DEST_DIR`: destination directory to sync zonefiles to. Default: zones

