#!/bin/bash
set -uo pipefail
export LC_ALL=C

# Configuration
UDEV_RULE_PATH=${UDEV_RULE_PATH:-/etc/udev/rules.d/99-uf2-mount.rules}
SERVICE_PATH=${SERVICE_PATH:-/etc/systemd/system/uf2-mount@.service}
MOUNT_PREFIX=${MOUNT_PREFIX:-/mnt}

# Write an error message and return an error status.
fail() {
    printf '%s\n' "$*" >&2
    return 1
}

# Install the systemd unit and the udev rule.
install_files() {
    local service script

    command -v mdir >/dev/null || {
        fail 'Install the mtools package. The script needs mdir.'
        return 1
    }
    [[ $EUID == 0 ]] || {
        fail 'Run the installation as root.'
        return 1
    }
    service=${SERVICE_PATH##*/}
    [[ $service =~ ^[a-zA-Z0-9_.-]+@\.service$ ]] || {
        fail 'The service file name must end in @.service.'
        return 1
    }
    script=$(readlink -f -- "$0") || {
        fail 'Cannot find the script path.'
        return 1
    }
    [[ -f $script && -x $script ]] || {
        fail "The script is not an executable file: $script"
        return 1
    }

    # Escape the path for the systemd ExecStart value.
    script=${script//\\/\\\\}
    script=${script//\"/\\\"}
    script=${script//\$/\$\$}
    script=${script//%/%%}
    umask 022
    cat >"$SERVICE_PATH" <<EOF || {
[Unit]
Description=Probe and mount UF2 volume at %I
BindsTo=sys-%i.device
After=sys-%i.device

[Service]
Type=oneshot
ExecStart="$script" /sys/%I
TimeoutStartSec=30
EOF
        fail "Cannot write the service file: $SERVICE_PATH"
        return 1
    }
    cat >"$UDEV_RULE_PATH" <<EOF || {
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_FS_TYPE}=="vfat", TAG+="systemd", ENV{SYSTEMD_WANTS}+="$service"
EOF
        fail "Cannot write the udev rule: $UDEV_RULE_PATH"
        return 1
    }
    systemctl daemon-reload || {
        fail 'Cannot reload systemd.'
        return 1
    }
    udevadm control --reload-rules || {
        fail 'Cannot reload the udev rules.'
        return 1
    }
    printf 'Installed %s and %s\n' "$SERVICE_PATH" "$UDEV_RULE_PATH"
}

# Check that the device still has the same disk sequence number.
check_device() {
    local resolved
    resolved=$(readlink -f -- "$identity") || {
        fail "The device is not available: $device"
        return 1
    }
    [[ -b $identity && $resolved == "$device" && -d $sysdev ]] || {
        fail "The device is not available: $device"
        return 1
    }
}

# Get the device path and disk sequence number from udev.
get_device() {
    local properties key value diskseq='' devtype='' partnum=''

    [[ $sysdev == /sys/devices/* ]] || {
        fail "Invalid sysfs path: $sysdev"
        return 1
    }
    properties=$(udevadm info --query=property --path="$sysdev") || {
        fail "Cannot get device data: $sysdev"
        return 1
    }
    while IFS='=' read -r key value; do
        case $key in
        DEVNAME) device=$value ;;
        DISKSEQ) diskseq=$value ;;
        DEVTYPE) devtype=$value ;;
        ID_PART_ENTRY_NUMBER) partnum=$value ;;
        esac
    done <<<"$properties"
    [[ $device == /dev/* && $diskseq =~ ^[0-9]+$ ]] || {
        fail 'The device path or disk sequence number is not available.'
        return 1
    }
    identity=/dev/disk/by-diskseq/$diskseq
    if [[ $devtype == partition ]]; then
        [[ $partnum =~ ^[0-9]+$ ]] || {
            fail "The partition number is not available: $device"
            return 1
        }
        identity+=-part$partnum
    fi
    check_device
}

# Check for the UF2 file. Return 2 if the file is not present.
check_uf2() {
    local output

    if output=$(mdir -i "$identity" ::/INFO_UF2.TXT 2>&1); then
        return 0
    fi
    if [[ $output == 'mdir: File "::/INFO_UF2.TXT" not found' ]]; then
        printf 'The UF2 file is not present: %s\n' "$device"
        return 2
    fi
    fail "Cannot read the UF2 file on $device: $output"
}

# Make sure that the mount path is an empty directory.
prepare_mountpoint() {
    local entries status

    [[ ! -L $mountpoint ]] || {
        fail "The mount path is a symbolic link: $mountpoint"
        return 1
    }
    if findmnt --mountpoint "$mountpoint" --noheadings >/dev/null; then
        fail "The mount path is in use: $mountpoint"
        return 1
    else
        status=$?
        ((status == 1)) || {
            fail "Cannot check the mount path: $mountpoint"
            return 1
        }
    fi
    if [[ -e $mountpoint ]]; then
        [[ -d $mountpoint ]] || {
            fail "The mount path is not a directory: $mountpoint"
            return 1
        }
        entries=$(find "$mountpoint" -mindepth 1 -maxdepth 1 -print -quit) || {
            fail "Cannot read the mount directory: $mountpoint"
            return 1
        }
        [[ -z $entries ]] || {
            fail "The mount directory is not empty: $mountpoint"
            return 1
        }
    else
        mkdir -- "$mountpoint" || {
            fail "Cannot create the mount directory: $mountpoint"
            return 1
        }
    fi
}

# Check the device and mount its FAT volume.
mount_device() {
    local sysdev=${1:-} device='' identity='' mountpoint
    local label group gid status lock_fd

    get_device || return 1
    exec {lock_fd}>/run/lock/uf2-mount.lock || {
        fail 'Cannot open the lock file.'
        return 1
    }
    flock -x "$lock_fd" || {
        fail 'Cannot lock the lock file.'
        return 1
    }
    check_device || return 1
    if findmnt --source "$device" --noheadings --first-only >/dev/null; then
        printf 'The device is already mounted: %s\n' "$device"
        return 0
    else
        status=$?
        ((status == 1)) || {
            fail "Cannot check the device mount: $device"
            return 1
        }
    fi
    if check_uf2; then
        :
    else
        status=$?
        ((status == 2)) && return 0
        return 1
    fi
    check_device || return 1
    label=$(blkid --probe --match-tag LABEL --output value "$identity") || {
        fail "Cannot read the volume label: $device"
        return 1
    }
    case $label in
    '' | . | .. | */*)
        fail "Invalid volume label: $label"
        return 1
        ;;
    esac
    mountpoint=${MOUNT_PREFIX}/$label
    prepare_mountpoint || return 1
    group=$(getent group disk) || {
        fail 'Cannot find the disk group.'
        return 1
    }
    gid=${group#*:}
    gid=${gid#*:}
    gid=${gid%%:*}
    [[ $gid =~ ^[0-9]+$ ]] || {
        fail 'The disk group ID is invalid.'
        return 1
    }
    check_device || return 1
    systemd-mount --collect --automount=no --bind-device --fsck=no --type=vfat \
        --options="rw,nosuid,nodev,noexec,sync,uid=0,gid=$gid,fmask=0117,dmask=0007" \
        "$identity" "$mountpoint" || {
        fail "Cannot mount the device: $device"
        return 1
    }
}

main() {
    if [[ -n ${INSTALL:-} && $INSTALL != 0 ]]; then
        install_files
    else
        mount_device "${1:-}"
    fi
}

main "$@"
exit $?
