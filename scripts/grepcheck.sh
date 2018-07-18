#! /bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2011-2018 ANSSI. All Rights Reserved.

set -x

# grepcheck.sh [logtype] [ihm]
Version=0.5.2
# Florent Chabaud clipos@ssi.gouv.fr
# Script de surveillance active des logs fw de CLIP
# /home/user/grepcheck/netdir-logtype contient le fichier des règles à utiliser
# netdir vaut /etc/admin/conf.d/netconf qui est un lien symbolique
# vers la configuration courante
# log/logtype.log est le fichier surveillé

LC_ALL=C # pour l'homogénéité des logs...
LOGDIR="/log"
ADMINDIR="/etc/admin"
# remplacer /dev/null par /dev/stderr
DEBUG="/dev/null"
debug_param=
[[ "$1" == "debug" ]] && shift && DEBUG="/dev/stderr" && debug_param="debug "
INFO=off
info_param=
[[ "$1" == "info" ]] && shift && INFO="on" && info_param="info "
START_IHM=
[[ "$1" == "ihm" ]] && shift && START_IHM="yes"
INCONNUS=off
[[ "$1" == "inconnus" ]] && shift && INCONNUS="on"

TIMEOUT=10 # le délai en secondes au bout duquel, sans évènement, on vérifie d'autres logs
TIMEOUTXDIALOG=180 # délai en secondes de l'interface Xdialog en cas d'événement détecté
NOTIFICATION=5000 # délai en milisecondes pour les notifications de niveau low (*2 pour normal *3 pour critique)

####################################################
############# Fonctions générales ##################
####################################################

ssh_audit() {
  local nb=10
  local ret

  while [[ $nb -ge 1 ]]; do
    timeout ${TIMEOUT} ssh -X -Y -p 23 _audit@127.53.0.1 "$@" </dev/null >"${TMPFILE}.ssh" 2>"${TMPFILE}.ssh-error"
    ret=$?
    if [[ $ret -eq 0 || $ret -eq 124 ]]; then # 124 = timeout
      nb=0
    else
      echo "Erreur ssh $@" >"${DEBUG}"
      sleep 1
    fi
    nb=$(( $nb - 1 ))
  done
  [[ $nb -eq 0 ]] && notify-send -u critical -t "$((${NOTIFICATION}*3))" -i "/usr/local/share/icons/dialog-warning.png" \
    -- "Analyse réseau" \
       "Erreur d'accès ssh audit : $(cat "${TMPFILE}.ssh-error")"
  cat "${TMPFILE}.ssh"
  rm "${TMPFILE}.ssh" "${TMPFILE}.ssh-error"
}
SSHCMD="ssh_audit"

HOMEDIR="/home/user"
REGEXPDIR="${HOMEDIR}/grepcheck"
TMPFILE="$(mktemp /tmp/grepcheck.XXXXXX)"

[[ -n "${TMPFILE}" ]] || exit 1

MACHINE="$(uname -n)"

[[ -d "${REGEXPDIR}" ]] || mkdir "${REGEXPDIR}" 
[[ -d "${REGEXPDIR}" ]] || exit 1

LOGSMANAGED="fw grsec pax clsm"
LOGNAMES="fw"
[[ -n "$1" ]] && LOGNAMES="$1"
for LOGNAME in ${LOGNAMES}; do
  LOGFILES="${LOGDIR}/${LOGNAME}.log ${LOGFILES}"
done
${SSHCMD} cat "${LOGFILES}" </dev/null >& /dev/null # "${DEBUG}"
[[ $? -ne 0 ]] &&   Xdialog --title "Analyse réseau : impossible" --infobox "Impossible d'accéder aux fichiers : ${LOGFILES}" 5 80 15000 && exit 2


################ Extrait du fichier de configuration les règles regexp ##########
extract_regexp() {
  sed -e "s/.*# \(.*\)/\1/g" < "$1.txt" > "$1"
}

################ Récupération de l'horodatage d'établissement de la session réseau
get_ts() {
  local log="$1"
    
  MONTH="$(echo "${log}" | cut -f1 -d" ")"
  DAY="$(echo "${log}" | cut -f2 -d" ")"	
  if [[ -z "${DAY}" ]]; then
    DAY="$(echo "${log}" | cut -f3 -d" ")"	
    HOUR="$(echo "${log}" | cut -f4 -d" ")"
  else    
    HOUR="$(echo "${log}" | cut -f3 -d" ")"
  fi
      
  echo "new ts: ${MONTH} ${DAY} ${HOUR}" >"${DEBUG}"
}

gethour() {
  LOGLINE="$(${SSHCMD} cat ${LOGDIR}/daemon.log | grep 'Starting network' | tail -1)"
  if [[ -z "${LOGLINE}" ]]; then
    echo "Pas de début de connexion dans daemon.log" > "${DEBUG}"
    LOGLINE="$(${SSHCMD} cat ${LOGDIR}/daemon.log | grep 'rc-scripts: Activation' | tail -1)"
  fi
  if [[ -z "${LOGLINE}" ]]; then
    echo "Pas d'activation dans daemon.log" > "${DEBUG}"
    LOGLINE="$(${SSHCMD} head -1 ${LOGDIR}/daemon.log )"
  fi
  if [[ -n "${LOGLINE}" ]]; then
    get_ts "${LOGLINE}"
  else
    echo "Pas de fichier daemon.log !" > "${DEBUG}"
  fi
  echo "<${MONTH}> <${DAY}> <${HOUR}>" > "${DEBUG}"
}


################### Nombre de lignes après le timestamp dans le fichier $1 #######
# Trick: 
# Si "$2" n'est pas vide, et que le nombre de lignes est nul, retournera "0 -f"
get_nbline() {
  local log="$1"
  local def="0 -f"
  local nbl=0
  [[ -z "$2" ]] && def="0"
  echo "Dernier événement traité : ${MONTH} ${DAY} ${HOUR} sur ${log}" >"${DEBUG}"
  ${SSHCMD} cat "${log}" > "${TMPFILE}.log"

  nbl="$(awk 'BEGIN{nb = 0; \
    def="'"${def}"'";\
    year=strftime("%Y",systime());\
    split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC",months," ");\
    for(i=1;i<=12;i++) mdigit[months[i]]=i;\
    month=mdigit[toupper("'${MONTH}'")];\
    m=strftime("%m",systime());\
    if((m==1)&&(month==12)) year--;\
    day='${DAY}'; \
    hms="'${HOUR}'"; \
    gsub(":"," ",hms); \
    ts=mktime(year " " month " " day " " hms);\
    sixmonths=mktime("2012 7 1 00 00 00")-mktime("2012 1 1 00 00 00");\
  } {\
    delta=mktime(year " " mdigit[toupper($1)] " " $2 " " substr($3,1,2) " " substr($3,4,2) " " substr($3,7,2)) - ts; \
    if((delta >= 0) && (delta < sixmonths) && (nb == 0)) \
      {nb =NR;} \
  } END{print((nb == 0)? def : NR-nb+1);}' \
"${TMPFILE}.log"
)"
  echo "Nombre d'événements à considérer : (${nbl}) sur ${log} (${def})">"${DEBUG}"
  echo "${nbl}"
}

############### Sortie nettoyante #####################
nice_exit() {
  FILES="$(ls -1 "${TMPFILE}"* 2> /dev/null)"
  [[ -n "${FILES}" ]] && rm "${TMPFILE}"*

  exit 0
}

trap "IHM=; nice_exit noop" INT TERM EXIT

######### Récupération des fichiers de configuration ####################

getnetconf() {
  NETDIR="$(${SSHCMD} ls -l "${ADMINDIR}/conf.d/netconf" | awk '{print $NF}')"
  NETNAME="$(basename ${NETDIR})"
  MONTH="$(date -R | cut -f3 -d" ")"
  DAY="$(date '+%e')"
  DAY=$(( 0 + ${DAY} ))
  HOUR="$(date '+%T')"
  [[ "${INFO}" == "on" ]] && notify-send -u low -t "$((${NOTIFICATION}*1))" -i "/usr/local/share/icons/network-connect.png" \
    -- "Analyse réseau" \
       "Analyse en cours de la connexion réseau détectée : ${NETNAME}"
  for LOGNAME in ${LOGSMANAGED}; do
    REGEXPFILE="${REGEXPDIR}/${NETNAME}-${LOGNAME}"
    [[ -f "${REGEXPFILE}.txt" ]] || raz "${LOGNAME}" "${REGEXPFILE}"
    extract_regexp "${REGEXPFILE}"
  done
}

ihm_gen() {
  local XDIALOG=
  local logname
  local lognames
  local IHM=

  INFINITE=no
  gethour
  i=0
  XDIALOG[$(( i++ ))]="Xdialog"
  XDIALOG[$(( i++ ))]="--stdout"
  XDIALOG[$(( i++ ))]="--item-help"
  XDIALOG[$(( i++ ))]="--cancel-label"
  XDIALOG[$(( i++ ))]="Annuler"
  XDIALOG[$(( i++ ))]="--ok-label"
  XDIALOG[$(( i++ ))]="Appliquer"
  XDIALOG[$(( i++ ))]="--title"
  XDIALOG[$(( i++ ))]="Analyse de sécurité (${NETNAME})"
  XDIALOG[$(( i++ ))]="--checklist"
  XDIALOG[$(( i++ ))]="Configuration de la surveillance de sécurité (${NETNAME})
Version ${Version} de l'interface
Analyse des journaux depuis l'horodatage : ${MONTH} ${DAY} ${HOUR}"
  XDIALOG[$(( i++ ))]="40"
  XDIALOG[$(( i++ ))]="100"
  XDIALOG[$(( i++ ))]="1"

  TEST="$(ps aux 2> "${DEBUG}" | grep "$0" | grep bash | grep info | wc -l)"
  [[ $TEST -gt 0 ]] && INFO="on"
  XDIALOG[$(( i++ ))]="info"
  XDIALOG[$(( i++ ))]="Active les notifications d'information"
  XDIALOG[$(( i++ ))]="${INFO}"
  XDIALOG[$(( i++ ))]="Seules les fenêtres de notification de niveau information sont configurables"

  XDIALOG[$(( i++ ))]="stop"
  XDIALOG[$(( i++ ))]="forcer l'arrêt immédiat"
  XDIALOG[$(( i++ ))]="off"
  TEST="$(ps aux 2> "${DEBUG}" | grep "$0" | grep bash | wc -l)"
  TEST=$(( $TEST / 4 ))
  XDIALOG[$(( i++ ))]="Force à l'arrêt les instances en cours au nombre de ${TEST}."

  XDIALOG[$(( i++ ))]="inconnus"
  XDIALOG[$(( i++ ))]="Catégorise les événements inconnus"
  XDIALOG[$(( i++ ))]="${INCONNUS}"
  XDIALOG[$(( i++ ))]="Catégorise les événements enregistrés mais inconnus (pour tous les journaux)"

  for logname in $LOGSMANAGED; do
      TEST="$(ps aux 2> "${DEBUG}" | grep "$0" | grep bash | grep -v ihm | grep "${logname}" | wc -l)"
      DYN="off"
      [[ $TEST -gt 0 ]] && DYN="on"

      XDIALOG[$(( i++ ))]="surv-${logname}"
      XDIALOG[$(( i++ ))]="active/inactive"
      XDIALOG[$(( i++ ))]="${DYN}"
      XDIALOG[$(( i++ ))]="Active ou arrête la surveillance dynamique du journal ${logname}"

      DYN="off"
      echo "${LOGNAMES}" | grep -q "${logname}"
      [[ $? -eq 0 ]] && DYN="on"
      XDIALOG[$(( i++ ))]="ihm-${logname}"
      XDIALOG[$(( i++ ))]="Analyse du journal ${logname}"
      XDIALOG[$(( i++ ))]="${DYN}"
      XDIALOG[$(( i++ ))]="Lance l'ihm de gestion de la surveillance du journal ${logname}"
  done
  IHM="$("${XDIALOG[@]}")"
  [[ $? -ne 0 ]] && exit 0
  echo "IHM: ${IHM}" >"${DEBUG}"

  INFO="off"
  info_param=
  echo "${IHM}" | grep -q "info"
  [[ $? -eq 0 ]] && INFO="on" && info_param="info "

  INCONNUS="off"
  echo "${IHM}" | grep -q "inconnus"
  [[ $? -eq 0 ]] && INCONNUS="on"

  TEST="$(ps aux 2> "${DEBUG}" | grep "$0" | grep bash |awk '($2 != '"$$"'){printf("%s ", $2);}END{print ""}')"
  echo "${IHM}" | grep -q stop
  [[ $? -eq 0 ]] && [[ -n "${TEST}" ]] && Xdialog --title "Analyse de sécurité : arrêt forcé" --ok-label "Oui" --cancel-label "Annuler" --yesno "Arrêt forcé des processus : ${TEST} ?" 5 80 15000 && kill ${TEST}

  TEST="$(ps aux 2> "${DEBUG}" | grep "$0" | grep bash | grep -v ihm |awk '{print $2}')"
  [[ -n "${TEST}" ]] && kill ${TEST}

  lognames=
  for logname in $LOGSMANAGED; do
    echo "IHM: ${IHM}" >"${DEBUG}"
    echo "${IHM}" | grep -q "surv-${logname}" 
    [[ $? -eq 0 ]] && lognames="${logname} ${lognames}"
    echo "${IHM}" | grep -q "ihm-${logname}" 
    [[ $? -eq 0 ]] && ihm_ssi "${logname}"
  done
  if [[ -n "${lognames}" ]]; then
    echo "Lancement surveillance ${lognames}" > "${DEBUG}"
    if [[ "${INCONNUS}" == "on" ]]; then
      "$0" ${debug_param}${info_param}"inconnus" "${lognames}" &
      INCONNUS="off" # inutile de les traiter deux fois
    else
      "$0" ${debug_param}${info_param}"${lognames}" &
    fi
  fi
  [[ "${INCONNUS}" == "on" ]] && return # on garde ainsi le début de l'horodatage en timestamp
  nice_exit "${LOGNAMES}"
}

gauge () {
  local i="$1"
  local tot="$2"
  
  tot=$(( $tot <= 0 ? 1 : $tot))
  local ret=$(( $i * 100 / $tot ))
  ret=$(( $ret < 1 ? 1 : $ret ))
  echo $(( $ret > 100 ? 100 : $ret ))
}

ihm_ssi() {
  local logname="$1"
  local regexpfile="${REGEXPDIR}/${NETNAME}-${logname}"
  local logfile="${LOGDIR}/${logname}.log"
  local XDIALOG=
  local IHM=

  local fifo=>(Xdialog --no-close --title "Analyse du journal ${logname}" --gauge "Analyse en cours du journal ${logname}" 5 100 0)
  exec 100> "$fifo"
  
  gethour


  i=0
  XDIALOG[$(( i++ ))]="Xdialog"
  XDIALOG[$(( i++ ))]="--cancel-label"
  XDIALOG[$(( i++ ))]="Annuler"
  XDIALOG[$(( i++ ))]="--ok-label"
  XDIALOG[$(( i++ ))]="Appliquer"
  XDIALOG[$(( i++ ))]="--stdout"
  XDIALOG[$(( i++ ))]="--item-help"
  XDIALOG[$(( i++ ))]="--title"
  XDIALOG[$(( i++ ))]="Analyse du journal ${logname} (${NETNAME})"
  XDIALOG[$(( i++ ))]="--checklist"
  XDIALOG[$(( i++ ))]="Configuration de la surveillance du journal ${logname} (${NETNAME})
Version ${Version} de l'interface
Analyse du journal depuis l'horodatage : ${MONTH} ${DAY} ${HOUR}"
  XDIALOG[$(( i++ ))]="40"
  XDIALOG[$(( i++ ))]="100"
  XDIALOG[$(( i++ ))]="1"
  
  XDIALOG[$(( i++ ))]="raz"
  XDIALOG[$(( i++ ))]="toutes les règles"
  XDIALOG[$(( i++ ))]="off"
  extract_regexp "${regexpfile}"
  NBLNS="$(cat "${regexpfile}" | wc -l)"
  NBLINES=$(( ${NBLNS} - ${NBREGS} ))
  # Nombre d'étapes de constitution de l'IHM 
  # NBLINES  + 1 (inconnus) + 1 (événements)
  # on omet une étape pour voir le 100 %
  
  local etape=1
  local complete=$(( ${NBLINES} + 1 ))
  gauge 0 $complete >&100

  XDIALOG[$(( i++ ))]="Supprime les ${NBLINES} règles et remet les règles par défaut"

  NBLINE="$(get_nbline "${logfile}")"
  PLURIEL=
  [[ ${NBLINE} -gt 1 ]] && PLURIEL="s"
  XDIALOG[$(( i++ ))]="recalcul"
  XDIALOG[$(( i++ ))]="rafraîchir les compteurs (${NBLINE} événement${PLURIEL})"
  XDIALOG[$(( i++ ))]="off"
  XDIALOG[$(( i++ ))]="Recalcule les compteurs des événements"

  gauge $(( etape++ )) $complete >&100 # événements

  [[ "${INFO}" == "on" ]] && notify-send -u low -t ${NOTIFICATION} -i "/usr/local/share/icons/dialog-information.png" \
    -- "Analyse de sécurité" \
    "Nombre d'événements à analyser du journal ${logname} : ${NBLINE} (pour ${NBLINES} règles)"

  #${SSHCMD} tail -${NBLINE} "${logfile}" > "${TMPFILE}.log"
  #gauge $(( etape++ )) $complete >&100 # lecture

  NBOCC="$(tail -${NBLINE} "${TMPFILE}.log" | grep --count -v -f "${regexpfile}")"
  if [[ ${NBOCC} -ge 0 ]]; then
    FIRST="$(tail -${NBLINE} "${TMPFILE}.log" | grep -v -f "${regexpfile}" -m 1 | awk '{print $1 " " $2 " " $3}' )"
    LAST="$(tail -${NBLINE} "${TMPFILE}.log" | grep -v -f "${regexpfile}" | tail -1 | awk '{print $1 " " $2 " " $3}' )"
    PLURIEL=
    [[ ${NBOCC} -gt 1 ]] && PLURIEL="s"
    XDIALOG[$(( i++ ))]="inconnus"
    XDIALOG[$(( i++ ))]="${NBOCC} occurence${PLURIEL} [$FIRST - $LAST]"
    XDIALOG[$(( i++ ))]="${INCONNUS}"
    if [[ -z "${PLURIEL}" ]]; then
      XDIALOG[$(( i++ ))]="Catégorise l'événement enregistré mais inconnu"
    else
      XDIALOG[$(( i++ ))]="Catégorise les événements enregistrés mais inconnus (pour tous les journaux)"
    fi
  fi

  gauge $(( etape++ )) $complete >&100 # inconnus

  KEYWORD="Evt-" # ACHTUNG : pas d'espace ni de caractère UTF-8

  while [[ "${NBLINES}" -gt 0 ]]; do
    tail -"${NBLINES}" "${regexpfile}.txt" | head -1 > "${TMPFILE}.txt"
    extract_regexp "${TMPFILE}"
    TITREGEXP="$(cat "${TMPFILE}.txt" | cut -f1 -d'#')"
    REGEXP="$(sed -f "${TMPFILE}-proto.sed" < "${TMPFILE}")"
    XDIALOG[$(( i++ ))]="${KEYWORD}${NBLINES}"
    NBOCC="$(tail -${NBLINE} "${TMPFILE}.log" | grep --count -f "${TMPFILE}" )"
    PLURIEL=
    FIRST=
    LAST=
    if [[ ${NBOCC} -gt 0 ]]; then
      [[ ${NBOCC} -gt 1 ]] && PLURIEL="s"
      FIRST="$(tail -${NBLINE} "${TMPFILE}.log" | grep -f "${TMPFILE}" -m 1 | awk '{print $1 " " $2 " " $3}' )"
      LAST="$(tail -${NBLINE} "${TMPFILE}.log" | grep -f "${TMPFILE}" | tail -1 | awk '{print $1 " " $2 " " $3}' )"
    fi
    XDIALOG[$(( i++ ))]="${NBOCC} occurence${PLURIEL} [$FIRST - $LAST]
  ${TITREGEXP}"
    XDIALOG[$(( i++ ))]="on"
    XDIALOG[$(( i++ ))]="Décochez la case pour supprimer la règle suivante :
${REGEXP}"
    rm "${TMPFILE}" "${TMPFILE}.txt"
    NBLINES=$(( ${NBLINES} - 1 ))
    gauge $(( etape++ )) $complete >&100
  done

  rm "${TMPFILE}.log"
  exec 100>&-

#  for arg in "${XDIALOG[@]}"; do
#    echo "${arg}"
#  done
  IHM="$("${XDIALOG[@]}")"
  [[ $? -ne 0 ]] && return

  INCONNUS="off"
  echo "${IHM}" | grep -q "inconnus"
  [[ $? -eq 0 ]] && INCONNUS="on"

  echo "${IHM}" | grep -q raz
  if [[ $? -eq 0 ]]; then
    raz ${logname} ${regexpfile}	
  else
    awk 'BEGIN{s="'$IHM'/";nreg='${NBREGS}'; nb='${NBLNS}'}\
(NR>nb)||(NR<=nreg)||(match(s,"'${KEYWORD}'" nb-NR+1 "/")){print $0}' "${regexpfile}.txt" > "${TMPFILE}"
    mv "${TMPFILE}" "${regexpfile}.txt" 
    extract_regexp "${regexpfile}"
  fi

  echo "${IHM}" | grep -q "recalcul"
  [[ $? -eq 0 ]] && ihm_ssi "${logname}"
}

################ Réinitialisation d'un fichier de règle #####################

raz() {
  cat "${TMPFILE}.reg" > "${2}.txt" 
  case "${1}" in
    fw)
      raz_fw "${2}"
    ;;
    grsec)
      raz_grsec "${2}"
    ;;
    *)
    ;;
  esac
}
################ Définition d'un nom synthétique de règle #####################

synthese() {
  local event="$2"
  
  case "${1}" in
    grsec)
      synthese_grsec "${event}"
    ;;
    pax)
      synthese_pax "${event}"
    ;;
    clsm)
      synthese_clsm "${event}"
    ;;
    *)
      echo "Règle personnelle"
    ;;
  esac
}
####################################################
################ Fonctions FW ######################
####################################################

raz_fw() {
# Règles correspondant généralement à des erreurs lors de l'établissement
# des connexions réseau
  cat >> "${1}.txt" <<EOF
Connexion réseau non établie # .* FW: invalid state IN=.* \(ACK \(PSH \)*FIN\|RST\) .*
Tunnel chiffrant non établi # .* FW: expected ipsec IN=.* 
EOF
# Règles correspondant à des protocoles courants non pris en compte par
# le firewall CLIP
  cat >> "${1}.txt" <<EOF
Hôte injoignable (ICMP type 3) # .* FW: \(loopback (REJECT)\|FORWARD\|OUTPUT\) IN=.* PROTO=ICMP TYPE=3 CODE=\(1\|3\) \[.* \].*
Ping (ICMP type 8 - echo request) # .* FW: INPUT IN=eth0 .* PROTO=ICMP TYPE=8 CODE=0 .*
Paquets multicast # .* FW: INPUT IN=.* DST=224.0.0.1 .* PROTO=2
Broadcast DHCP # .* FW: INPUT IN=eth0 OUT= MAC=.* SRC=.* DST=255.255.255.255 .* PROTO=UDP SPT=68 DPT=67 .*
Réponse DHCP # .* FW: \(INPUT\|FORWARD\) IN=eth0 .* PROTO=UDP SPT=67 DPT=68 .*
EOF
}

# Règles pour rendre lisible la question posée lors d'une nouvelle règle
cat > "${TMPFILE}-fw.sed" << EOF
s/FW: /FW:\\n/g
EOF

# Règles pour généraliser les règles
cat > "${TMPFILE}-fw.regsed" << EOF
s/\(ID\|LEN\|SEQ\|WINDOW\)=[0-9]*/\1=[0-9]*/g
s/\(S\|D\)PT=[0-9][0-9][0-9][0-9][0-9]/\1PT=[0-9]*/g
EOF

####################################################
################ Fonctions PAX #####################
####################################################

# Règles techniques pour éliminer les lignes non pertinentes
cat > "${TMPFILE}-pax.reg" << EOF
# .* PAX: bytes at .*
# .* PAX: execution attempt in: \((null)\|<anonymous mapping>\),.*
EOF

# Règles pour rendre lisible la question posée lors d'une nouvelle règle
cat > "${TMPFILE}-pax.sed" << EOF
s/PAX: /pax:\\n/g
s/ \(PC\|SP\): [0-9a-f,]*//g
s/ \(u\|g\)id\/e\(u\|g\)id: [0-9]*\/[0-9]*, //g
s/ [^[:blank:]]*(\([^[:blank:]]*\)):[0-9]*,/ \1 /g
EOF

# Règles pour généraliser les règles
cat > "${TMPFILE}-pax.regsed" << EOF
s/(\([^[:blank:]]*\)):[0-9]*/(\1):[0-9]*/g
s/\(PC\|SP\): [0-9a-f]*/\1: [0-9a-f]*/g
EOF

synthese_pax() {
  local event="$1"
  local type="Règle particulière"
  
  echo "${event}" | grep -q "\(terminating task\|execution attempt in\):" 
  if [[ $? -eq 0 ]]; then
    type="$(echo "${event}" | grep "\(terminating task\|execution attempt in\):" | sed -e "s/.*\(terminating task\|execution attempt in\): \([^[:blank:]]*\) .*/\2/g")"
  fi
  echo "${type}"
}
####################################################
################ Fonctions clsm #####################
####################################################

# Règles pour rendre lisible la question posée lors d'une nouvelle règle
cat > "${TMPFILE}-clsm.sed" << EOF
s/CLSM: /clsm:\\n/g
s/ task \([^[:blank:]]*\) ([0-9]* - / task \1 (/g
EOF

# Règles pour généraliser les règles
cat > "${TMPFILE}-clsm.regsed" << EOF
s/ task \([^[:blank:]]*\) ([0-9]* - / task \1 ([0-9]* - /g
EOF

synthese_clsm() {
  local event="$1"
  local type="Règle particulière"
  
  echo "${event}" | grep -q "\(blocked\|denied\)" 
  if [[ $? -eq 0 ]]; then
    type="$(echo "${event}" | grep "\(blocked\|denied\)" | sed -e "s/.* task \([^[:blank:]]*\) .* \(blocked\|denied\) \([^[:blank:]]*\) .*/\1 \2 \3/g")"
  fi
  echo "${type}"
}
####################################################
################ Fonctions grsec ###################
####################################################
raz_grsec() {
# Règles correspondant généralement à des erreurs lors de l'établissement
# des connexions réseau
  cat >> "${1}.txt" <<EOF
Réglage horaire # .* grsec: time set by .*
Journalisation désactivée # .* grsec: .* logging disabled for .*
EOF
}

# Règles pour rendre lisible la question posée lors d'une nouvelle règle
cat > "${TMPFILE}-grsec.sed" << EOF
s/grsec: /grsec:\\n/g
s/ \(u\|g\)id\/e\(u\|g\)id:[0-9]*\/[0-9]*//g
s/ [^[:blank:]]*\[\([^[:blank:]]*\):[0-9]*\]/ \1/g
s/ [^[:blank:]]*(\([^[:blank:]]*\):[0-9]*)/ \1/g
EOF

# Règles pour généraliser les règles
cat > "${TMPFILE}-grsec.regsed" << EOF
s/\[\([^[:blank:]]*\):[0-9]*\]/\\\\[\1:[0-9]*\\\\]/g
s/(\([^[:blank:]]*\):[0-9]*)/(\1:[0-9]*)/g
s/at [0-9a-f]\{8\}/at [0-9a-f]\\\\{8\\\\}/g
EOF

synthese_grsec() {
  local event="$1"
  local type="Règle particulière"
  
  echo "${event}" | grep -q "\(Segmentation fault\|Abort\)" 
  if [[ $? -eq 0 ]]; then
    type="$(echo "${event}" | grep "\(Segmentation fault\|Abort\)" | sed -e "s/.*\(Segmentation fault\|Abort\) occurred at .* in \([^[:blank:]]*\), .*/\1 \2/g")"
  fi
  echo "${event}" | grep -q "denied" 
  if [[ $? -eq 0 ]]; then
    type="Erreur $(echo "${event}" | grep "denied" | sed -e "s/denied \(.*\).* of .* by \([^[:blank:]]*\), .*/\1 \2/g")"
  fi
  echo "${event}" | grep -q "attached to" 
  if [[ $? -eq 0 ]]; then
    type="Usage de $(echo "${event}" | grep "attached to" | sed -e "s/process \(.*\) attached to via \(.*\) by \([^[:blank:]]*\), .*/\2 \3 pour \1/g")"
  fi
  echo "${event}" | grep -q "signal" 
  if [[ $? -eq 0 ]]; then
    type="Erreur $(echo "${event}" | grep "signal" | sed -e "s/signal \([0-9]*\) sent to \([^[:blank:]]*\), .*/Signal-\1 \2/g")"
  fi
  echo "${type}"
}

####################################################
# Fichier de lisibilité des règles
sed -e "s|/|_|g" /etc/services | grep _tcp | grep -v "^#" | \
      awk '{print "s/\\(S\\|D\\)PT=\\(" substr($2,0,length($2)-length("_tcp")) "\\) /\\1PT=\\2 (" $1 ") /g"}' \
      > "${TMPFILE}.sed"
cp "${TMPFILE}.sed" "${TMPFILE}-proto.sed"
cat >> "${TMPFILE}.sed" << EOF
s/${MACHINE} //g
s/kernel: //g
s/ID=[0-9]* //g
s/ \(MAC\|SRC\|LEN\|PROTO\)=/\\n\1=/g
EOF

# Fichier de généralisation des règles
# (rend les règles indépendantes d'un pid, par exemple)
cat > "${TMPFILE}.regsed" << EOF
s/.*${MACHINE} kernel:/.*/g
EOF

# Règles techniques prévues pour le multi-log
cat > "${TMPFILE}.reg" <<EOF
# ^$
EOF

for LOGNAME in ${LOGSMANAGED}; do
  for suf in "sed" "reg" "regsed"; do
    [[ -f "${TMPFILE}-${LOGNAME}.${suf}" ]] && cat "${TMPFILE}-${LOGNAME}.${suf}" >> "${TMPFILE}.${suf}"
  done
done
NBREGS="$(cat "${TMPFILE}.reg" | wc -l)"

getnetconf
INFINITE=yes

[[ -n "${START_IHM}" ]] && ihm_gen 
[[ "${INCONNUS}" == "on" ]] && gethour


#echo "Début de la boucle infinie"
[[ "${INFINITE}" == "yes" ]] &&   notify-send -u normal -t "$((${NOTIFICATION}*2))" -i "/usr/local/share/icons/dialog-ok.png" \
    -- "Surveillance de sécurité" \
       "Activée sur : ${NETNAME} (${LOGNAMES})"

WARNING=
while [[ -n "${INFINITE}" ]]; do
  [[ -n "${WARNING}" ]] && notify-send -u critical -t ${NOTIFICATION} -i "/usr/local/share/icons/dialog-warning.png" \
	    -- "Analyse de sécurité" \
	    "${WARNING}"
  echo -n > "${TMPFILE}.eventlog"
  for LOGNAME in ${LOGNAMES}; do
    LOGFILE="${LOGDIR}/${LOGNAME}.log"
    REGEXPFILE="${REGEXPDIR}/${NETNAME}-${LOGNAME}"

    NBLINE="$(get_nbline "${LOGFILE}" " -f")"
    rm "${TMPFILE}.log"
    LOGLINE="foo"
    while [[ -n "${LOGLINE}" ]]; do
      echo "Surveillance sur ${LOGFILE} -${NBLINE} -q" > "${DEBUG}"

      # Il faut essayer de mémoriser les timestamps qui ont été traités
      # Avant de lancer le tail, on prend donc le ts, au cas où on sorte
      # sur Timeout

      TS_MONTH="$(date -R | cut -f3 -d" ")"
      TS_DAY="$(date '+%e')"
      TS_HOUR="$(date '+%T')"

      DETECTLINE="$(${SSHCMD} tail -"${NBLINE}" -q "${LOGFILE}")"
      LOGLINE="$(echo "${DETECTLINE}" | grep -v -f "${REGEXPFILE}" -m 1)"
      if [[ -z "${LOGLINE}" ]]; then
	if [[ -n "${DETECTLINE}" ]]; then
	  [[ "${INFO}" == "on" ]] && notify-send -u low -t ${NOTIFICATION} -i "/usr/local/share/icons/dialog-information.png" \
	    -- "Analyse de sécurité" \
	    "Événement reconnu dans ${LOGNAME} (${NETNAME})"
	  LOGLINE="$(echo "${DETECTLINE}" | tail -1)"
# Affichage dans slim.log
	  echo "$(date +'%b %e %T') $(hostname) $(basename "$0"): Evénement reconnu dans les journaux ${LOGNAMES} (${NETNAME})"
	  echo "${LOGLINE}"
# Fin d'affichage
	  echo "${LOGNAME}: ${LOGLINE}" >> "${TMPFILE}.eventlog"
	else
	  echo "${LOGNAME}: ${TS_MONTH} ${TS_DAY} ${TS_HOUR} Timeout" >> "${TMPFILE}.eventlog"
	fi
	break # on passe au fichier de log suivant
      fi
# Affichage dans slim.log
      echo "$(date +'%b %e %T') $(hostname) $(basename "$0"): Evénement détecté dans les journaux ${LOGNAMES} (${NETNAME})"
      echo "${LOGLINE}"
# Fin d'affichage
      EVENTLINE="$(echo ${LOGLINE} | sed -f "${TMPFILE}.sed")"
      if [[ -n "${EVENTLINE}" ]]; then
	cat > "${TMPFILE}.txt" << EOF
${EVENTLINE}
EOF
	RPERSO="$(synthese "${LOGNAME}" "${EVENTLINE}")"
	Xdialog --stdout --no-cancel \
	  --check "Arrêter la surveillance de sécurité et ouvrir l'interface de configuration" \
	  --ok-label "Appliquer" --cancel-label "Annuler" \
	  --timeout ${TIMEOUTXDIALOG} --left \
	  --title "Evénement détecté dans le journal ${LOGNAME} (${NETNAME})" \
	  --inputbox "$(cat "${TMPFILE}.txt")
Entrez une phrase de résumé de la règle :" \
	  20 100 "${RPERSO}" > "${TMPFILE}.out"
	if [[ $? -eq 0 ]]; then
	  IHMcode="$(head -1 "${TMPFILE}.out" | sed -e "s/#/_/g")"
	  IHMm="$(tail -1 "${TMPFILE}.out")"
	else
	  WARNING="Un événement non reconnu a été détecté et non classé dans ${LOGNAME} (${RPERSO}): lancez manuellement l'interface de configuration."
	  IHMcode="${RPERSO}"
	  IHMm=""
	fi
	REGEXPLINE="$(echo "${LOGLINE}" | sed -f "${TMPFILE}.regsed")"
	echo "[${REGEXPLINE}]" >"${DEBUG}"
	echo "${IHMcode} # ${REGEXPLINE}" >> "${REGEXPFILE}.txt"
	extract_regexp "${REGEXPFILE}"
	rm "${TMPFILE}.txt" "${TMPFILE}.out"
	[[ "${IHMm}" == "checked" ]] && exec "$0" ${debug_param}${info_param}"ihm" "${LOGNAMES}"
      fi
      echo "${LOGNAME}: ${LOGLINE}" >> "${TMPFILE}.eventlog"
    done
  done
  if [[ "${INFINITE}" == "no" ]]; then
    nice_exit
  fi
# Il faut maintenant rattrapper les événements perdus
# Le timestamp est inchangé à ce stade.
# Tous les fichiers de logs ont donc été traités depuis le timestamp.
# Le fichier "${TMPFILE}.eventlog" contient toutes les lignes traitées, par 
# fichier de log.
# Pour être sûr de ne pas louper d'événement, il suffit que le timestamp
# soit mis à jour avec le plus anciens des derniers timestamp de chaque
# fichier de log.
# On commence donc par récupérer ces timestamps.
  echo "Events par log :" >"${DEBUG}"
  cat "${TMPFILE}.eventlog" >"${DEBUG}"
  echo -n > "${TMPFILE}.tslog"
  for LOGNAME in ${LOGNAMES}; do
    grep "^${LOGNAME}:" "${TMPFILE}.eventlog" | tail -1 | sed -e "s/^[^[:blank:]]*: //g" >> "${TMPFILE}.tslog"
  done
# On trie ensuite ces timestamps pour récupérer le plus ancien
  echo "Ts par log :" >"${DEBUG}"
  cat "${TMPFILE}.tslog" >"${DEBUG}"
  LOGLINE="$(sort --key=1M --key=2n --key=3 "${TMPFILE}.tslog" | head -1)"
# Mais avant de changer le timestamp, on vérifie que la configuration de réseau
# n'a pas changé
  NBLN="$(get_nbline "${LOGDIR}/daemon.log")"
  echo "nbln: ${MONTH} ${DAY} ${HOUR} ${NBLN}" >"${DEBUG}"
  if [[ "${NBLN}" -gt 0 ]]; then
    NETLINE="$(tail -${NBLN} "${TMPFILE}.log" | grep "Starting network" -m 1 )"
    if [[ -n "${NETLINE}" ]]; then
      echo "Changement de réseau détecté" > "${DEBUG}"
      getnetconf
    else
      get_ts "${LOGLINE}"
    fi
  else
    get_ts "${LOGLINE}"
  fi
  rm "${TMPFILE}."*log
done

