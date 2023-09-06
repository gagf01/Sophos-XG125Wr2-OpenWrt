#!/bin/sh

VERSION=${1}
PARTITION=${2}
TARGET="x86/64"
PROFILE="Sophos-XG125W-X86-64"

# Create update dir
UPDATE_DIR=/utils/update/${VERSION}
mkdir -p "${UPDATE_DIR}"

printf "Update directory %s created \n" "${UPDATE_DIR}"

# Copy config files
mkdir "${UPDATE_DIR}/etc"

cp -R "/etc/config" "${UPDATE_DIR}/etc/"
cp "/etc/passwd" "${UPDATE_DIR}/etc/passwd"
cp "/etc/group" "${UPDATE_DIR}/etc/group"
cp "/etc/sudoers" "${UPDATE_DIR}/etc/sudoers"
cp "/etc/shadow" "${UPDATE_DIR}/etc/shadow"
cp "/etc/hosts" "${UPDATE_DIR}/etc/hosts"
cp -R "/etc/samba" "${UPDATE_DIR}/etc/"

printf "Config files copied \n"

# Check if build_request.json not exists in update dir
if [ ! -f "${UPDATE_DIR}/build_request.json" ]; then
    # Trim package list from snapshot to retain only top level packages
    PKG_LIST=$(opkg list-installed | cut -f 1 -d ' ')

    JSON_PKG_LIST=""

    for p in ${PKG_LIST}; do
        WHAT_DEPENDS=$(opkg whatdepends "${p}" | sed -n '/^What depends on root set$/{n;p;n;p}')
        if [ -z "$WHAT_DEPENDS" ]; then
            
            #Add comma in front if not first element
            if [ -n "$JSON_PKG_LIST" ]; then
                JSON_PKG_LIST=${JSON_PKG_LIST}','
            fi
            
            JSON_PKG_LIST=${JSON_PKG_LIST}'"'${p}'"'
        fi
    done

    JSON_BODY=$(cat <<EOF
{"packages": [${JSON_PKG_LIST}], "profile": "${PROFILE}", "target": "${TARGET}", "version": "${VERSION}"}
EOF
)

    # Store JSON_BODY in update dir
    echo "${JSON_BODY}" > "${UPDATE_DIR}/build_request.json"

    printf "Build request stored in %s \n" "${UPDATE_DIR}/build_request.json"

else
    printf "Build request already exists in %s \n" "${UPDATE_DIR}/build_request.json"
    JSON_BODY=$(cat "${UPDATE_DIR}/build_request.json")

fi

# Check if build_response.json not exists in update dir
if [ ! -f "${UPDATE_DIR}/build_response.json" ]; then
    # Trigger build
    BUILD_RESP=$(curl -s -X POST -H "Accept: application/json" -H "Content-Type: application/json" https://sysupgrade.openwrt.org/api/v1/build -d "${JSON_BODY}" )

    # Store build response in update dir
    echo "${BUILD_RESP}" > "${UPDATE_DIR}/build_response.json"
    printf "Build response stored in %s \n" "${UPDATE_DIR}/build_response.json"
else
    printf "Build response already exists in %s \n" "${UPDATE_DIR}/build_response.json"
    BUILD_RESP=$(cat "${UPDATE_DIR}/build_response.json")
fi

# Read Build Response
STATUS=$(echo "${BUILD_RESP}" | jq '.status')

case $STATUS in
    200) 
        # Image successfully built
    ;;
    202)
        while [ "${STATUS}" != "200" ]
        do
            printf "Build added to queue or currently building, checking again in 5 seconds. \n"
            sleep 5
            REQUEST_HASH=$(echo "${BUILD_RESP}" | jq -r '.request_hash')
            BUILD_RESP=$(curl -s -X GET -H "Accept: application/json" "https://sysupgrade.openwrt.org/api/v1/build/${REQUEST_HASH}" )
            
            # Overwrite build response in update dir
            rm "${UPDATE_DIR}/build_response.json"
            echo "${BUILD_RESP}" > "${UPDATE_DIR}/build_response.json"
            
            STATUS=$(echo "${BUILD_RESP}" | jq '.status')
        done
    ;;
    400)
        # Invalid build request
        echo "Build request error: "
        echo "${BUILD_RESP}" | jq '.detail'
        exit 255
    ;;
    422)
        # Unknown package(s) in request
        echo "Build request error: "
        echo "${BUILD_RESP}" | jq '.detail'
        exit 255
    ;;
    *)
        # Unknown error
        printf "Build request error: status %s \n" "${STATUS}"
        exit 255
    ;;
esac


# Download kernel and rootfs
URL_PREFIX="https://sysupgrade.openwrt.org/store/$(echo "${BUILD_RESP}" | jq -r '.bin_dir')/"

# Check if kernel already exists
if [ ! -f "${UPDATE_DIR}/kernel.bin" ]; then
    KERNEL_URL=${URL_PREFIX}$(echo "${BUILD_RESP}" | jq -r '.image_prefix')"-kernel.bin"
    printf "Downloading kernel from %s \n" "${KERNEL_URL}"  
    curl --output "${UPDATE_DIR}/kernel.bin" "${KERNEL_URL}"
    printf "Kernel downloaded \n"
fi

# Check if rootfs already exists
if [ ! -f "${UPDATE_DIR}/rootfs.tar.gz" ]; then
    ROOTFS_URL=${URL_PREFIX}$(echo "${BUILD_RESP}" | jq -r '.image_prefix')"-rootfs.tar.gz"
    printf "Downloading rootfs from %s \n" "${ROOTFS_URL}"  
    curl --output "${UPDATE_DIR}/rootfs.tar.gz" "${ROOTFS_URL}"
    printf "Rootfs downloaded \n"
fi

# Mount target partition
PARTITION_PATH=/mnt/${PARTITION}

# Check if partition already mounted
if [ ! -d "${PARTITION_PATH}" ]; then
    mkdir "${PARTITION_PATH}"
    mount "/dev/${PARTITION}" "${PARTITION_PATH}"
fi

printf "Target partition %s mounted in %s \n" "${PARTITION}" "${PARTITION_PATH}"

# Find target Kernel file name in /boot
KERNEL_PATH=$(grep -m 1 "${PARTITION}" /boot/grub/grub.cfg  | awk '{print $2}')

printf "Target kernel is: %s \n" "${KERNEL_PATH}"

# Ask confirmation
printf "Are you sure to update target partition %s ? [y/n] " "${PARTITION}"
read -r CONFIRMATION
if [ "$CONFIRMATION" != "y" ]; then exit 1; fi
printf "\n"

# Delete all files in target partition
rm -Rf "${PARTITION_PATH:?}"/*
printf "Target partition %s content deleted \n" "${PARTITION}"

# Copy new version files in target partition
tar -zxvf "${UPDATE_DIR}/rootfs.tar.gz" -C "${PARTITION_PATH}"
printf "Rootfs extracted in %s \n" "${PARTITION_PATH}"

# Copy config files in target partition
cp -Rf "${UPDATE_DIR}/etc/config"/* "${PARTITION_PATH}/etc/config/"
cp -f "${UPDATE_DIR}/etc/passwd" "${PARTITION_PATH}/etc/passwd" 
cp -f "${UPDATE_DIR}/etc/group" "${PARTITION_PATH}/etc/group"
cp -f "${UPDATE_DIR}/etc/sudoers" "${PARTITION_PATH}/etc/sudoers" 
cp -f "${UPDATE_DIR}/etc/shadow" "${PARTITION_PATH}/etc/shadow" 
cp -f "${UPDATE_DIR}/etc/hosts" "${PARTITION_PATH}/etc/hosts"
mkdir -p "${PARTITION_PATH}/etc/samba"
cp -Rf "${UPDATE_DIR}/etc/samba"/* "${PARTITION_PATH}/etc/samba/"
printf "Config files copied in %s \n" "${PARTITION_PATH}" 

# Fix permission for usr/bin/sudo (need setuid and copying the file seem to remove it...)
chmod u+s "${PARTITION_PATH:?}/usr/bin/sudo"
printf "usr/bin/sudo fixed \n"

# Copy target partition's new kernel
cp "${UPDATE_DIR}/kernel.bin" "${KERNEL_PATH}"
printf "Kernel copied in %s \n" "${KERNEL_PATH}"

# Set Boot default partition to target partition
KERNEL_POSITION=$(( $(grep linux /boot/grub/grub.cfg | grep -n -m 1 "${PARTITION}" | cut -d : -f 1) - 1))
sed -i "s/default=\"[0-9]\"/default=\"${KERNEL_POSITION}\"/g" /boot/grub/grub.cfg
printf "Boot default partition set to %s \n" "${PARTITION}"

# Ask for reboot
printf "Update completed. Do you want to reboot ? [y/n] "
read -r CONFIRMATION
if [ "$CONFIRMATION" = "y" ]; then reboot; fi
