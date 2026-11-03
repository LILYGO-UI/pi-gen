#!/bin/bash -e

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="${INSTALLER_DIR}/files/packages.list"
APT_REPOSITORY="${LILYGO_UI_APT_URL:-https://lilygo-ui.github.io/packages}"
APT_KEY_URL="${LILYGO_UI_APT_KEY_URL:-${APT_REPOSITORY%/}/apt-keyring.gpg}"
APT_ARCH="${LILYGO_UI_APT_ARCH:-${ARCH:-arm64}}"
KEYRING_PATH="${ROOTFS_DIR}/usr/share/keyrings/lilygo-ui-archive-keyring.gpg"
SOURCES_PATH="${ROOTFS_DIR}/etc/apt/sources.list.d/lilygo-ui.list"

if [[ ! "${APT_ARCH}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
	echo "Invalid LILYGO UI APT architecture: ${APT_ARCH}" >&2
	exit 1
fi

if [ ! -r "${PACKAGES_FILE}" ]; then
	echo "LILYGO UI package list is missing: ${PACKAGES_FILE}" >&2
	exit 1
fi

INSTALL_PACKAGES=()
while IFS= read -r PACKAGE || [ -n "${PACKAGE}" ]; do
	PACKAGE="${PACKAGE%%#*}"
	PACKAGE="$(printf '%s' "${PACKAGE}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
	# Ignore blank lines and comments, while rejecting malformed package names.
	if [ -z "${PACKAGE//[[:space:]]/}" ]; then
		continue
	fi
	if [[ "${PACKAGE}" =~ [[:space:]] ]] ||
		[[ ! "${PACKAGE}" =~ ^[a-z0-9][a-z0-9+.-]*$ ]]; then
		echo "Invalid package name in ${PACKAGES_FILE}: ${PACKAGE}" >&2
		exit 1
	fi
	INSTALL_PACKAGES+=("${PACKAGE}")
done < "${PACKAGES_FILE}"

if [ "${#INSTALL_PACKAGES[@]}" -eq 0 ]; then
	echo "LILYGO UI package list is empty: ${PACKAGES_FILE}" >&2
	exit 1
fi

# Fetch the repository key outside the target rootfs, then install it atomically
# so a failed download cannot leave a partially written trust anchor in the
# image. The key is the binary keyring published by the packages repository.
install -d "$(dirname "${KEYRING_PATH}")" "$(dirname "${SOURCES_PATH}")"
KEYRING_TMP="${KEYRING_PATH}.part"
rm -f "${KEYRING_TMP}"
trap 'rm -f "${KEYRING_TMP}"' EXIT
curl --fail --location --retry 3 --output "${KEYRING_TMP}" "${APT_KEY_URL}"
test -s "${KEYRING_TMP}"
chmod 0644 "${KEYRING_TMP}"
mv -f "${KEYRING_TMP}" "${KEYRING_PATH}"

cat > "${SOURCES_PATH}" <<EOF
deb [arch=${APT_ARCH} signed-by=/usr/share/keyrings/lilygo-ui-archive-keyring.gpg] ${APT_REPOSITORY%/} stable main
EOF
chmod 0644 "${SOURCES_PATH}"

# Keep the exact package set visible in the resulting image for diagnostics and
# future rebuilds. APT itself owns the downloaded archives and resolves all
# package dependencies from the signed repository metadata.
install -d "${ROOTFS_DIR}/opt/lilygo-ui"
install -m 0644 "${PACKAGES_FILE}" "${ROOTFS_DIR}/opt/lilygo-ui/packages.list"

on_chroot -s -- "${INSTALL_PACKAGES[@]}" <<'CHROOT'
set -e
# A failed or interrupted Pages deployment can leave an obsolete InRelease in
# the reusable rootfs. Remove only the LILYGO UI lists so the next refresh must
# retrieve the current signed metadata without discarding Debian indexes.
rm -f /var/lib/apt/lists/*lilygo-ui.github.io*
rm -f /var/lib/apt/lists/partial/*lilygo-ui.github.io*
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install --no-install-recommends --reinstall -y "$@"
systemctl enable meshtasticd.service
CHROOT

# The generic meshtasticd package ships a safe auto-detect configuration, but
# the CM0 LR2021 radio needs its board-specific SPI/GPIO profile selected.
# Keep this in config.d so package upgrades can replace the generic defaults
# without overwriting the image's hardware configuration.
MESHTASTIC_CONFIG_DIR="${ROOTFS_DIR}/etc/meshtasticd/config.d"
install -d "${MESHTASTIC_CONFIG_DIR}"
install -m 0644 "${INSTALLER_DIR}/files/lora-lr2021.yaml" \
	"${MESHTASTIC_CONFIG_DIR}/lora-lr2021.yaml"
