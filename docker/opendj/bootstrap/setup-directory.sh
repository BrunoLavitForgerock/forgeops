#!/usr/bin/env bash
# Set up a directory server.
#
# Copyright (c) 2016-2018 ForgeRock AS. Use of this source code is subject to the
# Common Development and Distribution License (CDDL) that can be found in the LICENSE file

#set -x

cd /opt/opendj

echo "Setting up $BASE_DN"


INIT_OPTION="--addBaseEntry"

# If NUMBER_SAMPLE_USERS is set AND we are the first node, then generate sample users.
if [[  -n "${NUMBER_SAMPLE_USERS}" && $HOSTNAME = *"0"* ]]; then
    INIT_OPTION="--sampleData ${NUMBER_SAMPLE_USERS}"
fi




# An admin server is also a directory server.
# TODO: Integrate keystore settings:
# --usePkcs12keyStore /path/to/keystore.p12 \
# --keyStorePasswordFile /tmp/keystore.pin \
./setup directory-server \
  -p 1389 \
  --enableStartTLS  \
  --adminConnectorPort 4444 \
  --enableStartTls \
  --ldapsPort 1636 \
  --httpPort 8080 --httpsPort 8443 \
  --baseDN "${BASE_DN}" \
  --hostname "${FQDN}" \
  --rootUserPasswordFile "${DIR_MANAGER_PW_FILE}" \
  --monitorUserPasswordFile "${MONITOR_PW_FILE}" \
  --usePkcs12KeyStore "${KEYSTORE_FILE}" \
  --keyStorePasswordFile "${KEYSTORE_PIN_FILE}" \
  --certNickName "${SSL_CERT_ALIAS}" \
  --acceptLicense \
  --doNotStart \
   ${INIT_OPTION}  || (echo "Setup failed, will sleep for debugging"; sleep 10000)

echo "Set the global server id to $SERVER_ID"

bin/dsconfig  set-global-configuration-prop --set server-id:$SERVER_ID  --offline  --no-prompt


echo "Creating CTS backend..."
./bin/dsconfig create-backend \
          --set base-dn:o=cts \
          --set enabled:true \
          --type je \
          --backend-name ctsRoot \
          --offline \
          --no-prompt

cat >/tmp/cts.ldif <<EOF
dn: o=cts
objectClass: top
objectClass: organization
o: cts
EOF

# Need to manually import the base entry as we are offline.
bin/import-ldif --offline -n ctsRoot -F -l /tmp/cts.ldif


echo "Creating CTS UID index for uid=monitor search"
./bin/dsconfig create-backend-index \
          --backend-name ctsRoot \
          --set index-type:equality \
          --type generic \
          --index-name uid \
          --offline \
          --no-prompt


echo "Creating Default Trust Manager..."
./bin/dsconfig create-trust-manager-provider \
      --type file-based \
      --provider-name "Default Trust Manager" \
      --set enabled:true \
      --set trust-store-type:PKCS12 \
      --set trust-store-pin:\&{file:"${KEYSTORE_PIN_FILE}"} \
      --set trust-store-file:"${KEYSTORE_FILE}" \
      --offline \
      --no-prompt

echo "Configuring LDAP connection handler..."
./bin/dsconfig set-connection-handler-prop \
      --handler-name "LDAP" \
      --set "trust-manager-provider:Default Trust Manager" \
      --offline \
      --no-prompt

echo "Configuring LDAPS connection handler..."
./bin/dsconfig set-connection-handler-prop \
      --handler-name "LDAPS" \
      --set "trust-manager-provider:Default Trust Manager" \
      --offline \
      --no-prompt


echo "Tuning the disk free space thresholds"

# For development you may want to tune the disk thresholds. TODO: Make this configurable
bin/dsconfig  set-backend-prop \
    --backend-name userRoot  \
    --set "disk-low-threshold:2GB"  --set "disk-full-threshold:1GB"  \
    --offline \
    --no-prompt

bin/dsconfig  set-backend-prop \
    --backend-name ctsRoot  \
    --set "disk-low-threshold:2GB"  --set "disk-full-threshold:1GB"  \
    --offline \
    --no-prompt


# Load any optional LDIF files. $1 is the directory to load from
load_ldif() {

    # If any optional LDIF files are present, load them.
    ldif=$1

    if [ -d "$ldif" ]; then
        echo "Loading LDIF files in $ldif"
        for file in "${ldif}"/*.ldif;  do
            echo "Loading $file"
            # search + replace all placeholder variables. Naming conventions are from AM.
            sed -e "s/@BASE_DN@/$BASE_DN/"  \
                -e "s/@userStoreRootSuffix@/$BASE_DN/"  \
                -e "s/@DB_NAME@/$DB_NAME/"  \
                -e "s/@SM_CONFIG_ROOT_SUFFIX@/$BASE_DN/"  <${file}  >/tmp/file.ldif

            #cat /tmp/file.ldif
            echo bin/ldapmodify -D "cn=Directory Manager"  --continueOnError -h localhost -p 1389 -j ${DIR_MANAGER_PW_FILE} -f /tmp/file.ldif
            bin/ldapmodify -D "cn=Directory Manager"  --continueOnError -h localhost -p 1389 -j ${DIR_MANAGER_PW_FILE} -f /tmp/file.ldif
            # Note that currently these ldif files must be added with ldapmodify.
            #bin/import-ldif --offline -n userRoot -l /tmp/file.ldif --rejectFile /tmp/rejects.ldif
            #cat /tmp/rejects.ldif
          echo "  "
        done
    fi
}


# Load any optional ldif files. These fiiles need to be loaded with the server running.
bin/start-ds
load_ldif "bootstrap/userstore/ldif"
load_ldif "bootstrap/cts/ldif"
bin/stop-ds

echo "Rebuilding indexes"
bin/rebuild-index --offline --baseDN "${BASE_DN}" --rebuildDegraded
bin/rebuild-index --offline --baseDN "o=cts" --rebuildDegraded


# Run post install customization script if the user supplied one.
script="bootstrap/post-install.sh"

if [ -r "$script" ]; then
    echo "executing post install script $script"
    sh "$script"
fi

# Set the paths to our PVC directory
./bootstrap/set-data-paths.sh 

./bootstrap/log-redirect.sh

if [[ $HOSTNAME =~ cts* ]]; then
    echo "Disabling acccess logging for the CTS"
    ./bootstrap/disable-access-log.sh 

    echo "Tuning ds"
    ./bootstrap/dstune.sh
fi

# Before we enable rest2ldap we need a strategy for parameterizing the json template
#./bootstrap/setup-rest2ldap.sh

# Note that presently dsreplication does not handle templated config.ldif. You
# must completely finish setting up replication first, and then template this file.
#./bootstrap/convert-config-to-template.sh


if [ -d data ]; then
    echo "Moving mutable directories to data/"
    # For now we need to most of the directories created by setup, including the "immutable" ones.
    # When we get full support for commons configuration we should revisit.
    for dir in db changelogDb config var import-tmp
    do
        echo "moving $dir to data/"
        # Use cp as it works across file systems.
        cp -r $dir data/$dir
        rm -fr $dir
    done
fi


for d in data/*
do
    echo "Creating symbolic link $d"
    ln -s $d
done
