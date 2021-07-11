#!/bin/sh

# Based on POTLUCK TEMPLATE v3.0
# Altered by Michael Gmelin
#
# EDIT THE FOLLOWING FOR NEW FLAVOUR:
# 1. RUNS_IN_NOMAD - true or false
# 2. If RUNS_IN_NOMAD is false, can delete the <flavour>+4 file, else
#    make sure pot create command doesn't include it
# 3. Create a matching <flavour> file with this <flavour>.sh file that
#    contains the copy-in commands for the config files from <flavour>.d/
#    Remember that the package directories don't exist yet, so likely copy
#    to /root
# 4. Adjust package installation between BEGIN & END PACKAGE SETUP
# 5. Adjust jail configuration script generation between BEGIN & END COOK
#    Configure the config files that have been copied in where necessary

# Set this to true if this jail flavour is to be created as a nomad (i.e. blocking) jail.
# You can then query it in the cook script generation below and the script is installed
# appropriately at the end of this script
RUNS_IN_NOMAD=false

# set the cook log path/filename
COOKLOG=/var/log/cook.log

# check if cooklog exists, create it if not
if [ ! -e $COOKLOG ]
then
    echo "Creating $COOKLOG" | tee -a $COOKLOG
else
    echo "WARNING $COOKLOG already exists"  | tee -a $COOKLOG
fi
date >> $COOKLOG

# -------------------- COMMON ---------------

STEPCOUNT=0
step() {
  STEPCOUNT=$(expr "$STEPCOUNT" + 1)
  STEP="$@"
  echo "Step $STEPCOUNT: $STEP" | tee -a $COOKLOG
}

exit_ok() {
  trap - EXIT
  exit 0
}

FAILED=" failed"
exit_error() {
  STEP="$@"
  FAILED=""
  exit 1
}

set -e
trap 'echo ERROR: $STEP$FAILED | (>&2 tee -a $COOKLOG)' EXIT

# -------------- BEGIN PACKAGE SETUP -------------

step "Bootstrap package repo"
mkdir -p /usr/local/etc/pkg/repos
#echo 'FreeBSD: { url: "pkg+http://pkg.FreeBSD.org/${ABI}/latest" }' \
echo 'FreeBSD: { url: "pkg+http://pkg.FreeBSD.org/${ABI}/quarterly" }' \
  >/usr/local/etc/pkg/repos/FreeBSD.conf
ASSUME_ALWAYS_YES=yes pkg bootstrap

step "Touch /etc/rc.conf"
touch /etc/rc.conf

# this is important, otherwise running /etc/rc from cook will
# overwrite the IP address set in tinirc
step "Remove ifconfig_epair0b from config"
sysrc -cq ifconfig_epair0b && sysrc -x ifconfig_epair0b || true

step "Disable sendmail"
service sendmail onedisable

step "Create /usr/local/etc/rc.d"
mkdir -p /usr/local/etc/rc.d

# we need consul for consul agent
step "Install package consul"
pkg install -y consul

step "Install package node_exporter"
pkg install -y node_exporter

step "Install package sudo"
pkg install -y sudo

step "Install package curl"
pkg install -y curl

step "Install package jq"
pkg install -y jq

step "Install package vault"
pkg install -y vault

step "Clean package installation"
pkg clean -y

# -------------- END PACKAGE SETUP -------------

#
# Create configurations
#

#
# Now generate the run command script "cook"
# It configures the system on the first run by creating the config file(s)
# On subsequent runs, it only starts sleeps (if nomad-jail) or simply exits
#

# clear any old cook runtime file
step "Remove pre-existing cook script (if any)"
rm -f /usr/local/bin/cook

# this runs when image boots
# ----------------- BEGIN COOK ------------------

step "Create cook script"
echo "#!/bin/sh
RUNS_IN_NOMAD=$RUNS_IN_NOMAD
# declare this again for the pot image, might work carrying variable through like
# with above
COOKLOG=/var/log/cook.log
# No need to change this, just ensures configuration is done only once
if [ -e /usr/local/etc/pot-is-seasoned ]
then
    # If this pot flavour is blocking (i.e. it should not return),
    # we block indefinitely
    if [ \"\$RUNS_IN_NOMAD\" = \"true\" ]
    then
        /bin/sh /etc/rc
        tail -f /dev/null
    fi
    exit 0
fi

# ADJUST THIS: STOP SERVICES AS NEEDED BEFORE CONFIGURATION
# not needed, not started automatically, needs configuring

# No need to adjust this:
# If this pot flavour is not blocking, we need to read the environment first from /tmp/environment.sh
# where pot is storing it in this case
if [ -e /tmp/environment.sh ]
then
    . /tmp/environment.sh
fi

#
# ADJUST THIS BY CHECKING FOR ALL VARIABLES YOUR FLAVOUR NEEDS:
#

# Check config variables are set
#
if [ -z \${DATACENTER+x} ]; then
    echo 'DATACENTER is unset - see documentation how to configure this flavour'
    exit 1
fi
if [ -z \${NODENAME+x} ];
then
    echo 'NODENAME is unset - see documentation how to configure this flavour'
    exit 1
fi
if [ -z \${CONSULSERVERS+x} ]; then
    echo 'CONSULSERVERS is unset - see documentation how to configure this flavour'
    exit 1
fi
if [ -z \${IP+x} ]; then
    echo 'IP is unset - see documentation how to configure this flavour'
    exit 1
fi
if [ -z \${VAULTSERVER+x} ];
then
    echo 'VAULTSERVER is unset - you must include the master vault server IP'
    exit 1
fi
# we need a token from the vault server
if [ -z \${VAULTTOKEN+x} ];
then
    echo 'VAULTTOKEN is unset - see documentation how to configure this flavour. You must pass in a valid token'
    exit 1
fi
# GOSSIPKEY is a 32 byte, Base64 encoded key generated with consul keygen for the consul flavour.
# Re-used for nomad, which is usually 16 byte key but supports 32 byte, Base64 encoded keys
# We'll re-use the one from the consul flavour
if [ -z \${GOSSIPKEY+x} ];
then
    echo 'GOSSIPKEY is unset - see documentation how to configure this flavour, defaulting to preset encrypt key. Do not use this in production!'
    GOSSIPKEY='\"BY+vavBUSEmNzmxxS3k3bmVFn1giS4uEudc774nBhIw=\"'
fi
if [ -z \${LOGCLIENTS+x} ];
then
    echo 'LOGCLIENTS is unset - see documentation how to configure this flavour, please include the subnet to accept logs from'
    exit 1
fi

# ADJUST THIS BELOW: NOW ALL THE CONFIGURATION FILES NEED TO BE CREATED:
# Don't forget to double(!)-escape quotes and dollar signs in the config files

# setup directories for vault usage
mkdir -p /mnt/templates
mkdir -p /mnt/certs

## start consul

# make consul configuration directory and set permissions
mkdir -p /usr/local/etc/consul.d
chmod 750 /usr/local/etc/consul.d

# Create the consul agent config file with imported variables
echo \"{
 \\\"advertise_addr\\\": \\\"\$IP\\\",
 \\\"datacenter\\\": \\\"\$DATACENTER\\\",
 \\\"node_name\\\": \\\"\$NODENAME\\\",
 \\\"data_dir\\\":  \\\"/var/db/consul\\\",
 \\\"dns_config\\\": {
  \\\"a_record_limit\\\": 3,
  \\\"enable_truncate\\\": true
 },
 \\\"verify_incoming\\\": false,
 \\\"verify_outgoing\\\": true,
 \\\"verify_server_hostname\\\":false,
 \\\"verify_incoming_rpc\\\": true,
 \\\"ca_file\\\": \\\"/mnt/certs/lokica.pem\\\",
 \\\"cert_file\\\": \\\"/mnt/certs/lokicert.pem\\\",
 \\\"key_file\\\": \\\"/mnt/certs/lokikey.pem\\\",
 \\\"log_file\\\": \\\"/var/log/consul/\\\",
 \\\"log_level\\\": \\\"WARN\\\",
 \\\"encrypt\\\": \$GOSSIPKEY,
 \\\"start_join\\\": [ \$CONSULSERVERS ],
 \\\"telemetry\\\": {
  \\\"prometheus_retention_time\\\": \\\"24h\\\",
  \\\"disable_hostname\\\": true
 },
 \\\"service\\\": {
  \\\"address\\\": \\\"\$IP\\\",
  \\\"name\\\": \\\"node-exporter\\\",
  \\\"tags\\\": [\\\"_app=prometheus\\\", \\\"_service=node-exporter\\\", \\\"_hostname=\$NODENAME\\\", \\\"_datacenter=\$DATACENTER\\\"],
  \\\"port\\\": 9100
 }
}\" > /usr/local/etc/consul.d/agent.json

# set owner and perms on agent.json
chown consul:wheel /usr/local/etc/consul.d/agent.json
chmod 640 /usr/local/etc/consul.d/agent.json

# enable consul
sysrc consul_enable=\"YES\"

# set load parameter for consul config
sysrc consul_args=\"-config-file=/usr/local/etc/consul.d/agent.json\"
#sysrc consul_datadir=\"/var/db/consul\"

# Workaround for bug in rc.d/consul script:
sysrc consul_group=\"wheel\"

# setup consul logs, might be redundant if not specified in agent.json above
mkdir -p /var/log/consul
touch /var/log/consul/consul.log
chown -R consul:wheel /var/log/consul

# add the consul user to the wheel group, this seems to be required for
# consul to start on this instance. May need to figure out why.
# I'm not entirely sure this is the correct way to do it
/usr/sbin/pw usermod consul -G wheel

## end consul

## start Vault

# first remove any existing vault configuration
if [ -f /usr/local/etc/vault/vault-server.hcl ]; then
    rm /usr/local/etc/vault/vault-server.hcl
fi
# then setup a fresh vault.hcl specific to the type of image

# default freebsd vault.hcl is /usr/local/etc/vault.hcl and
# the init script /usr/local/etc/rc.d/vault refers to this
# but many vault docs refer to /usr/local/etc/vault/vault-server.hcl
# or similar

# begin vault config
# we're setting a config file but not actually running the vault service
# certificate rotation is being done with a cron job
# token rotation may require the vault service

echo \"disable_mlock = true
ui = false
vault {
  address = \\\"\$VAULTSERVER:8200\\\"
  retry {
    num_retries = 5
  }
}
storage \\\"file\\\" {
  path = \\\"/mnt/vault/data\\\"
}
template {
  source = \\\"/mnt/templates/cert.tpl\\\"
  destination = \\\"/mnt/certs/lokicert.pem\\\"
}
template {
  source = \\\"/mnt/templates/ca.tpl\\\"
  destination = \\\"/mnt/certs/lokica.pem\\\"
}
template {
  source = \\\"/mnt/templates/key.tpl\\\"
  destination = \\\"/mnt/certs/lokikey.pem\\\"
}\" > /usr/local/etc/vault.hcl

# setup template files for certificates
echo \"{{- /* /mnt/templates/cert.tpl */ -}}
{{ with secret \\\"pki_int/issue/\$DATACENTER\\\" \\\"common_name=\$NODENAME\\\" \\\"ttl=24h\\\" \\\"alt_names=\$NODENAME\\\" \\\"ip_sans=\$IP\\\" }}
{{ .Data.certificate }}{{ end }}
\" > /mnt/templates/cert.tpl

echo \"{{- /* /mnt/templates/ca.tpl */ -}}
{{ with secret \\\"pki_int/issue/\$DATACENTER\\\" \\\"common_name=\$NODENAME\\\" }}
{{ .Data.issuing_ca }}{{ end }}
\" > /mnt/templates/ca.tpl

echo \"{{- /* /mnt/templates/key.tpl */ -}}
{{ with secret \\\"pki_int/issue/\$DATACENTER\\\" \\\"common_name=\$NODENAME\\\" \\\"ttl=24h\\\" \\\"alt_names=\$NODENAME\\\" \\\"ip_sans=\$IP\\\" }}
{{ .Data.private_key }}{{ end }}
\" > /mnt/templates/key.tpl

# set permissions on /mnt for vault data
chown -R vault:wheel /mnt/certs
chown -R vault:wheel /mnt/templates

# setup rc.conf entries
# we do not set vault_user=vault because vault will not start
# we're not starting vault as a service
sysrc vault_enable=no
sysrc vault_login_class=root
sysrc vault_syslog_output_enable=\"YES\"
sysrc vault_syslog_output_priority=\"warn\"

# retrieve CA certificates from vault leader
echo \"Retrieving CA certificates from Vault leader\"
/usr/local/bin/vault read -address=https://\$VAULTSERVER:8200 -tls-skip-verify -field=certificate pki/cert/ca > /mnt/certs/CA_cert.crt
/usr/local/bin/vault read -address=https://\$VAULTSERVER:8200 -tls-skip-verify -field=certificate pki_int/cert/ca > /mnt/certs/intermediate.cert.pem

# unwrap the pki token issued by vault leader
echo \"Unwrapping passed in token...\"
/usr/local/bin/vault unwrap -address=https://\$VAULTSERVER:8200 -ca-cert=/mnt/certs/intermediate.cert.pem -format=json \$VAULTTOKEN | /usr/local/bin/jq -r '.auth.client_token' > /root/unwrapped.token
sleep 1
if [ -s /root/unwrapped.token ]; then
    echo \"Token unwrapped\"
    THIS_TOKEN=\$(/bin/cat /root/unwrapped.token)
    echo \"Logging in to vault leader to authenticate\"
    echo \"\$THIS_TOKEN\" | /usr/local/bin/vault login -address=https://\$VAULTSERVER:8200 -ca-cert=/mnt/certs/intermediate.cert.pem -method=token -field=token token=- > /root/login.token
    sleep 5
fi

echo \"Setting certificate payload\"
if [ -s /root/login.token ]; then
    # generate certificates to use
    # using this payload.json approach to avoid nested single and double quotes for expansion
    echo \"{
\\\"common_name\\\": \\\"\$NODENAME\\\",
\\\"ttl\\\": \\\"24h\\\",
\\\"ip_sans\\\": \\\"\$IP\\\"
}\" > /mnt/templates/payload.json

    # we use curl to get the certificates in json format as the issue command only has formats: pem, pem_bundle, der
    # but no json format except via the API
    echo \"Generating certificates to use from Vault\"
    HEADER=\$(/bin/cat /root/login.token)
    /usr/local/bin/curl --cacert /mnt/certs/intermediate.cert.pem --header \"X-Vault-Token: \$HEADER\" --request POST --data @/mnt/templates/payload.json https://\$VAULTSERVER:8200/v1/pki_int/issue/\$DATACENTER > /mnt/certs/vaultissue.json

    # cli requires [], but web api does not
    #/usr/local/bin/jq -r '.data.issuing_ca[]' /mnt/certs/vaultissue.json > /mnt/certs/lokica.pem
    # if [] left in for this script, you will get error: Cannot iterate over string
    /usr/local/bin/jq -r '.data.issuing_ca' /mnt/certs/vaultissue.json > /mnt/certs/lokica.pem
    /usr/local/bin/jq -r '.data.certificate' /mnt/certs/vaultissue.json > /mnt/certs/lokicert.pem
    /usr/local/bin/jq -r '.data.private_key' /mnt/certs/vaultissue.json > /mnt/certs/lokikey.pem

    # set permissions on /mnt/certs for vault
    chown -R vault:wheel /mnt/certs

    # removing as not sure vault service needs to be running here
    # start vault
    #echo \"Starting Vault Agent\"
    #/usr/local/etc/rc.d/vault start

    # start consul agent
    /usr/local/etc/rc.d/consul start

    # setup certificate rotation script
    echo \"#!/bin/sh
if [ -s /root/login.token ]; then
    LOGINTOKEN=\\\$(/bin/cat /root/login.token)
    HEADER=\\\$(echo \\\"X-Vault-Token: \\\"\\\$LOGINTOKEN)
    /usr/local/bin/curl -k --header \\\"\\\$HEADER\\\" --request POST --data @/mnt/templates/payload.json https://\$VAULTSERVER:8200/v1/pki_int/issue/\$DATACENTER > /mnt/certs/vaultissue.json
    /usr/local/bin/jq -r '.data.issuing_ca' /mnt/certs/vaultissue.json > /mnt/certs/lokica.pem
    /usr/local/bin/jq -r '.data.certificate' /mnt/certs/vaultissue.json > /mnt/certs/lokicert.pem
    /usr/local/bin/jq -r '.data.private_key' /mnt/certs/vaultissue.json > /mnt/certs/lokikey.pem
    # set permissions on /mnt/certs for vault
    chown -R vault:wheel /mnt/certs
    /usr/local/etc/rc.d/consul reload
    /usr/local/etc/rc.d/node_exporter restart
    #/usr/local/etc/rc.d/loki restart
else
    echo \\\"/root/login.token does not contain a token. Certificates cannot be renewed.\\\"
fi
\" > /root/rotate-certs.sh

    if [ -f /root/rotate-certs.sh ]; then
        # make executable
        chmod +x /root/rotate-certs.sh
        # add a crontab entry for every hour
        echo \"0 * * * * root /root/rotate-certs.sh >> /mnt/rotate-cert.log 2>&1\" >> /etc/crontab
    fi

    # syslogd setup

    # setup log directory for stored logs
    mkdir -p /mnt/logs

    # setup sysrc entries to start and set parameters to accept logs from remote subnet
    sysrc syslogd_enable=\"YES\"
    sysrc syslogd_flags=\"-b \$IP:514 -a \$LOGCLIENTS:* -n -C -vv\"

    #TRIMLOGCLIENTS=\$(echo \$LOGCLIENTS | /usr/bin/grep -o '[0-9]\+[.][0-9]\+[.][0-9]\+[.][0-9]\+')

    echo \"#-\$IP
*.*                                             /mnt/logs/central.log
#*
\" >> /etc/syslog.conf

    /etc/rc.d/syslogd restart

    # loki setup
    # download the source files
    /usr/bin/fetch https://github.com/grafana/loki/releases/download/v2.2.1/loki-freebsd-amd64.zip --output=/root/loki-freebsd-amd64.zip

    # extract loki and copy to /usr/local/bin
    cd /root/
    if [ -f /root/loki-freebsd-amd64.zip ]; then
        /usr/bin/unzip loki-freebsd-amd64.zip
        if [ -f /root/loki-freebsd-amd64 ]; then
            /bin/cp -f /root/loki-freebsd-amd64 /usr/local/bin/loki-freebsd-amd64
            /bin/chmod a+x /usr/local/bin/loki-freebsd-amd64
            /bin/ln -s /usr/local/bin/loki-freebsd-amd64 /usr/local/bin/loki
        fi
    fi

    # copy in the loki rc file
    if [ -f /root/loki.rc ]; then
        /bin/cp -f /root/loki.rc /usr/local/etc/rc.d/loki
        /bin/chmod +x /usr/local/etc/rc.d/loki
        sysrc loki_enable=\"YES\"
        sysrc loki_syslog_output_enable=\"YES\"
    fi

    # copy in the loki config file
    if [ -f /root/loki-local-config.yaml ]; then
        /usr/bin/sed -i .orig \"s/MYIP/\$IP/g\" /root/loki-local-config.yaml
        /bin/cp -f /root/loki-local-config.yaml /usr/local/etc/loki-local-config.yaml
    fi

    # promtail
    # download the source files
    /usr/bin/fetch https://github.com/grafana/loki/releases/download/v2.2.1/promtail-freebsd-amd64.zip --output=/root/promtail-freebsd-amd64.zip

    # extract promtail and copy to /usr/local/bin
    if [ -f /root/promtail-freebsd-amd64.zip ]; then
        /usr/bin/unzip promtail-freebsd-amd64.zip
        if [ -f /root/promtail-freebsd-amd64 ]; then
            /bin/cp -f /root/promtail-freebsd-amd64 /usr/local/bin/promtail-freebsd-amd64
            /bin/chmod a+x /usr/local/bin/promtail-freebsd-amd64
            /bin/ln -s /usr/local/bin/promtail-freebsd-amd64 /usr/local/bin/promtail
        fi
    fi

    # copy in the promtail rc file
    if [ -f /root/promtail.rc ]; then
        /bin/cp -f /root/promtail.rc /usr/local/etc/rc.d/promtail
        /bin/chmod +x /usr/local/etc/rc.d/promtail
        sysrc promtail_enable=\"YES\"
        sysrc promtail_syslog_output_enable=\"YES\"
    fi

    # copy in the promtail config file
    if [ -f /root/promtail-local-config.yaml ]; then
        /usr/bin/sed -i .orig \"s/MYIP/\$IP/g\" /root/promtail-local-config.yaml
        /bin/cp -f /root/promtail-local-config.yaml /usr/local/etc/promtail-local-config.yaml
    fi

    # start services
    /usr/local/etc/rc.d/loki start
    /usr/local/etc/rc.d/promtail start

    ## start node_exporter config
    # node exporter needs tls setup
    echo \"tls_server_config:
  cert_file: /mnt/certs/lokicert.pem
  key_file: /mnt/certs/lokikey.pem
\" > /usr/local/etc/node-exporter.yml

    # enable node_exporter service
    sysrc node_exporter_enable=\"YES\"
    sysrc node_exporter_args=\"--web.config=/usr/local/etc/node-exporter.yml\"
    ## end node_exporter config

    # start node_exporter
    /usr/local/etc/rc.d/node_exporter start
else
    echo \"ERROR: There was a problem logging into vault and no certificates were retrieved. Vault not started.\"
fi


#
# ADJUST THIS: START THE SERVICES AGAIN AFTER CONFIGURATION

# start services


#
# Do not touch this:
touch /usr/local/etc/pot-is-seasoned

# If this pot flavour is blocking (i.e. it should not return), there is no /tmp/environment.sh
# created by pot and we now after configuration block indefinitely
if [ \"\$RUNS_IN_NOMAD\" = \"true\" ]
then
    /bin/sh /etc/rc
    tail -f /dev/null
fi
" > /usr/local/bin/cook

# ----------------- END COOK ------------------


# ---------- NO NEED TO EDIT BELOW ------------

step "Make cook script executable"
if [ -e /usr/local/bin/cook ]
then
    echo "setting executable bit on /usr/local/bin/cook" | tee -a $COOKLOG
    chmod u+x /usr/local/bin/cook
else
    exit_error "there is no /usr/local/bin/cook to make executable"
fi

#
# There are two ways of running a pot jail: "Normal", non-blocking mode and
# "Nomad", i.e. blocking mode (the pot start command does not return until
# the jail is stopped).
# For the normal mode, we create a /usr/local/etc/rc.d script that starts
# the "cook" script generated above each time, for the "Nomad" mode, the cook
# script is started by pot (configuration through flavour file), therefore
# we do not need to do anything here.
#

# Create rc.d script for "normal" mode:
step "Create rc.d script to start cook"
echo "creating rc.d script to start cook" | tee -a $COOKLOG

echo "#!/bin/sh
#
# PROVIDE: cook
# REQUIRE: LOGIN
# KEYWORD: shutdown
#
. /etc/rc.subr
name=\"cook\"
rcvar=\"cook_enable\"
load_rc_config \$name
: \${cook_enable:=\"NO\"}
: \${cook_env:=\"\"}
command=\"/usr/local/bin/cook\"
command_args=\"\"
run_rc_command \"\$1\"
" > /usr/local/etc/rc.d/cook

step "Make rc.d script to start cook executable"
if [ -e /usr/local/etc/rc.d/cook ]
then
  echo "Setting executable bit on cook rc file" | tee -a $COOKLOG
  chmod u+x /usr/local/etc/rc.d/cook
else
  exit_error "/usr/local/etc/rc.d/cook does not exist"
fi

if [ "$RUNS_IN_NOMAD" != "true" ]
then
  step "Enable cook service"
  # This is a non-nomad (non-blocking) jail, so we need to make sure the script
  # gets started when the jail is started:
  # Otherwise, /usr/local/bin/cook will be set as start script by the pot flavour
  echo "enabling cook" | tee -a $COOKLOG
  service cook enable
fi

# -------------------- DONE ---------------
exit_ok