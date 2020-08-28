#!/usr/bin/env bash

##############################################################
# Title          : install-imagemagick7.sh                   #
# Description    : ImageMagick® 7 for Debian/Ubuntu,         #
#                  including advanced delegate support.      #
#                                                            #
# Author         : Sascha Greuel <hello@1-2.dev>             #
# Date           : 2020-08-28 06:52:12                       #
# License        : MIT                                       #
# Version        : 4.0.0                                     #
#                                                            #
# Usage          : bash install-imagemagick7.sh              #
##############################################################

######################
# Check requirements #
######################

# Check if user is root
[ "$(id -u)" != "0" ] && {
  echo "Error: You must be root or use sudo to run this script"
  exit 1
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

# Make sure, that we are on Debian or Ubuntu
if ! command_exists apt-get; then
  echo "This script cannot run on any other system than Debian or Ubuntu"
  exit 1
fi

# Checking if lsb_release is installed or install it
if ! command_exists lsb_release; then
  apt-get install -qq lsb-release >/dev/null 2>&1
fi

# Check if required packages are installed or install them
required_packages="wget jq"

for package in $required_packages; do
  if ! command_exists "$package"; then
    apt-get install -qq "$package" >/dev/null 2>&1
  fi
done

####################
# Script arguments #
####################

while [ "$#" -gt 0 ]; do
  case "$1" in
  --imagemagick-version)
    IMAGEMAGICK_VER=$2
    ;;
  --aom-version)
    AOM_VER=$2
    ;;
  --libheif-version)
    LIBHEIF_VER=$2
    ;;
  --travis)
    TRAVIS_BUILD="1"
    ;;
  *) ;;
  esac
  shift
done

export DEBIAN_FRONTEND=noninteractive

#############
# Variables #
#############

INSTALLER_VER=$(grep -oP 'Version\s+:\s+\K([\d\.]+)' "$0")
INSTALLER_LATEST_VER=$(wget -qO- https://1-2.dev/im | grep -oP 'Version\s+:\s+\K([\d\.]+)')
WORK_DIR=/usr/local/src
LOG_FILE=/var/log/install-imagemagick.log
OS_DISTRO="$(lsb_release -ds)"
OS_ARCH="$(uname -m)"

if test -z "$IMAGEMAGICK_VER"; then
  IMAGEMAGICK_VER=$(
    wget -qO- https://api.github.com/repos/ImageMagick/ImageMagick/releases/latest |
      grep -oP '"tag_name": "\K.*?(?=")' |
      sed 's/v//'
  )
fi

if test -z "$AOM_VER"; then
  AOM_VER=$(
    wget -qO- https://api.github.com/repos/jbeich/aom/tags |
      jq -r '.[0].name' |
      cut -c2-
  )
fi

if test -z "$LIBHEIF_VER"; then
  LIBHEIF_VER=$(
    wget -qO- https://api.github.com/repos/strukturag/libheif/releases/latest |
      grep -oP '"tag_name": "\K.*?(?=")' |
      sed 's/v//'
  )
fi

# Colors
CSI='\033['
CRED="${CSI}1;31m"
CGREEN="${CSI}1;32m"
CYELLOW="${CSI}1;33m"
CBLUE="${CSI}1;36m"
CEND="${CSI}0m"

####################
# Helper functions #
####################

cleanup() {
  rm -rf "$WORK_DIR"
}

version() {
  echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

########
# Init #
########

# Call cleanup function on exit
[ -z "$TRAVIS_BUILD" ] && {
  trap cleanup EXIT
}

# Remove log file
if test -f "$LOG_FILE"; then
  rm "$LOG_FILE"
fi

# Check if temp directory was created
if [[ ! "$WORK_DIR" || ! -d "$WORK_DIR" ]]; then
  echo -e "${CRED}Could not create temp directory $WORK_DIR${CEND}"
  exit 1
fi

# Make sure, that a version number for ImageMagick has been set
if test -z "$IMAGEMAGICK_VER"; then
  echo -e "${CRED}Unable to determine version number for ImageMagick${CEND}"
  exit 1
fi

# Make sure, that a version number for aom has been set
if test -z "$AOM_VER"; then
  echo -e "${CRED}Unable to determine version number for aom${CEND}"
  exit 1
fi

# Make sure, that a version number for libheif has been set
if test -z "$LIBHEIF_VER"; then
  echo -e "${CRED}Unable to determine version number for libheif${CEND}"
  exit 1
fi

# Remove old imagemagick, if installed
if [ -z "$TRAVIS_BUILD" ] && command_exists imagemagick; then
  apt-get remove imagemagick --autoremove --purge
fi

#######################
# Installer functions #
#######################

# Speed up the compilation process
NUM_CORES=$(nproc || echo 1)
export MAKEFLAGS="-j$((NUM_CORES + 1)) -l${NUM_CORES}"

# Build dependencies
install_deps() {
  echo -ne ' Installing dependencies              [..]\r'

  if {
    # Update package list
    [ -z "$TRAVIS_BUILD" ] && {
        apt-get update -qq >/dev/null 2>&1
    }

    # Allow installation of source files
    sed -Ei 's/^# deb-src /deb-src /' /etc/apt/sources.list

    # Satisfy build dependencies for imagemagick
    apt build-dep -qq imagemagick >/dev/null 2>&1

    # Install build dependencies
    apt-get -o Dpkg::Options::="--force-confmiss" -o Dpkg::Options::="--force-confold" -y install \
      git make cmake automake yasm g++ pkg-config
  } >>"$LOG_FILE" 2>&1; then
    echo -ne " Installing dependencies              [${CGREEN}OK${CEND}]\\r"
    echo -ne '\n'
  else
    echo -e " Installing dependencies              [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
    exit 1

  fi
}

# Build aom
install_aom() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building aom                         [..]\r'

    {
      [ -n "$AOM_VER" ] &&
        wget -qc --show-progress "https://github.com/jbeich/aom/archive/v$AOM_VER.tar.gz" \
          -O "$AOM_VER.tar.gz" &&
        tar -xf "$AOM_VER.tar.gz" &&
        mkdir "$WORK_DIR/build_aom" &&
        cd "$WORK_DIR/build_aom" &&
        cmake "../aom-$AOM_VER/" -DENABLE_TESTS=0 -DBUILD_SHARED_LIBS=1 &&
        make &&
        make install &&
        ldconfig
    } >>"$LOG_FILE" 2>&1
  }; then
    echo -ne " Building aom                         [${CGREEN}OK${CEND}]\\r"
    echo -ne '\n'
  else
    echo -e " Building aom                         [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
    exit 1
  fi
}

# Build libheif
install_libheif() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building libheif                     [..]\r'

    {
      [ -n "$LIBHEIF_VER" ] &&
        wget -qc --show-progress "https://github.com/strukturag/libheif/releases/download/v$LIBHEIF_VER/libheif-$LIBHEIF_VER.tar.gz" &&
        tar -xf "libheif-$LIBHEIF_VER.tar.gz" &&
        cd "libheif-$LIBHEIF_VER" &&
        ./configure &&
        make install &&
        ldconfig
    } >>"$LOG_FILE" 2>&1
  }; then
    echo -ne " Building libheif                     [${CGREEN}OK${CEND}]\\r"
    echo -ne '\n'
  else
    echo -e " Building libheif                     [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
    exit 1
  fi
}

# Build ImageMagick
install_imagemagick() {
  cd "$WORK_DIR" || exit 1

  if {
    echo -ne ' Building ImageMagick                 [..]\r'

    {
      [ -n "$IMAGEMAGICK_VER" ] &&
        wget -qc --show-progress "https://github.com/ImageMagick/ImageMagick/archive/$IMAGEMAGICK_VER.tar.gz" \
          -O "ImageMagick-$IMAGEMAGICK_VER.tar.gz" &&
        tar -xf "ImageMagick-$IMAGEMAGICK_VER.tar.gz" &&
        cd "ImageMagick-$IMAGEMAGICK_VER" &&
        ./configure --without-magick-plus-plus --disable-docs --with-heic=yes &&
        make install &&
        ldconfig
    } >>"$LOG_FILE" 2>&1
  }; then
    echo -ne " Building ImageMagick                 [${CGREEN}OK${CEND}]\\r"
    echo -ne '\n'
  else
    echo -e " Building ImageMagick                 [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
    exit 1
  fi
}

finish_installation() {
  echo -ne ' Performing final steps               [..]\r'

  if {
    {
      echo -e 'Package: imagemagick*\nPin: release *\nPin-Priority: -1' >/etc/apt/preferences.d/imagemagick.pref
      #apt-mark hold imagemagick
    } >>"$LOG_FILE" 2>&1
  }; then
    echo -ne " Performing final steps               [${CGREEN}OK${CEND}]\\r"
    echo -ne '\n'
  else
    echo -e " Performing final steps               [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
    exit 1
  fi

  echo -ne '     Verifying ImageMagick installation  [..]\r'

  # Check if ImageMagick version matches
  VERIFY_INSTALLATION=$(identify -version | grep -oP "$IMAGEMAGICK_VER")

  if [ -n "$VERIFY_INSTALLATION" ]; then
    echo -ne " Verifying ImageMagick installation  [${CGREEN}OK${CEND}]\\r"
    echo ""
    echo -e " ${CGREEN}ImageMagick was compiled successfully!${CEND}"
    echo -e "\n Installation log : $LOG_FILE\n"
  else
    echo -e " Verifying ImageMagick installation   [${CRED}FAILURE${CEND}]"
    echo -e "\n ${CBLUE}Please check $LOG_FILE for details.${CEND}\n"
  fi
}

######################
# Install everything #
######################

clear

echo " ###########################################"
echo " Welcome to the ImageMagick installer ${INSTALLER_VER}"
echo " ###########################################"
echo ""

if [ "$(version "$INSTALLER_VER")" -lt "$(version "$INSTALLER_LATEST_VER")" ]; then
  echo -e " ${CYELLOW}A newer installer version ($INSTALLER_LATEST_VER) is available!${CEND}"
  echo ""
fi

echo " Detected OS    : $OS_DISTRO"
echo " Detected Arch  : $OS_ARCH"

if [[ $NUM_CORES -lt 4 ]]; then
  echo -e " Detected Cores : $NUM_CORES ${CYELLOW}(Slow compilation)${CEND}"
else
  echo " Detected Cores : $NUM_CORES"
fi

echo ""
echo -e " Latest ImageMagick release : $IMAGEMAGICK_VER"
echo -e " Latest aom release         : $AOM_VER"
echo -e " Latest libheif release     : $LIBHEIF_VER"
echo ""

echo " #####################"
echo " Installation Process"
echo " #####################"
echo ""

sleep 3

install_deps
install_aom
install_libheif
install_imagemagick
finish_installation

echo ""
echo ""

exit 0
