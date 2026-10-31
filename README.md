# UF2 mount

This script configures automatic mounting of USB FAT volumes containing `INFO_UF2.TXT`:

- Monitored with `udev`, triggers `systemd` service.
- Shell script verifies UF2 signature, mounts device.
- Mounts with read+write access for the `disk` group.
- Uses volume label as name of mount point.
- Mount points are created in `/mnt` by default.

## Installation

Requirements:

- `bash`
- `sudo`
- `systemd`
- `udev`
- [`mtools`](http://www.gnu.org/software/mtools/) (for `mdir`)

Put `uf2-mount.bash` in the location where it will stay. Make it executable, install the `udev` rule and `systemd` service:

```sh
chmod +x /path/to/uf2-mount.bash
sudo INSTALL=1 /path/to/uf2-mount.bash
```

> [!TIP]
> To change the mount point prefix or installation paths for the rule and service, edit the variables at the top of the script.

The service uses the script at this path. If you move the script, run the installation command again from the new path.

> [!IMPORTANT]
> The volume must have a label. If the mount directory is in use or is not empty, the script does not mount the volume.
