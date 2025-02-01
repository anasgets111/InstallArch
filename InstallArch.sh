#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status to avoid cascading errors
set -e

# Define color variables for output to make messages more readable/colored
BLACK=$'\e[0;30m'  # Black color
WHITE=$'\e[0;37m'  # White color
BWHITE=$'\e[1;37m' # Bold White color
RED=$'\e[0;31m'    # Red color
BLUE=$'\e[0;34m'   # Blue color
GREEN=$'\e[0;32m'  # Green color
YELLOW=$'\e[0;33m' # Yellow color
NC=$'\e[0m'        # No Color

# Show greeting message ASCII art
echo "        ${RED}Thank you for using my script!${NC}"

# Enable parallel downloads and color in pacman configuration
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf

# Update keyrings and install necessary packages
pacman -Sy --noconfirm archlinux-keyring
pacman -S --noconfirm --needed pacman-contrib fzf reflector rsync bc

# Prompt user to select the disk for installation using fzf for interactive selection
echo "${BLUE}:: ${BWHITE}Select disk to install system on.${NC}"
DISKS=$(lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print "/dev/"$2"|"$3}')
while [ -z "${DISK}" ]; do
  DISK=$(echo "$DISKS" | fzf --height=20% --layout=reverse | sed 's/|.*//')
done
# Retrieve the size of the selected disk
DISK_SIZE=$(lsblk -n --output SIZE "${DISK}" | head -n1)
echo "${BLUE}:: ${BWHITE}Selected disk: ${BLUE}${DISK}${NC}"
echo "${BLUE}:: ${BWHITE}Size: ${DISK_SIZE}GB${NC}"

# Prompt user to confirm if they want to erase the disk before partitioning
read -rp "${BLUE}:: ${BWHITE}Erase ${DISK} before partitioning? [Y/n]${NC} " erase_disk
use_x_efi="n"
if [[ "$erase_disk" =~ ^[nN] ]]; then
  # Find EFI partition by its PARTTYPE identifier (EFI code), if present
  EFI_PART=$(lsblk -n -o PARTTYPE,KNAME "$DISK" | awk '$1=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" { print "/dev/"$2 }')
  if [ -n "$EFI_PART" ]; then
    echo "${BLUE}:: ${BWHITE}EFI partition found: ${BLUE}${EFI_PART}${NC}"
    read -rp "${BLUE}:: ${BWHITE}Use existing EFI partition? [Y/n]${NC} " use_x_efi
  fi
fi

# Automatically select zram for swap
SWAP_TYPE="zram"
# Calculate total RAM in GB from /proc/meminfo
TOTAL_RAM_GB=$(echo "scale=1; $(grep -i 'memtotal' /proc/meminfo | grep -o '[[:digit:]]*')/1000000" | bc)
echo "${YELLOW}:: ${BWHITE}You have ${TOTAL_RAM_GB}GB of RAM.${NC}"
echo "${YELLOW}:: ${BWHITE}Creating ${TOTAL_RAM_GB}GB zram swap...${NC}"

# Prompt user to create a non-root username and password
read -rp "${BLUE}:: ${BWHITE}Enter your username: ${NC}" USERNAME
while true; do
  echo -n "${YELLOW}:: ${BWHITE}Please enter your password: ${NC}"
  read -rs password
  echo -ne "\n${YELLOW}:: ${BWHITE}Please repeat your password: ${NC}"
  read -rs password2
  if [ "$password" = "$password2" ]; then
    echo -e "\n${GREEN}:: ${BWHITE}Passwords match.${NC}"
    PASSWORD="$password"
    break
  else
    echo -e "\n${RED}:: ${BWHITE}Passwords do not match. Try again.${NC}"
  fi
done

# Prompt user for a hostname
read -rp "${YELLOW}:: ${BWHITE}Please enter your hostname: ${NC}" MACHINE_NAME

# Enable time synchronization
timedatectl set-ntp true

# Prompt user to decide if they want to use reflector to rank mirrors
read -rp "${BLUE}:: ${BWHITE}Setup faster mirrors with reflector? [Y/n]${NC} " mirrors_setup
if [[ ! $mirrors_setup =~ ^[nN] ]]; then
  reflector -a 48 -f 10 -l 20 --sort rate --save /etc/pacman.d/mirrorlist &
  pid=$!
  sp="/-\|"
  i=1
  echo -n ' '
  while [ -d /proc/$pid ]; do
    printf "\b${sp:i++%${#sp}:1}"
    sleep 0.1
  done
  echo "${GREEN}:: ${BWHITE}Mirrorlist updated.${NC}"
fi

# Create a mount directory for the new system
mkdir -p /mnt

# Install prerequisites for partitioning and filesystem creation
pacman -S --noconfirm --needed gptfdisk btrfs-progs glibc

# Make sure everything is unmounted to avoid issues
if grep -qs '/mnt' /proc/mounts; then
  umount -AR /mnt
fi

# Confirm with the user before proceeding with disk formatting
read -rp "${RED}:: ${BWHITE}This will erase data on ${DISK} if chosen. Continue? [y/N]${NC} " confirm_erase
if [[ ! $confirm_erase =~ ^[yY]$ ]]; then
  echo "${RED}:: ${BWHITE}Aborted.${NC}"
  exit 1
fi

# If user wants to erase disk, wipe partition table and create new GPT
if [[ $erase_disk =~ ^[yY] || -z $erase_disk ]]; then
  sgdisk -o "${DISK}"
  sgdisk -n "1::+512M" -t 1:EF00 -c 1:"EFIBOOT" "${DISK}"
  sgdisk -n "2::" -t 2:8300 -c 2:"Archlinux" "${DISK}"
  partprobe "${DISK}"
  EFI_PART="/dev/disk/by-partlabel/EFIBOOT"
else
  if [[ $use_x_efi =~ ^[yY] ]]; then
    EFI_PART="$EFI_PART"
  else
    sgdisk -o "${DISK}"
    sgdisk -n "1::+512M" -t 1:EF00 -c 1:"EFIBOOT" "${DISK}"
    sgdisk -n "2::" -t 2:8300 -c 2:"Archlinux" "${DISK}"
    partprobe "${DISK}"
    EFI_PART="/dev/disk/by-partlabel/EFIBOOT"
  fi
fi

# Format the EFI partition and root partition
mkfs.fat -F32 -n "EFIBOOT" "${EFI_PART}"
mkfs.btrfs -L Archlinux -f "/dev/disk/by-partlabel/Archlinux"

# Create BTRFS subvolumes for root, home, var, tmp, cache, log, snapshots, docker
echo "${BLUE}:: ${BWHITE}Creating BTRFS subvolumes...${NC}"
# Mount the root partition to /mnt to create subvolumes
mount -t btrfs -o x-mount.mkdir LABEL=Archlinux /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@docker
umount /mnt # Unmount root to remount with subvolumes

# Set mount options for read/write performance & compression
MOUNT_OPTIONS="defaults,x-mount.mkdir,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"

# Mount @ (root) subvolume
echo "${BLUE}:: ${BWHITE}Mounting @ subvolume...${NC}"
mount -t btrfs -o subvol=@,$MOUNT_OPTIONS LABEL=Archlinux /mnt

# Mount rest of the BTRFS subvolumes
echo "${BLUE}:: ${BWHITE}Mounting other btrfs subvolumes...${NC}"
mount -t btrfs -o subvol=@home,$MOUNT_OPTIONS LABEL=Archlinux /mnt/home
mount -t btrfs -o subvol=@tmp,$MOUNT_OPTIONS LABEL=Archlinux /mnt/tmp
mount -t btrfs -o subvol=@cache,$MOUNT_OPTIONS LABEL=Archlinux /mnt/var/cache
mount -t btrfs -o subvol=@log,$MOUNT_OPTIONS LABEL=Archlinux /mnt/var/log
mount -t btrfs -o subvol=@snapshots,$MOUNT_OPTIONS LABEL=Archlinux /mnt/.snapshots
mount -t btrfs -o subvol=@docker,$MOUNT_OPTIONS LABEL=Archlinux /mnt/var/lib/docker
# Mount EFI partition to /mnt/boot
mount -t vfat "${EFI_PART}" -o x-mount.mkdir /mnt/boot

# Check if drive is mounted, otherwise reboot
if ! grep -qs '/mnt' /proc/mounts; then
  echo "${RED}:: ${BWHITE}Drive not mounted. Cannot continue.${NC}"
  echo "${YELLOW}:: ${BWHITE}Rebooting in 3s...${NC}" && sleep 1
  echo "${YELLOW}:: ${BWHITE}Rebooting in 2s...${NC}" && sleep 1
  echo "${YELLOW}:: ${BWHITE}Rebooting in 1s...${NC}" && sleep 1
  reboot now
fi

# Define prerequisites for the base Arch system
PREREQS=(
  "base"
  "btrfs-progs"
  "linux"
  "linux-firmware"
  "linux-headers"
  "sudo"
  "archlinux-keyring"
  "networkmanager"
)

# Install the basic Arch system into /mnt
echo "${BLUE}:: ${BWHITE}Installing prerequisites to ${BLUE}/mnt${BWHITE}...${NC}"
pacstrap /mnt "${PREREQS[@]}" --noconfirm --needed
# Generate an fstab file from the current system mount layout and print it
genfstab -L /mnt >>/mnt/etc/fstab
echo "${YELLOW}:: ${BWHITE}Generated /etc/fstab:${NC}"
cat /mnt/etc/fstab
sleep 2
# Handle swap choice (only zram)
echo "${BLUE}:: ${BWHITE}Installing ${BLUE}zram${BWHITE} prerequisites...${NC}"
pacstrap /mnt zram-generator --noconfirm --needed

# Function inside host, then export to chroot
function configure_system {
  pacman -Sy --noconfirm archlinux-keyring

  # Detect CPU and install appropriate microcode
  if grep -qi "intel" /proc/cpuinfo; then
    pacman -S --noconfirm --needed intel-ucode
    UCODE="intel-ucode.img"
    CPU_OPTIONS=""
  else
    pacman -S --noconfirm --needed amd-ucode
    UCODE="amd-ucode.img"
    CPU_OPTIONS="amd_pstate=active"
  fi

  bootctl install

  mkdir -p /etc/systemd/zram-generator.conf.d
  cat <<EOT >/etc/systemd/zram-generator.conf
[zram0]
zram-fraction = 1
max-zram-size = none
compression-algorithm = zstd
EOT
  systemctl enable systemd-zram-setup@zram0.service

  mkdir -p /boot/loader/entries
  cat <<EOT >/boot/loader/loader.conf
default arch.conf
timeout 1
console-mode max
editor no
EOT

  cat <<EOT >/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /$UCODE
initrd  /initramfs-linux.img
options root="LABEL=Archlinux" rw rootflags=subvol=@ quiet splash zswap.enabled=0 nowatchdog $CPU_OPTIONS loglevel=3 
EOT

  # Timezone prompt inside chroot
  ln -sf "/usr/share/zoneinfo/${MY_TZ}" /etc/localtime
  hwclock --systohc

  sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" >/etc/locale.conf
  echo "KEYMAP=us" >/etc/vconsole.conf

  echo "${MACHINE_NAME}" >/etc/hostname
  echo "127.0.0.1   localhost" >/etc/hosts
  echo "::1         localhost" >>/etc/hosts
  echo "127.0.1.1   ${MACHINE_NAME}.localdomain ${MACHINE_NAME}" >>/etc/hosts

  echo "root:${PASSWORD}" | chpasswd
  groupadd libvirt >/dev/null 2>&1 || true
  useradd -mG wheel,libvirt -s /bin/bash "${USERNAME}"
  echo "${USERNAME}:${PASSWORD}" | chpasswd
  sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
  sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

  systemctl enable NetworkManager.service
  systemctl enable ModemManager.service

  mkinitcpio -P
}

export -f configure_system
export USERNAME
export PASSWORD
export MACHINE_NAME
export SWAP_TYPE
export MY_TZ
export BLACK
export WHITE
export BWHITE
export RED
export BLUE
export GREEN
export YELLOW
export NC

# Prompt user for timezone
read -rp "Enter your timezone (e.g. 'Africa/Cairo'): " MY_TZ

# Chroot into the new Arch system and run the configure_system script
if ! arch-chroot /mnt /bin/bash -c "configure_system"; then
  echo "${RED}:: ${BWHITE}Chroot failed. Exiting.${NC}"
  exit 1
fi

# Final message indicating setup completion
echo "${GREEN}:: ${BWHITE}Setup completed!${NC}"
read -rp "${RED}:: ${BWHITE}Reboot now? [Y/n]${NC} " reboot_prompt
if [[ ! $reboot_prompt =~ ^[nN] ]]; then
  systemctl reboot
fi
