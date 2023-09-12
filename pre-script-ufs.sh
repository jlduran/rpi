#!/bin/sh

# MSDOS_SIZE set the EFI system partition size in MB
MSDOS_SIZE=200

# Size of the /etc ramdisk
NANO_RAM_ETCSIZE="32m"

# Size of the /tmp+/var ramdisk
NANO_RAM_TMPVARSIZE="32m"

NANO_WORLDDIR="${WRKDIR}/world"

make_msdos_file() {
	file=$1
	size=$2
	loader=$3
	FAT16MIN=2
	FAT32MIN=33

	if [ "$size" -ge "$FAT32MIN" ]; then
		fatbits=32
	elif [ "$size" -ge "$FAT16MIN" ]; then
		fatbits=16
	else
		fatbits=12
	fi

	msg "Creating MS-DOS image"
	stagedir=$(mktemp -d /tmp/stand-test.XXXXXX)

	# Copy the EFI bootloader
	mkdir -p "${stagedir}/EFI/BOOT" "${stagedir}/EFI/FreeBSD"
	efibootname=$(get_uefi_bootname)
	cp "${loader}" "${stagedir}/EFI/BOOT/${efibootname}.efi"
	cp "${loader}" "${stagedir}/EFI/FreeBSD/loader.efi"

	# XXX Set the currdev on the EFI environment file
	#echo "set currdev=disk0p2:" > "${stagedir}/EFI/FreeBSD/loader.env"

	# Copy over dtb and firmware files
	cp -R /usr/local/share/rpi-firmware/* ${stagedir}

	# Remove unneeded files
	rm -f "${stagedir}"/config_*

	# Copy the config.txt file
	cp "${SAVED_PWD}/config.txt" "${stagedir}"

	# Copy u-boot
	cp /usr/local/share/u-boot/u-boot-rpi-arm64/u-boot.bin ${stagedir}

	makefs -t msdos \
	    -o fat_type=${fatbits} \
	    -o OEM_string="" \
	    -o sectors_per_cluster=1 \
	    -o volume_label=MSDOSBOOT \
	    -s ${size}m \
	    "${file}" "${stagedir}" \
	    >/dev/null 2>&1
	rm -rf "${stagedir}"
	msg "MS-DOS Image created"
}

_ufs_populate_cfg()
{
	if [ -d "${SAVED_PWD}/cfg" ]; then
		CFGDIR="${SAVED_PWD}/cfg"

		cp -a ${CFGDIR}/* ${NANO_WORLDDIR}/cfg
	fi
}

#
# Convert a directory into a symlink. Takes two arguments, the
# current directory and what it should become a symlink to. The
# directory is removed and a symlink is created.
#
_ufs_tgt_dir2symlink()
{
	dir=$1
	symlink=$2

	cd "${NANO_WORLDDIR}"
	rm -xrf "$dir"
	ln -s "$symlink" "$dir"
}

_ufs_setup_nanobsd()
{
	(
	cd "${NANO_WORLDDIR}"

	# Move /usr/local/etc to /etc/local so that the /cfg stuff
	# can stomp on it.  Otherwise packages like ipsec-tools which
	# have hardcoded paths under ${prefix}/etc are not tweakable.
	if [ -d usr/local/etc ] ; then
		(
		tar -C ${WRKDIR}/world -X ${excludelist} -cf - usr/local/etc | \
		    tar -xf - -C ${WRKDIR}/world/etc/local --strip-components=3
		rm -xrf usr/local/etc
		)
	fi

	# Always setup the usr/local/etc -> etc/local symlink.
	# usr/local/etc gets created by packages, but if no packages
	# are installed by this point, but are later in the process,
	# the symlink not being here causes problems. It never hurts
	# to have the symlink in error though.
	ln -s ../../etc/local usr/local/etc

	for d in var etc
	do
		# link /$d under /conf
		# we use hard links so we have them both places.
		# the files in /$d will be hidden by the mount.
		mkdir -p conf/base/$d conf/default/$d
		tar -C ${WRKDIR}/world -X ${excludelist} -cf - $d | tar -xf - -C ${WRKDIR}/world/conf/base
	done

	echo "$NANO_RAM_ETCSIZE" > conf/base/etc/md_size
	echo "$NANO_RAM_TMPVARSIZE" > conf/base/var/md_size

	# pick up config files from the special partition
	echo "mount -o ro /dev/gpt/cfg" > conf/default/etc/remount

	# Put /tmp on the /var ramdisk (could be symlink already)
	_ufs_tgt_dir2symlink tmp var/tmp
	)
}

_ufs_setup_nanobsd_etc()
{
	(
	cd "${NANO_WORLDDIR}"

	# create diskless marker file
	touch etc/diskless

	# Make root filesystem R/O by default
	sysrc -f etc/defaults/vendor.conf "root_rw_mount=NO"
	# Disable entropy file, since / is read-only
	sysrc -f etc/defaults/vendor.conf "entropy_boot_file=NO"
	sysrc -f etc/defaults/vendor.conf "entropy_file=NO"
	sysrc -f etc/defaults/vendor.conf "entropy_dir=NO"

	# save config file for scripts
	echo "NANO_DRIVE=gpt/${IMAGENAME}" > etc/nanobsd.conf

	echo "/dev/gpt/${IMAGENAME}1	/		ufs	ro			1	1" >> etc/fstab
	echo "/dev/gpt/cfg		/cfg		ufs	rw,noatime,noauto	2	2" >> etc/fstab
	echo "/dev/gpt/data		/data		ufs	rw,noatime		2	2" >> etc/fstab
	mkdir -p cfg
	mkdir -p data

	# Create directory for eventual /usr/local/etc contents
	mkdir -p etc/local

	# Add some first boot empty files
	touch etc/zfs/exports

	# Remove poudriere-populated rc.conf
	rm -f etc/rc.conf
	)
}

_ufs_modify_second_partition()
{
	# Duplicate the first partition
	cp ${WRKDIR}/raw.img ${WRKDIR}/raw2.img

	# Make the duplicated partition an md(4) device
	md_raw2="$(mdconfig -a -t vnode -f ${WRKDIR}/raw2.img)"

	# Create a temporary directory
	TMP_RAW2="$(mktemp -d -t poudriere-firmware-raw2)" || exit 1

	# Mount the md(4) device on to the temporary directory
	mount /dev/"${md_raw2}" "$TMP_RAW2"

	# Make the necessary changes
	sed -i "" "s|gpt/${IMAGENAME}1|gpt/${IMAGENAME}2|" /"$TMP_RAW2"/conf/base/etc/fstab
	sed -i "" "s|gpt/${IMAGENAME}1|gpt/${IMAGENAME}2|" /"$TMP_RAW2"/etc/fstab

	# Clean up
	umount /dev/"${md_raw2}" &&
	    rm -rf "$TMP_RAW2" &&
	    mdconfig -d -u "$md_raw2" || exit 1
}

firmware_build()
{
	# Configuring nanobsd-like mode
	# It re-uses the diskless(8) framework, but using a /cfg configuration partition
	# It uses a "config save" script too, like the nanobsd example:
	#  /usr/src/tools/tools/nanobsd/Files/root/save_cfg
	# Because rootfs is readonly, it creates ramdisks for /etc and /var+/tmp
	# Then we need to replace /tmp by a symlink to /var/tmp
	# For more information, read /etc/rc.initdiskless
	cat >> ${WRKDIR}/world/etc/fstab <<-EOEFI
		# Device		Mountpoint	FStype	Options			Dump	Pass#
		/dev/gpt/efiboot0	/boot/efi	msdosfs	rw,noatime,noauto	2	2
	EOEFI
	if [ -n "${SWAPSIZE}" ] && [ "${SWAPSIZE}" != "0" ]; then
		cat >> ${WRKDIR}/world/etc/fstab <<-EOSWAP
		/dev/gpt/swap0.eli	none		swap	sw,late		0	0
		EOSWAP
	fi

	# NanoBSD-like configuration
	_ufs_setup_nanobsd_etc
	_ufs_populate_cfg
	_ufs_setup_nanobsd

	# Make sure that firstboot scripts run so growfs works.
	touch ${NANO_WORLDDIR}/firstboot
	sysrc -f ${NANOWORLD_DIR}/etc/defaults/vendor.conf growfs_enable=YES

	# Figure out Partition sizes
	OS_SIZE=
	calculate_ospart_size "2" "${NEW_IMAGESIZE_SIZE}" "${CFG_SIZE}" "${DATA_SIZE}" "${SWAPSIZE}"

	# Prune off a bit to fit the extra partitions and loaders
	OS_SIZE=$(( OS_SIZE - 1 - MSDOS_SIZE / 2 ))
	WORLD_SIZE=$(du -ms ${NANO_WORLDDIR} | awk '{print $1}')
	if [ ${WORLD_SIZE} -gt ${OS_SIZE} ]; then
		err 2 "Installed OS Partition needs: ${WORLD_SIZE}m, but the OS Partitions are only: ${OS_SIZE}m.  Increase -s"
	fi

	# For correct booting it needs ufs-formatted /cfg and /data partitions
	FTMPDIR=`mktemp -d -t poudriere-firmware` || exit 1

	# Set proper permissions to this empty directory: so /cfg (/etc) and /data once mounted will inherit them
	chmod -R 755 ${FTMPDIR}
	if [ -d "${SAVED_PWD}/cfg" ]; then
		CFGDIR="${SAVED_PWD}/cfg"
	else
		CFGDIR="${FTMPDIR}"
	fi
	if [ -d "${SAVED_PWD}/data" ]; then
		DATADIR="${SAVED_PWD}/data"
	else
		DATADIR="${FTMPDIR}"
	fi
	makefs -B little -s ${CFG_SIZE} ${WRKDIR}/cfg.img ${CFGDIR}
	makefs -B little -s ${DATA_SIZE} ${WRKDIR}/data.img ${DATADIR}
	rm -rf ${FTMPDIR}
	makefs -B little -s ${OS_SIZE}m -o label=${IMAGENAME} \
		-o version=2 ${WRKDIR}/raw.img ${NANO_WORLDDIR}
}

firmware_generate()
{
	FINALIMAGE=${IMAGENAME}.img

	msdosfilename=$(mktemp /tmp/efiboot.XXXXXX)
	make_msdos_file ${msdosfilename} ${MSDOS_SIZE} ${NANO_WORLDDIR}/boot/gptboot.efi
	_ufs_modify_second_partition

	if [ ${SWAPSIZE} != "0" ]; then
		SWAPCMD="-p freebsd-swap/swap0::${SWAPSIZE_VALUE}${SWAPSIZE_UNIT}"
		if [ $SWAPBEFORE -eq 1 ]; then
			SWAPFIRST="$SWAPCMD"
		else
			SWAPLAST="$SWAPCMD"
		fi
	fi
	mkimg -s gpt -C ${IMAGESIZE} \
	    -p efi/efiboot0:=${msdosfilename} \
	    -p freebsd-ufs/${IMAGENAME}1:=${WRKDIR}/raw.img \
	    -p freebsd-ufs/${IMAGENAME}2:=${WRKDIR}/raw2.img \
	    -p freebsd-ufs/cfg:=${WRKDIR}/cfg.img \
	    ${SWAPFIRST} \
	    -p freebsd-ufs/data:=${WRKDIR}/data.img \
	    ${SWAPLAST} \
	    -o "${OUTPUTDIR}/${FINALIMAGE}"
	rm -rf ${msdosfilename}
}

rawfirmware_build()
{
	# Configuring nanobsd-like mode
	# It re-uses the diskless(8) framework, but using a /cfg configuration partition
	# It uses a "config save" script too, like the nanobsd example:
	#  /usr/src/tools/tools/nanobsd/Files/root/save_cfg
	# Because rootfs is readonly, it creates ramdisks for /etc and /var+/tmp
	# Then we need to replace /tmp by a symlink to /var/tmp
	# For more information, read /etc/rc.initdiskless
	cat >> ${WRKDIR}/world/etc/fstab <<-EOEFI
		# Device		Mountpoint	FStype	Options			Dump	Pass#
		/dev/gpt/efiboot0	/boot/efi	msdosfs	rw,noatime,noauto	2	2
	EOEFI
	if [ -n "${SWAPSIZE}" ] && [ "${SWAPSIZE}" != "0" ]; then
		cat >> ${WRKDIR}/world/etc/fstab <<-EOSWAP
		/dev/gpt/swap0.eli	none		swap	sw,late		0	0
		EOSWAP
	fi

	# NanoBSD-like configuration
	_ufs_setup_nanobsd_etc
	_ufs_populate_cfg
	_ufs_setup_nanobsd

	# Make sure that firstboot scripts run so growfs works.
	touch ${NANO_WORLDDIR}/firstboot
	sysrc -f ${NANOWORLD_DIR}/etc/defaults/vendor.conf growfs_enable=YES

	# Figure out Partition sizes
	OS_SIZE=
	calculate_ospart_size "2" "${NEW_IMAGESIZE_SIZE}" "${CFG_SIZE}" "${DATA_SIZE}" "${SWAPSIZE}"

	# Prune off a bit to fit the extra partitions and loaders
	OS_SIZE=$(( OS_SIZE - 1 - MSDOS_SIZE / 2 ))
	WORLD_SIZE=$(du -ms ${NANO_WORLDDIR} | awk '{print $1}')
	if [ ${WORLD_SIZE} -gt ${OS_SIZE} ]; then
		err 2 "Installed OS Partition needs: ${WORLD_SIZE}m, but the OS Partitions are only: ${OS_SIZE}m.  Increase -s"
	fi

	# For correct booting it needs ufs-formatted /cfg and /data partitions
	FTMPDIR=`mktemp -d -t poudriere-firmware` || exit 1

	# Set proper permissions to this empty directory: so /cfg (/etc) and /data once mounted will inherit them
	chmod -R 755 ${FTMPDIR}
	if [ -d "${SAVED_PWD}/cfg" ]; then
		CFGDIR="${SAVED_PWD}/cfg"
	else
		CFGDIR="${FTMPDIR}"
	fi
	if [ -d "${SAVED_PWD}/data" ]; then
		DATADIR="${SAVED_PWD}/data"
	else
		DATADIR="${FTMPDIR}"
	fi
	makefs -B little -s ${CFG_SIZE} ${WRKDIR}/cfg.img ${CFGDIR}
	makefs -B little -s ${DATA_SIZE} ${WRKDIR}/data.img ${DATADIR}
	rm -rf ${FTMPDIR}
	makefs -B little -s ${OS_SIZE}m -o label=${IMAGENAME} \
		-o version=2 ${WRKDIR}/raw.img ${NANO_WORLDDIR}
}
