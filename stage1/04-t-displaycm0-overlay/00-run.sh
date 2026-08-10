#!/bin/bash -e

OVERLAY_REPO_DIR="${LILYGO_DTOVERLAYS_CONTAINER_DIR:-${LILYGO_DTOVERLAYS_DIR:-}}"
if [ -z "${OVERLAY_REPO_DIR}" ]; then
	OVERLAY_REPO_DIR="$(mktemp -d)"
	trap 'rm -rf "${OVERLAY_REPO_DIR}"' EXIT
	git clone --depth 1 --single-branch \
		--branch "${LILYGO_DTOVERLAYS_REF:-master}" \
		"${LILYGO_DTOVERLAYS_REPO:-https://github.com/Xinyuan-LilyGO/lilygo-linux-dtoverlays.git}" \
		"${OVERLAY_REPO_DIR}"
fi

MODULES_DIR="${OVERLAY_REPO_DIR}/modules"
BOARD_DIR="${MODULES_DIR}/T-DisplayCM0"

for REQUIRED_FILE in \
	module.mk \
	T-DisplayCM0/Makefile \
	T-DisplayCM0/t-display-cm0-overlay.dts \
	bq25890/Makefile \
	bq27xxx/Makefile \
	es8328/Makefile \
	goodix-berlin/Makefile \
	panel-rm69a10/Makefile \
	qmi8658c/Makefile; do
	if [ ! -f "${MODULES_DIR}/${REQUIRED_FILE}" ]; then
		echo "T-DisplayCM0 build input not found: ${MODULES_DIR}/${REQUIRED_FILE}" 1>&2
		exit 1
	fi
done

# Keep the complete modules tree so the board Makefile can reach shared drivers.
rm -rf "${ROOTFS_DIR}/tmp/lilygo-linux-modules"
install -d "${ROOTFS_DIR}/tmp/lilygo-linux-modules"
cp -a "${MODULES_DIR}/." "${ROOTFS_DIR}/tmp/lilygo-linux-modules/"

# Build the overlay and all external drivers against every installed v8 ABI.
on_chroot << 'CHROOT'
set -e

BUILD_DIR="/tmp/lilygo-linux-modules"
BOARD_DIR="${BUILD_DIR}/T-DisplayCM0"
DRIVER_DIRS="bq25890 bq27xxx es8328 goodix-berlin panel-rm69a10 qmi8658c"
MODULE_NAMES="bq25890_charger bq27xxx_battery bq27xxx_battery_i2c snd-soc-es8328-i2c goodix_berlin_core goodix_berlin_i2c panel_rm69a10 qmi8658c"
FOUND_KERNEL=0
OVERLAY_INSTALLED=0

trap 'rm -rf "${BUILD_DIR}"' EXIT

check_alias()
{
	MODULE_FILE="$1"
	EXPECTED_ALIAS="$2"
	if ! modinfo -F alias "${MODULE_FILE}" | grep -Fq "${EXPECTED_ALIAS}"; then
		echo "$(basename "${MODULE_FILE}") lacks the ${EXPECTED_ALIAS} OF alias" 1>&2
		exit 1
	fi
}

for KERNEL_DIR in /lib/modules/*-v8/build; do
	if [ ! -f "${KERNEL_DIR}/Makefile" ]; then
		continue
	fi

	FOUND_KERNEL=1
	KVER="${KERNEL_DIR#/lib/modules/}"
	KVER="${KVER%/build}"
	MODULE_DIR="/lib/modules/${KVER}/extra"
	DTS_INCLUDE="${KERNEL_DIR}/include"
	if [ ! -d "${DTS_INCLUDE}/dt-bindings" ]; then
		KERNEL_BASE="${KVER%-rpi-v8}"
		DTS_INCLUDE="/usr/src/linux-headers-${KERNEL_BASE}-common-rpi/include"
	fi
	if [ ! -d "${DTS_INCLUDE}/dt-bindings" ]; then
		echo "Device-tree bindings not found for ${KVER}" 1>&2
		exit 1
	fi

	if [ "${OVERLAY_INSTALLED}" -eq 0 ]; then
		# Also remove any overlay artifact copied from a local checkout.
		make -C "${BOARD_DIR}" \
			KERNELDIR="${KERNEL_DIR}" KVER="${KVER}" clean
		make -C "${BOARD_DIR}" \
			KERNELDIR="${KERNEL_DIR}" KVER="${KVER}" \
			DTS_INCLUDE="${DTS_INCLUDE}" install_dts
		if [ ! -s /boot/firmware/overlays/t-display-cm0.dtbo ]; then
			echo "T-DisplayCM0 overlay was not installed" 1>&2
			exit 1
		fi
		OVERLAY_INSTALLED=1
	else
		# Kbuild outputs and Module.symvers files are specific to a kernel ABI.
		for DRIVER_DIR in ${DRIVER_DIRS}; do
			make -C "${BUILD_DIR}/${DRIVER_DIR}" \
				KERNELDIR="${KERNEL_DIR}" KVER="${KVER}" clean
		done
	fi

	make -C "${BOARD_DIR}" \
		KERNELDIR="${KERNEL_DIR}" \
		KVER="${KVER}" \
		MODULE_DIR="${MODULE_DIR}" \
		install_modules

	# TCA8418 is provided by Raspberry Pi OS. Remove artifacts left by older
	# image-build attempts before regenerating the module index.
	rm -f "${MODULE_DIR}/tca8418_keypad.ko"
	depmod -a "${KVER}"

	for MODULE_NAME in ${MODULE_NAMES}; do
		MODULE_FILE="${MODULE_DIR}/${MODULE_NAME}.ko"
		if [ ! -s "${MODULE_FILE}" ]; then
			echo "${MODULE_NAME} was not installed for ${KVER}" 1>&2
			exit 1
		fi

		case "$(modinfo -F vermagic "${MODULE_FILE}")" in
			"${KVER} "*) ;;
			*)
				echo "${MODULE_NAME} vermagic does not match ${KVER}" 1>&2
				exit 1
				;;
		esac

		if ! INDEXED_FILE="$(modinfo -k "${KVER}" -F filename "${MODULE_NAME}")"; then
			echo "${MODULE_NAME} is missing from the ${KVER} module index" 1>&2
			exit 1
		fi
		if [ "${INDEXED_FILE}" != "${MODULE_FILE}" ]; then
			echo "${MODULE_NAME} resolves to ${INDEXED_FILE}, not ${MODULE_FILE}" 1>&2
			exit 1
		fi
	done

	check_alias "${MODULE_DIR}/bq25890_charger.ko" 'Cti,bq25890'
	check_alias "${MODULE_DIR}/bq27xxx_battery_i2c.ko" 'Cti,bq27220'
	check_alias "${MODULE_DIR}/snd-soc-es8328-i2c.ko" 'Ceverest,es8388'
	check_alias "${MODULE_DIR}/goodix_berlin_i2c.ko" 'Cgoodix,gt9895'
	check_alias "${MODULE_DIR}/panel_rm69a10.ko" 'Craydium,rm69a10'

	if ! SYSTEM_TCA_FILE="$(modinfo -k "${KVER}" -F filename tca8418_keypad)"; then
		echo "System TCA8418 module is missing for ${KVER}" 1>&2
		exit 1
	fi
	case "${SYSTEM_TCA_FILE}" in
		"/lib/modules/${KVER}/kernel/"*) ;;
		*)
			echo "TCA8418 resolves to a non-system module: ${SYSTEM_TCA_FILE}" 1>&2
			exit 1
			;;
	esac
	check_alias "${SYSTEM_TCA_FILE}" 'Cti,tca8418'
done

if [ "${FOUND_KERNEL}" -eq 0 ]; then
	echo "Raspberry Pi v8 kernel headers not found" 1>&2
	exit 1
fi
CHROOT

# Install the boot configuration fragment maintained by pi-gen.
install -m 644 files/t-display-cm0.txt \
	"${ROOTFS_DIR}/boot/firmware/t-display-cm0.txt"
