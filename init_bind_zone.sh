#!/bin/bash
#
# To be run on primary DNS host to be delegated new DNSSEC zone
echo
echo "Executing ${PWD}/$0 on host ${HOSTNAME}"

# Source env file for variable default values
ENV_FILE=${ENV_FILE:-".env"}
if [ -e ${ENV_FILE} ]
then
	echo "Sourcing ${PWD}/${ENV_FILE} ..."
	. ${ENV_FILE}
fi

# Default existing parent ZONE fallback to $DOMAINNAME if set, else to domain set in $HOSTNAME, else error
#
ZONE=${ZONE:-${DOMAINNAME}}
ZONE=${ZONE:-${HOSTNAME#*.}}
if [[ ! -n ${ZONE} ]]; then
	echo "Error: Parent DNS zone \$ZONE environment variable not set in command line, sourced in ${ENV_FILE} or determined from \$DOMAINNAME or \$HOSTNAME"
	exit 1
fi

# Discover master (usually primary DNS server) of parent zone from SOA record
#
DIG_QUERY_PARAM=${DIG_QUERY_PARAM:-}
ZONE_SOA_MASTER=${ZONE_SOA_MASTER:-$(dig ${DIG_QUERY_PARAM} +short ${ZONE} SOA | cut -f1 -d' ')}
if [[ ! -n ${ZONE_SOA_MASTER} ]]; then
	echo "Warning: Parent ZONE ${ZONE} SOA record does not resolve"
fi

# Define zone to install on local BIND server
#
NEW_SUBZONE=${NEW_SUBZONE:-"testzone"}
NEW_ZONE="${NEW_SUBZONE}.${ZONE}"

# Define path, ownership & BIND zone filename for new zone
# TODO discover this from BIND configuration and/or OS defaults
#
NEW_ZONE_PATH=${NEW_ZONE_PATH:-"/var/cache/bind/dynamic/${NEW_ZONE}"} # default in Debian
NEW_ZONE_KEY_PATH=${NEW_ZONE_KEY_PATH:-"${NEW_ZONE_PATH}"} # default key storage path
NEW_ZONE_FILENAME="named.${NEW_ZONE}" # needed to create dnssec dynamic zonefile below - not recommended to change
NEW_ZONE_PATH_OWNER=${NEW_ZONE_PATH_OWNER:-"bind:bind"}                     # default in Debian

NEW_ZONE_SOA_MASTER=${NEW_ZONE_SOA_MASTER:-"dns-oarc.free2air.net"}
NEW_ZONE_SOA_CONTACT=${NEW_ZONE_SOA_CONTACT:-"root.free2air.org."}
NEW_ZONE_SOA_SERIAL=${NEW_ZONE_SOA_SERIAL:-"2007243476 ; serial"}
NEW_ZONE_SOA_REFRESH=${NEW_ZONE_SOA_REFRESH:-"10800      ; refresh (3 hours)"}
NEW_ZONE_SOA_RETRY=${NEW_ZONE_SOA_RETRY:-"900        ; retry (15 minutes)"}
NEW_ZONE_SOA_EXPIRE=${NEW_ZONE_SOA_EXPIRE:-"604800     ; expire (1 week)"}
NEW_ZONE_SOA_MINIMUM=${NEW_ZONE_SOA_MINIMUM:-"86400      ; minimum (1 day)"}

NEW_ZONE_SERVER_IP=${NEW_ZONE_SERVER_IP:-"128.140.34.230"}

NEW_ZONE_DNSSEC_ALGORITHM="RSASHA256" # current (20230529) recommended DNSSEC key algo

echo
echo "ZONE = ${ZONE}"
echo "ZONE_SOA_MASTER = ${ZONE_SOA_MASTER}"

echo
echo "NEW_ZONE = ${NEW_ZONE}"

echo "NEW_ZONE_PATH = ${NEW_ZONE_PATH}"
echo "NEW_ZONE_FILENAME = ${NEW_ZONE_FILENAME}"
echo "NEW_ZONE_PATH_OWNER = ${NEW_ZONE_PATH_OWNER}"

echo
echo "NEW_ZONE_SOA_MASTER = ${NEW_ZONE_SOA_MASTER}"
echo "NEW_ZONE_SOA_CONTACT = ${NEW_ZONE_SOA_CONTACT}"

echo
echo " New zone ${NEW_SUBZONE} to be created under ${ZONE} with update server ${ZONE_SOA_MASTER}"

# Create path for new zone
if [ -d "${NEW_ZONE_PATH}" ]; then
       echo "Warning: path ${NEW_ZONE_PATH} already exists"
else
 	mkdir -p ${NEW_ZONE_PATH} || exit 1
	chown -R ${NEW_ZONE_PATH_OWNER} ${NEW_ZONE_PATH} || exit 1
fi

if [ -f "${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME}" ]; then
	echo "Error: zonefile ${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME} already exists"
	exit 1
fi

cat <<EOF >${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME}.unsigned 
\$ORIGIN .
\$TTL 360        ; 6 minutes

${NEW_ZONE}                IN SOA  ${NEW_ZONE_SOA_MASTER}. ${NEW_ZONE_SOA_CONTACT} (
                                ${NEW_ZONE_SOA_SERIAL}
                                ${NEW_ZONE_SOA_REFRESH}
                                ${NEW_ZONE_SOA_RETRY}
                                ${NEW_ZONE_SOA_EXPIRE}
                                ${NEW_ZONE_SOA_MINIMUM}
                                )
\$TTL 600
                        NS      ${NEW_ZONE_SOA_MASTER}.
                        A       ${NEW_ZONE_SERVER_IP}
EOF


# create zone signing key (ZSK)
#
dnssec-keygen -K ${NEW_ZONE_KEY_PATH} -a ${NEW_ZONE_DNSSEC_ALGORITHM} -b 2048 -n ZONE ${NEW_ZONE}

# create key signing key (KSK)
#
dnssec-keygen -K ${NEW_ZONE_KEY_PATH} -f KSK -a ${NEW_ZONE_DNSSEC_ALGORITHM} -b 4096 -n ZONE ${NEW_ZONE}

#  add the ZSK & KSK public keys to zone
#
for key in `ls ${NEW_ZONE_PATH}/K${NEW_ZONE}*.key`
do
echo "\$INCLUDE $key">> ${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME}.unsigned
done

# sign zone
#
# for dynamic zones, bind detects *.signed and *.jnl files
# as we are bootstrapping this from a dns to dnssec zone bind config, we just place zonefile without .signed extension.

SALT=`head -c 1000 /dev/random | sha1sum | cut -b 1-16`
dnssec-signzone -K ${NEW_ZONE_PATH} -3 ${SALT} -A -N INCREMENT -o ${NEW_ZONE} -t -f ${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME} -d ${NEW_ZONE_PATH} ${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME}.unsigned 
chown -R ${NEW_ZONE_PATH_OWNER} ${NEW_ZONE_PATH}/${NEW_ZONE_FILENAME}

