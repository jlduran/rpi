# Raspberry Pi

FreeBSD-based Raspberry Pi (3 or 4) image, built using poudriere.

Largely inspired by [NanoBSD]-[embedded].

Poudriere will create an `arm64.aarch64` base jail which will be used to compile the ports listed in `pkglist`.  Then, it will create an image using the base jail and the ports.

There are two possible image versions, ZFS or UFS-based.  As much as we like ZFS, we have observed that UFS performs a little better on the Pi as the base system.

The upgrade process for ZFS is a new boot environment, while for UFS is a ping-pong deployment on a specific partition.  ZFS's boot environments can be kept as needed, as long as the current version supports them.

The system is mounted read-only to preserve the life of the SD card or EEPROM (in the case of a compute module).

As a recommended best practice, we currently keep the base system with a UFS file system, and external drives with ZFS (similar to [schenkeveld10]).

> **NOTE**: At the moment, poudriere needs a number of fixes.  In the meantime, use https://github.com/jlduran/poudriere/tree/quilt.

## Create a new image

1. Create a poudriere jail with a `GENERIC-MMCCAM-NODEBUG` kernel

       poudriere jail -c -j rpi -a arm64.aarch64 -m git+https -v main -K GENERIC-MMCCAM-NOEBUG

2. Create a ports tree

       poudriere ports -c -U https://git.freebsd.org/ports.git -B main -p latest

3. Create/modify the list of ports to be included

       cat > pkglist <<EOF
       editors/vim
       lang/python
       security/sudo
       ...
       EOF

4. Build the ports

       poudriere bulk -j rpi -p latest -f pkglist

5. Create the image

       poudriere image -t firmware -j rpi -s 8g -p latest -h raspberrypi -n raspberrypi \
           -f pkglist -c overlaydir -B pre-script-ufs.sh

   If ZFS is desired

       poudriere image -t zfs -j rpi -s 4g -p latest -h raspberrypi -n raspberrypi \
           -f pkglist -c overlaydir -B pre-script-zfs.sh

6. Optionally, test the image

       qemu-system-aarch64 -m 4096M -cpu cortex-a72 -M virt \
           -bios /usr/local/share/u-boot/u-boot-qemu-arm64/u-boot.bin \
           -serial telnet::4444,server -nographic \
           -drive if=none,file=/usr/local/poudriere/data/images/raspberrypi.img,id=hd0 \
           -device virtio-blk-device,drive=hd0

7. Copy the image to the SD card

       dd if=/usr/local/poudriere/data/images/raspberrypi.img \
          of=/dev/da0 bs=4M conv=fsync status=progress

## Upgrade an image

1. Update the poudriere jail

       poudriere jail -u -j rpi

2. Update the ports tree

       poudriere ports -u -p latest

4. Build the ports

       poudriere bulk -j rpi -p latest -f pkglist

5. Create a boot environment (BE)

       poudriere image -t zfs+send+be -j rpi -s 4g -p latest -h raspberrypi -n raspberrypi \
           -f pkglist -c overlaydir -B pre-script-zfs.sh

6. Test the BE image:

   1. Optionally, compress the BE image created in the previous step

          xz -9 --keep /usr/local/poudriere/data/images/raspberrypi.be.zfs

   2. Start a VM with the old image

          qemu-system-aarch64 -m 4096M -cpu cortex-a72 -M virt \
              -bios /usr/local/share/u-boot/u-boot-qemu-arm64/u-boot.bin \
              -serial telnet::4444,server -nographic \
              -drive if=none,file=/usr/local/poudriere/data/images/raspberrypi.img,id=hd0 \
              -device virtio-blk-device,drive=hd0

   3. From the Raspberry Pi, import the new BE

          fetch -o - https://srv/raspberrypi.be.zfs.xz | unxz | bectl import newbe

   4. Boot once

          bectl activate -t newbe

   5. Reboot

          shutdown -r now "Rebooting for a firmware upgrade"

## Configuration changes

In order to save configuration changes, issue the following command:

    # save_cfg

Configuration (`/etc` and `/usr/local/etc`) changes will be saved to `/cfg` (and `/cfg/local`).

## To do

- [ ] Adapt NanoBSD's update scripts
   - [ ] UFS (Files-UFS)
   - [ ] ZFS (Files-ZFS)
- [ ] Test gunion(8) `/cfg` (unionfs works, but...)
- [ ] Incremental ZFS snapshots
- [ ] Clean-up pre-scripts
- [ ] Improve sample directories and pkglist
- [ ] Improve documentation

[NanoBSD]: https://papers.freebsd.org/2005/phk-nanobsd/
[embedded]: https://github.com/freebsd/freebsd-src/tree/main/tools/tools/nanobsd/embedded
[schenkeveld10]: https://2010.asiabsdcon.org/papers/abc2010-P4A-paper.pdf
