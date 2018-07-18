#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.
# Network configuration switch script for CLIP ADMIN
# Copyright (c) 2010 SGDSN/ANSSI
# Author: Mickaël Salaün <clipos@ssi.gouv.fr>
# Distributed under the terms of the GNU General Public Licence,
# version 2.

LOCKFILE="/tmp/netswitch.lock"
(
flock -xn 3 || exit

cleanexit() {
	rm -f -- "${LOCKFILE}" 2>/dev/null
	exit $1
}

if [[ $# -ne 1 ]]; then
	echo "usage: $0 <network-profile>" >&2
	cleanexit 1
fi

NETCONF="$(basename "$1")"
if [[ -z "${NETCONF}" ]] || [[ "${NETCONF}" == "." ]] || [[ "${NETCONF}" == ".." ]]; then
	cleanexit 1
fi
ERROR_FILE="/usr/local/var/net_error"
ERROR_MSG="."

# Exit only if the current profile is already selected at login, i.e. no user action
[[ -d /mounts/admin_priv ]] && [[ "$(basename -- "$(readlink -- "/etc/admin/conf.d/netconf")")" == "${NETCONF}" ]] && cleanexit

/usr/local/bin/Xdialog --title "Changement de profil réseau" \
	--wrap --left --no-buttons --no-cancel --ok-label "Fermer" \
	--icon "/usr/local/share/icons/network-disconnect.png" \
	--msgbox "Activation du profil réseau « ${NETCONF} » en cours, veuillez patienter..." 0 0 &

NETD_SOCK="/var/run/netd"
if [[ -d /mounts/admin_priv ]]; then
	RET="$(/mounts/admin_root/bin/net-change-profile -q "${NETCONF}")"
else
	RET="$(/usr/local/bin/ssh -o ServerAliveInterval=5 -p 22 _admin@127.54.0.1 -- /bin/net-change-profile -q "${NETCONF}")"
fi

[[ "$(/usr/bin/stat -c '%s' "${ERROR_FILE}" 2>/dev/null)" != "0" ]] && ERROR_MSG=" : $(cat "${ERROR_FILE}")."

case "${RET}" in
Y)
	MSG="Le profil « ${NETCONF} » a été activé."
	TITLE="Profil activé"
	;;
N)
	MSG="Le profil « ${NETCONF} » n'a pas pu être activé à cause d'une erreur réseau${ERROR_MSG}"
	TITLE="Erreur d'activation"
	;;
E)
	MSG="Le profil « ${NETCONF} » n'a pas pu être activé à cause d'une erreur interne du démon netd."
	TITLE="Erreur d'activation"
	;;
S)
	MSG="Le démon netd n'a pu être contacté."
	TITLE="Erreur d'activation"
	;;
P)
	MSG="Le lien symbolique n'a pas pu être créé."
	TITLE="Erreur d'activation"
	;;
*)
	MSG="Erreur inattendue : ${RET}"
	TITLE="Erreur d'activation"
	;;
esac

kill %% 2>/dev/null

case "${RET}" in
Y)
	[[ -d /mounts/admin_priv ]] ||
	/usr/local/bin/notify-send -u low -t 5000 -i "/usr/local/share/icons/applications-internet.png" -- \
		"${TITLE}" "${MSG}"
	;;
*)
	/usr/local/bin/Xdialog --wrap --left --no-buttons --no-cancel --ok-label "Fermer" \
		--icon "/usr/local/share/icons/vpn-off.png" \
		--title "${TITLE}" --msgbox "${MSG}" 0 0
	;;
esac

cleanexit

) 3>"${LOCKFILE}"
