get_uboot_interface_from_device() {
    case "$1" in
        /dev/mmcblk* )
            echo mmc
            ;;
        *)
            bberror "Could not determine U-Boot interface from $1"
            exit 1
            ;;
    esac
}

get_uboot_device_from_device() {
    dev_base="unknown"
    case "$1" in
        /dev/mmcblk*p* )
            dev_base=$(echo $1 | cut -dk -f2 | cut -dp -f1)
            ;;
        /dev/mmcblk* )
            dev_base=$(echo $1 | cut -dk -f2)
            ;;
    esac

    device=$(printf "%d" $dev_base 2>/dev/null)
    if [ $? = 1 ]; then
        bberror "Could not determine U-Boot device from $1"
        exit 1
    else
        echo $device
    fi
}

get_grub_device_from_device_base() {
    case "$1" in
        /dev/[sh]d[a-z])
            dev_number=${1#/dev/[sh]d}
            dev_number=$(expr $(printf "%d" "'$dev_number") - $(printf "%d" "'a") || true)
            echo "hd$dev_number"
            ;;
        /dev/mmcblk[0-9]p)
            dev_number=${1#/dev/mmcblk}
            dev_number=${dev_number%p}
            echo "hd$dev_number"
            ;;
        /dev/nvme[0-9]n[0-9]p)
            dev_number=${1#/dev/nvme?n}
            dev_number=$(expr $(printf "%d" "'$dev_number") - $(printf "%d" "'1") || true)
            echo "hd$dev_number"
            ;;
        *)
            bberror "Could not determine Grub device from $1"
            exit 1
            ;;
    esac
}

get_part_number_from_device() {
    dev_base="unknown"
    case "$1" in
        /dev/mmcblk*p* )
            dev_base=$(echo $1 | cut -dk -f2 | cut -dp -f2)
            ;;
        /dev/[sh]d[a-z][1-9])
            dev_base=${1##*d[a-z]}
            ;;
        /dev/nvme[0-9]n[0-9]p[0-9])
            dev_base=$(echo $1 | cut -dp -f2)
            ;;
        ubi*_* )
            dev_base=$(echo $1 | cut -d_ -f2)
            ;;
        /dev/disk/by-partuuid/* )
            bberror "Please enable mender-partuuid Distro feature to use PARTUUID"
            ;;
    esac
    part=$(printf "%d" $dev_base 2>/dev/null)
    if [ $? = 1 ]; then
        bberror "Could not determine partition number from $1"
        exit 1
    else
        echo $part
    fi
}

get_part_number_hex_from_device() {
    part_dec=$(get_part_number_from_device $1)
    part_hex=$(printf "%X" $part_dec 2>/dev/null)
    if [ $? = 1 ]; then
        bberror "Could not determine partition number from $1"
        exit 1
    else
        echo $part_hex
    fi
}

mender_number_to_hex() {
    part_hex=$(printf "%X" $1 2>/dev/null)
}

def mender_get_partuuid_from_device(d, deviceName):
    import re
    if bb.utils.contains('DISTRO_FEATURES', 'mender-partuuid', True, False, d) and deviceName:
        uuid=deviceName.replace('/dev/disk/by-partuuid/', '')
        gptMatch = re.search('^[0-9a-f]{8}\-[0-9a-f]{4}\-[0-9a-f]{4}\-[0-9a-f]{4}\-[0-9a-f]{12}$', uuid)
        if gptMatch:
            return gptMatch.group(0)

        msdosMatch = re.search("^[0-9a-f]{8}\-[0-9]{2}$", uuid)
        if msdosMatch:
            return msdosMatch.group(0)
        bb.fatal("%s Does not contain a valid PARTUUID path" % deviceName )
    return

def mender_make_mtdparts_shell_array(d):
    """Makes a string that can be shell-eval'ed to get the components of the
    mtdparts string. See the "local mtd_..." definitions below."""

    mtdparts = d.getVar('MENDER_MTDPARTS')
    if len(mtdparts) == 0:
        return "bbfatal 'MENDER_MTDPARTS is empty.'"

    active_mtdid = d.getVar('MENDER_IS_ON_MTDID')
    if len(active_mtdid) == 0:
        return "bbfatal 'MENDER_IS_ON_MTDID is empty. Please set it to the mtdid inside MENDER_MTDPARTS that you want Mender to use.'"

    import re

    # Breaking up the mtdparts string in shell is tricky, so do it here, and
    # just return a string that can be eval'ed in the shell. Can't use real bash
    # arrays though... sigh.
    count = 0
    total_offset = 0
    shell_cmd = ""
    remaining_encountered = False

    # Pick the mtdid that matches MENDER_IS_ON_MTDID.
    current_mtdparts = None
    for part in mtdparts.split(";"):
        if part.split(":")[0] == active_mtdid:
            current_mtdparts = part

    if current_mtdparts is None:
        return ("bbfatal 'Cannot find a valid mtdparts string inside MENDER_MTDPARTS (\"%s\"), "
                + "corresponding to MENDER_IS_ON_MTDID (\"%s\").'"
                % (mtdparts, active_mtdid))

    mtdparts = current_mtdparts

    # Skip first component (the ID).
    for component in mtdparts.split(":")[1].split(","):
        if len(component) == 0:
            continue

        if remaining_encountered:
            return "bbfatal \"'-' entry was not last entry in mtdparts: '%s'\"" % mtdparts

        match = re.match("^([0-9]+|-)([kmg]?)(?:@([0-9]+)([kmg]?))?\(([^)]+)\)(?:ro)?$", component)
        if match is None:
            return "bbfatal \"'%s' is not a valid mtdparts string. Please set MENDER_MTDPARTS to a valid value\"" % mtdparts

        # Make a shell array out of the mtdparts.
        if match.group(3) is None:
            offset = total_offset
        else:
            offset = mender_mtdparts_convert_units_to_bytes(match.group(3), match.group(4))

        if match.group(1) == '-':
            size = '-'
            kbsize = '-'
            remaining_encountered = True
        else:
            size = mender_mtdparts_convert_units_to_bytes(match.group(1), match.group(2))
            kbsize = int(size / 1024)
            total_offset = offset + size

        name = match.group(5)

        shell_cmd += "local mtd_sizes_%d='%s'\n" % (count, size)
        shell_cmd += "local mtd_kbsizes_%d='%s'\n" % (count, kbsize)
        shell_cmd += "local mtd_offsets_%d='%d'\n" % (count, offset)
        shell_cmd += "local mtd_kboffsets_%d='%d'\n" % (count, offset / 1024)
        shell_cmd += "local mtd_names_%d='%s'\n" % (count, name)

        count += 1

    shell_cmd += "local mtd_count=%d\n" % count

    return shell_cmd

def mender_mtdparts_convert_units_to_bytes(number, unit):
    if unit is None or unit.lower() == '':
        to_return = int(number)
    elif unit.lower() == 'k':
        to_return = int(number) * 1024
    elif unit.lower() == 'm':
        to_return = int(number) * 1048576
    elif unit.lower() == 'g':
        to_return = int(number) * 1073741824
    else:
        bb.fatal("Cannot parse number '%s' and unit '%s'" % (number, unit))

    if to_return % 1024 != 0:
        bb.fatal("Numbers in mtdparts must be aligned to a KiB boundary")

    return to_return

mender_get_clean_kernel_devicetree() {
    # Strip leading and trailing whitespace, then newline divide, and remove dtbo's.
    MENDER_DTB_NAME="$(echo "${KERNEL_DEVICETREE}" | sed -r 's/(^\s*)|(\s*$)//g; s/\s+/\n/g' | sed -ne '/\.dtbo$/b; p')"

    if [ -z "$MENDER_DTB_NAME" ]; then
        bbfatal "Did not find a dtb specified in KERNEL_DEVICETREE"
        exit 1
    fi

    DTB_COUNT=$(echo "$MENDER_DTB_NAME" | wc -l)

    if [ "$DTB_COUNT" -ne 1 ]; then
        bbwarn "Found more than one dtb specified in KERNEL_DEVICETREE. Only one should be specified. Choosing the last one."
        MENDER_DTB_NAME="$(echo "$MENDER_DTB_NAME" | tail -1)"
    fi

    # Now strip any subdirectories off.  Some kernel builds require KERNEL_DEVICETREE to be defined, for example,
    # as qcom/apq8016-sbc.dtb yet when installed, they go directly in /boot
    MENDER_DTB_NAME="$(basename "$MENDER_DTB_NAME")"

    # Return.
    echo "$MENDER_DTB_NAME"
}


def mender_is_msdos_ptable_image(d):
    mptimgs = 'mender-image-sd mender-image-bios'
    return bb.utils.contains_any('MENDER_FEATURES_ENABLE', mptimgs , True, False, d)


def mender_get_data_part_num(d):
    n = 3
    boot_part_size = d.getVar('MENDER_BOOT_PART_SIZE_MB')
    swap_part_size = d.getVar('MENDER_SWAP_PART_SIZE_MB')
    if (boot_part_size and boot_part_size != '0'): n += 1
    if (swap_part_size and swap_part_size != '0'): n += 1

    #is an msdos extended partion going to be required
    if n <= 4: return n
    if mender_is_msdos_ptable_image(d): n += 1
    return n

# Take the content from the rootfs that is going into the boot partition, coming
# from MENDER_BOOT_PART_MOUNT_LOCATION, and merge with the files from
# IMAGE_BOOT_FILES, following the format from the official Yocto documentation.
mender_merge_bootfs_and_image_boot_files() {
    W="${WORKDIR}/bootfs.${BB_CURRENTTASK}"
    rm -rf "$W"

    cp -al "${IMAGE_ROOTFS}/${MENDER_BOOT_PART_MOUNT_LOCATION}" "$W"

    # Put in variable to avoid expansion and ';' being parsed by shell.
    image_boot_files="${IMAGE_BOOT_FILES}"
    for entry in $image_boot_files; do
        if echo "$entry" | grep -q ";"; then
            dest="$(echo "$entry" | sed -e 's/[^;]*;//')"
            entry="$(echo "$entry" | sed -e 's/;.*//')"
        else
            dest="./"
        fi
        if echo "$dest" | grep -q '/$'; then
            dest_is_dir=1
            mkdir -p "$W/$dest"
        else
            dest_is_dir=0
            mkdir -p "$(dirname "$W/$dest")"
        fi

        # Use extra for loop so we can check conflict for each file.
        for file in ${DEPLOY_DIR_IMAGE}/$entry; do
            if [ $dest_is_dir -eq 1 ]; then
                destfile="$W/$dest$(basename $file)"
            else
                destfile="$W/$dest"
            fi
            if [ -e "$destfile" ]; then
                bbfatal "$destfile already exists in boot partition. Please verify that packages do not put files in the boot partition that conflict with IMAGE_BOOT_FILES."
            fi
            cp -l "$file" "$destfile"
        done
    done
}
