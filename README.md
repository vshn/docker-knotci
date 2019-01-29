# Automation Script for Knot CI


## CI/CD Flow

The CI/CD flow works like this:

1. Detect changes in the zone files by comparing them to the state on the hidden master
1. Replace the magic token `1 ; SERIALAUTOUPDATE` with the current unix timestamp
1. Send new or modified zones to the hidden master and let knot refresh these zones
1. Remove deleted zones from the hidden master

The CI process is configured in the hidden file `.gitlab-ci.yml` (see example below).

### Example `.gitlab-ci.yml`

```
image: docker.io/vshn/knotci:latest

zonedelivery:
  script:
    - build.sh
  only:
    - master
```

## Manually running scripts

The CI task is executed in a Docker container, therefore just start a Docker image and
run the script in there:

`docker run --rm -it -v FULLPATHTOZONEFILES:/zones vshn/knotci bash`

### build.sh

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

Environment variables used:

* `SSH_USER`: The SSH user to log into. Default: `knot`
* `DEST_DIR`: The destination dir relative the the user's home directory. Default: `zones`
* `NS_HIDDENMASTER`: The host name of the hidden master to SSH into. Required, no default.
* `SSH_PRIVATE_KEY`: The private key used to log into the hidden master. Required, no default.
