#!/usr/bin/env bash
set -euo pipefail

# Copyright (c) 2015 by Roderick W. Smith
# Copyright (c) 2021 by profzei
# Licensed under the terms of the GPL v3
# Modified by LUKAKEITON, perez987, AlexFullmoon
# Content of 'binaries' folder is provided for convenience under its own license

GC='\033[0;32m'
RC='\033[0;31m'
NC='\033[0m'

# Function to display help message
show_help() {
    echo -e "This script can:"
    echo -e "- create signing keys"
    echo -e "- download and include Microsoft database keys"
    echo -e "- optionally include Microsoft keys in KEK"
    echo -e "- download chosen OpenCore version and sign all necessary files"
    echo -e "- sign any user files placed in 'user' folder"
    echo -e " "
    echo -e "Possibly useful things to sign:"
    echo -e "Ventoy: EFI/BOOT/BOOTX64.EFI (disable SecureBoot support in installer)"
    echo -e " "
    echo -e "${RC}Known caveats: ${NC}"
    echo -e "Thinkpad T, X and P series firmware depend on Lenovo keys in KEK and db."
    echo -e "This may apply to other similar 'corporate/secure' hardware."
    echo -e "${RC}DO NOT${NC} remove them, this may result in bricking firmware."
    echo -e "Use minimal key generation."
    echo -e " "
    echo -e "Full keys installation:"
    echo -e "Put *.auth files from 'efikeys' dir on FAT32 formatted USB"
    echo -e "Boot into UEFI, go to Security/Secure Boot"
    echo -e "Delete keys/Reset keystore/Secureboot mode: Setup or whatever your UEFI says"
    echo -e "Proceed in ${RC}EXACTLY THIS${NC} order:"
    echo -e " 1. Install Authorized signatures (db)"
    echo -e " 2. Install Key Exchange Keys (KEK)"
    echo -e " 3. Install Platform Key (PK)"
    echo -e " "
    echo -e "Minimal keys installation (Thinkpad example):"
    echo -e "Put ISK.cer from 'efikeys' dir on FAT32 formatted USB"
    echo -e "Boot into UEFI, go to Security/Secure Boot/Key Management"
    echo -e "In DB keys choose Enroll key"
    echo -e "Select ISK.cer from USB and enter UUID."
    echo -e " "
    #exit 0
}

# Function to display main menu
show_menu() {
    clear
    echo -e "${GC}==>> SecureBoot signing script${NC}"
    echo -e "${GC}=====================================================${NC}"
    echo -e "1) Switch key generation mode (current: $(get_current_mode))"
    echo -e "2) Generate keys"
    echo -e "3) Download and sign OpenCore"
    echo -e "4) Sign .efi files placed in 'user' folder"
    echo -e "5) Help"
    echo -e "6) Quit"
    echo -e "${GC}======================================================${NC}"
}

# Function to get current mode from config
get_current_mode() {
    local CONFIG_FILE=".sbsign_config"
    if [[ -f "$CONFIG_FILE" ]]; then
        local mode=$(grep "^KEY_MODE=" "$CONFIG_FILE" | cut -d'=' -f2)
        echo "$mode"
    else
        echo "not set"
    fi
}

# Function to handle menu choice
handle_menu_choice() {
    local choice="$1"
    case "$choice" in
        1)
            handle_config
            ;;
        2)
            if ! check_required_tools; then
                return
            fi
            KEY_MODE=$(get_current_mode)
            if [[ "$KEY_MODE" == "not set" ]]; then
                echo -e "${RC}==>${NC} Error: Key mode not set. Please choose it first."
                read -rp "Press Enter to continue..."
                return
            fi
            handle_key_generation "$KEY_MODE"
            read -rp "Press Enter to continue..."
            ;;
        3)
            if ! check_required_tools; then
                return
            fi
            if ! [[ -d efikeys ]]; then
                echo -e "${RC}==>${NC} Error: Keys not generated. Please generate keys first."
                read -rp "Press Enter to continue..."
                return
            fi
            VERSION=$(get_opencore_version)
            handle_opencore "$VERSION"
            read -rp "Press Enter to continue..."
            ;;
        4)
            if ! check_required_tools; then
                return
            fi
            if ! [[ -d efikeys ]]; then
                echo -e "${RC}==>${NC} Error: Keys not generated. Please generate keys first."
                read -rp "Press Enter to continue..."
                return
            fi
            sign_user_files
            read -rp "Press Enter to continue..."
            ;;
        5)
            show_help
            read -rp "Press Enter to continue..."
            ;;
        6)
            
            echo -e "${GC}==>${NC} Exiting..."
            exit 0
            ;;
        *)
            echo -e "${RC}==>${NC} Invalid choice"
            read -rp "Press Enter to continue..."
            ;;
    esac
}

# Function to check required tools
check_required_tools() {
    local REQUIRED_TOOLS=(openssl wget unzip sbsign cert-to-efi-sig-list sign-efi-sig-list curl uuidgen setfacl)
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            echo "${RC}==>${NC} Error: $tool is not installed. Please install it and rerun the script."
            echo "${RC}==>${NC} Running in Ubuntu 22.04 is recommended"
            echo "${RC}==>${NC} To install everything run: ${GC}apt install openssl sbsigntool efitools unzip uuid-runtime curl wget acl${NC}"
            read -rp "Press Enter to continue..."
            return 1
        fi
    done
    return 0
}

# Function to get latest OpenCore version
get_latest_opencore_version() {
    local latest_version
    latest_version=$(curl -s https://api.github.com/repos/acidanthera/OpenCorePkg/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    if [[ -z "$latest_version" ]]; then
        echo -e "${RC}==>${NC} Error: Could not fetch latest OpenCore version."
        exit 1
    fi
    echo "$latest_version"
}

# Function to get OpenCore version
get_opencore_version() {
    local VERSION=""
    local latest_version
    latest_version=$(get_latest_opencore_version)
    
    while [[ -z "${VERSION:-}" ]]; do
        read -rp "=> Enter the OpenCore version to use [latest: ${latest_version}]: " VERSION
        if [[ -z "$VERSION" ]]; then
            VERSION="$latest_version"
            # echo -e "${GC}=>${NC} Using latest version: ${VERSION}"
        fi
        if ! [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RC}==>${NC} Invalid version format. Please use e.g., 1.0.4"
            VERSION=""
        fi
    done
    echo "$VERSION"
}

# Function to handle configuration
handle_config() {
    local CONFIG_FILE=".sbsign_config"
    local OLD_MODE=""
    local KEY_MODE=""
    if [[ -f "$CONFIG_FILE" ]]; then
        OLD_MODE=$(grep "^KEY_MODE=" "$CONFIG_FILE" | cut -d'=' -f2)
    fi

    echo -e "${GC}==>${NC} Choose key generation mode:"
    echo -e "1) Full replacement (PK, KEK, ISK)"
    echo -e "2) Minimal mode (ISK only)"
    while true; do
        read -rp "=> Enter choice [1]: " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[12]$ ]]; then
            KEY_MODE=$([[ "$choice" == "1" ]] && echo "full" || echo "minimal")
            break
        else
            echo -e "${RC}==>${NC} Please enter 1 or 2"
        fi
    done

    if [[ -n "$OLD_MODE" && "$KEY_MODE" != "$OLD_MODE" && -d efikeys ]]; then
        echo -e "${RC}==>${NC} WARNING: Switching key mode will delete all previously generated keys!"
        read -rp "=> Are you sure you want to continue? This will remove 'efikeys' [y/N]: " confirm
        confirm=${confirm:-n}
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf efikeys
            echo -e "${GC}==>${NC} Removed 'efikeys' directory."
        else
            echo -e "${RC}==>${NC} Key mode switch cancelled."
            return
        fi
    fi

    echo "KEY_MODE=$KEY_MODE" > "$CONFIG_FILE"
    echo "$KEY_MODE"
}

# Function to handle key generation
handle_key_generation() {
    local KEY_MODE="$1"
    local ADD_MS_KEK=""
    local DEL_OLD_KEYS=""

    if [[ "$KEY_MODE" == "full" ]]; then
        while true; do
            read -rp "=> Do you want to include Microsoft keys into KEK? (y/N): " ADD_MS_KEK
            ADD_MS_KEK=${ADD_MS_KEK:-n}
            if [[ "$ADD_MS_KEK" =~ ^[yn]$ ]]; then
                break
            else
                echo -e "${RC}==>${NC} Please answer y or n"
            fi
        done
    fi

    if [[ -d efikeys ]]; then
        while true; do
            read -rp "=> Delete previously generated keys? (y/N): " DEL_OLD_KEYS
            DEL_OLD_KEYS=${DEL_OLD_KEYS:-n}
            if [[ "$DEL_OLD_KEYS" =~ ^[yn]$ ]]; then
                break
            else
                echo -e "${RC}==>${NC} Please answer y or n"
            fi
        done
    fi

    echo -e "${GC}==>${NC} Preparing keys"

    if [[ "$DEL_OLD_KEYS" == "y" ]]; then
        echo -e "${GC}==>${NC} Cleaning old keys"
        rm -rf efikeys
    fi

    if [[ "$KEY_MODE" == "full" ]]; then
        full_key_generation
    else
        minimal_key_generation
    fi

    if [[ "$KEY_MODE" == "full" ]]; then
        handle_ms_certificates "$ADD_MS_KEK"
        cd efikeys
        echo -e "${GC}==>${NC} Converting PEM files to ESL"
        for cert in *.pem; do
            cert-to-efi-sig-list -g $(uuidgen) "$cert" "${cert%.pem}.esl"
        done
        echo -e "${GC}==>${NC} Forming db record"
        cat ISK.esl \
            ../mskeys/MS_db.esl \
            > db.esl

        if [ "$ADD_MS_KEK" == "y" ]; then
            echo -e "${GC}==>${NC} Forming KEK record"
            cat KEK.esl \
                ../mskeys/MS_KEK.esl \
                > KEK.esl
        fi

        echo -e "${GC}==>${NC} Signing ESL files"
        sign-efi-sig-list -k PK.key -c PK.pem PK PK.esl PK.auth
        sign-efi-sig-list -k PK.key -c PK.pem KEK KEK.esl KEK.auth
        sign-efi-sig-list -k KEK.key -c KEK.pem db db.esl db.auth
        # Empty key to remove PK in user mode without removing the rest
        sign-efi-sig-list -k PK.key -c PK.pem -g $(uuidgen) PK /dev/null removePK.auth
        cd ..
    else
        cd efikeys
        echo -e "${GC}==>${NC} Converting PEM file to ESL"
        cert-to-efi-sig-list -g "$(< GUID.txt)" ISK.pem ISK.esl
        echo -e "==> =============== GUID ==============="
        echo -e "${GC}==>${NC} $(cat GUID.txt)" 
        echo -e "==> ===================================="

        cd ..
    fi
}

full_key_generation() {
    if ! [[ -d efikeys ]]; then
        echo -e "${GC}==>${NC} Creating efikeys folder"
        mkdir -p -m 0700 efikeys
        setfacl -PRdm u::rw,g::---,o::--- efikeys
    fi
    cd efikeys

    if ! [[ "$DEL_OLD_KEYS" == "n" ]]; then
        echo -e "${GC}==>${NC} Creating PK, KEK and image signing keys"
        openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -subj "/CN=Platform Key" -keyout PK.key -out PK.pem
        openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -subj "/CN=Key Exchange Key" -keyout KEK.key -out KEK.pem
        openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -subj "/CN=Image Signing Key" -keyout ISK.key -out ISK.pem
        chmod 0600 *.key
    fi
    cd ..
}

# Function for minimal key generation
minimal_key_generation() {
    if ! [[ -d efikeys ]]; then
        echo -e "${GC}==>${NC} Creating efikeys folder"
        mkdir -p -m 0700 efikeys
        setfacl -PRdm u::rw,g::---,o::--- efikeys
    fi
    cd efikeys
    if ! [[ "$DEL_OLD_KEYS" == "n" ]]; then
        echo -e "${GC}==>${NC} Creating image signing key"
        uuidgen --random > GUID.txt
        openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -subj "/CN=Personal image signing key/" -keyout ISK.key -out ISK.pem
        openssl x509 -outform DER -in ISK.pem -out ISK.cer
        chmod 0600 *.key
    fi
    cd ..
}

# Function to download and process Microsoft certificates
handle_ms_certificates() {
    local ADD_MS_KEK="$1"
    
    echo -e "${GC}==>${NC} Downloading Microsoft certificates${NC}"
    mkdir -p mskeys
    cd mskeys

    # Download certificates
    local CERT_URLS=(
        "MSKEKCA_2011.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/KEK/Certificates/MicCorKEKCA2011_2011-06-24.der"
        "MSKEKCA_2023.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/KEK/Certificates/microsoft%20corporation%20kek%202k%20ca%202023.der"
        "MSWINCA_2011.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/DB/Certificates/MicWinProPCA2011_2011-10-19.der"
        "MSUEFICA_2011.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/DB/Certificates/MicCorUEFCA2011_2011-06-27.der"
        "MSUEFICA_2023.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/DB/Certificates/microsoft%20uefi%20ca%202023.der"
        "MSWINCA_2023.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/DB/Certificates/windows%20uefi%20ca%202023.der"
        "MSOPTCA_2023.der:https://github.com/microsoft/secureboot_objects/raw/refs/heads/main/PreSignedObjects/DB/Certificates/microsoft%20option%20rom%20uefi%20ca%202023.der"
    )

    for cert_info in "${CERT_URLS[@]}"; do
        IFS=':' read -r filename url <<< "$cert_info"
        if [[ ! -f "$filename" ]]; then
            echo "==> Downloading ${filename}"
            wget --no-check-certificate --content-disposition -O "$filename" "$url"
        else
            echo -e "==> $filename exists. Skipping download."
        fi
    done

    echo -e "${GC}==>${NC} Converting Microsoft certificates to PEM"
    for cert in *.der; do
        openssl x509 -in "$cert" -inform DER -out "${cert%.der}.pem" -outform PEM
    done

    echo -e "${GC}==>${NC} Converting MS PEM files to ESL"
    for cert in *.pem; do
        cert-to-efi-sig-list -g $(uuidgen) "$cert" "${cert%.pem}.esl"
    done

    echo -e "${GC}==>${NC} Adding Microsoft keys to db"
    cat MSWINCA_2011.esl \
        MSUEFICA_2011.esl \
        MSWINCA_2023.esl \
        MSUEFICA_2023.esl \
        MSOPTCA_2023.esl \
        > MS_db.esl

    if [ "$ADD_MS_KEK" == "y" ]; then
        echo -e "${GC}==>${NC} Adding Microsoft keys to KEK"
        cat MSKEKCA_2011.esl \
            MSKEKCA_2023.esl \
            > MS_KEK.esl
    fi

    cd ..
}

# Function to download and sign OpenCore files
handle_opencore() {
    local VERSION="$1"
    
    echo -e "${GC}==>${NC} Downloading Opencore ${VERSION}${NC}"
    echo -e "${GC}==>${NC} Creating directories${NC}"
    mkdir -p signed/EFI/{BOOT,OC/{Drivers,Tools}}
    mkdir -p download

    local LINK="https://github.com/acidanthera/OpenCorePkg/releases/download/${VERSION}/OpenCore-${VERSION}-RELEASE.zip"
    if ! wget -nv "$LINK"; then
        echo -e "${RC}==> Error: Failed to download OpenCore ${VERSION}${NC}"
        exit 1
    fi
    unzip "OpenCore-${VERSION}-RELEASE.zip" "X64/*" -d "download"
    wget -nv -O download/HfsPlus.efi https://github.com/acidanthera/OcBinaryData/raw/master/Drivers/HfsPlus.efi
    local FILES_TO_SIGN=(
        "download/X64/EFI/OC/OpenCore.efi:signed/EFI/OC/OpenCore.efi"
        "download/X64/EFI/OC/Drivers/OpenRuntime.efi:signed/EFI/OC/Drivers/OpenRuntime.efi"
        "download/X64/EFI/OC/Drivers/OpenCanopy.efi:signed/EFI/OC/Drivers/OpenCanopy.efi"
        "download/X64/EFI/OC/Drivers/OpenLinuxBoot.efi:signed/EFI/OC/Drivers/OpenLinuxBoot.efi"
        "download/X64/EFI/OC/Drivers/FirmwareSettingsEntry.efi:signed/EFI/OC/Drivers/FirmwareSettingsEntry.efi"
        "download/X64/EFI/OC/Drivers/ResetNvramEntry.efi:signed/EFI/OC/Drivers/ResetNvramEntry.efi"
        "download/X64/EFI/OC/Drivers/ToggleSipEntry.efi:signed/EFI/OC/Drivers/ToggleSipEntry.efi"
        "download/X64/EFI/OC/Drivers/AudioDxe.efi:signed/EFI/OC/Drivers/AudioDxe.efi"
        "download/X64/EFI/OC/Tools/OpenShell.efi:signed/EFI/OC/Tools/OpenShell.efi"
        "download/X64/EFI/BOOT/BOOTx64.efi:signed/EFI/BOOT/BOOTx64.efi"
        "download/HfsPlus.efi:signed/EFI/OC/Drivers/HfsPlus.efi"
        "binaries/btrfs_x64.efi:signed/EFI/OC/Drivers/btrfs_x64.efi"
        "binaries/ext4_x64.efi:signed/EFI/OC/Drivers/ext4_x64.efi"
    )

    for file_info in "${FILES_TO_SIGN[@]}"; do
        IFS=':' read -r input output <<< "$file_info"
        sbsign --key efikeys/ISK.key --cert efikeys/ISK.pem --output "$output" "$input"
    done

    echo -e "${GC}==>${NC} Cleaning up${NC}"
    rm  "OpenCore-${VERSION}-RELEASE.zip"
    rm -r download
    echo -e "${GC}==> OpenCore files signed!${NC}"
}

# Function to sign user files
sign_user_files() {
    echo -e "${GC}==>${NC} Signing user files (will be placed into signed/user)${NC}"
    mkdir -p signed/user
    shopt -s nocaseglob
    for file in user/*.efi; do
        [ -f "$file" ] || continue
        out="signed/user/$(basename "$file")"
        sbsign --key efikeys/ISK.key --cert efikeys/ISK.pem --output "$out" "$file"
    done
    shopt -u nocaseglob
}

# Main script execution
if [[ $# -gt 0 ]]; then 
    if [[ "$1" == "help" ]]; then
        echo -e "${GC}==>> SecureBoot signing script${NC}"
        echo -e "Run without arguments."
        echo -e " "
        show_help
        exit 0
    else
        echo -e "${GC}==>> SecureBoot signing script ${NC}"
        echo -e "For information run ${GC}$0 help${NC}"
        echo -e "Otherwise run without arguments."
        exit 0
    fi
fi

# Main menu loop
while true; do
    show_menu
    read -rp "=> Enter your choice [1-6]: " choice
    handle_menu_choice "$choice"
done



