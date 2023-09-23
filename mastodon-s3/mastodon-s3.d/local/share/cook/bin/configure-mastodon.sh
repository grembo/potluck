#!/bin/sh

# shellcheck disable=SC1091
if [ -e /root/.env.cook ]; then
    . /root/.env.cook
fi

set -e
# shellcheck disable=SC3040
set -o pipefail

export PATH=/usr/local/bin:$PATH

# create mastodon user without -m, --create-home
if ! id -u "mastodon" >/dev/null 2>&1; then
  /usr/sbin/pw useradd -n mastodon -c 'Mastodon User' -d /usr/local/www/mastodon -s /bin/sh -h -
fi

# make directory to store keys
mkdir -p /mnt/mastodon/private

# set permissions on key directory after creating user
chown -R mastodon:mastodon /mnt/mastodon/

# make sure we have /usr/local/www/mastodon
mkdir -p /usr/local/www/mastodon

# set perms on /usr/local/www/mastodon to mastodon:mastodon
chown -R mastodon:mastodon /usr/local/www/mastodon

# if we do not have /usr/local/www/mastodon/.git then
# configure /usr/local/www/mastodon as git repo and pull files
if [ ! -d /usr/local/www/mastodon/.git ]; then
	echo "Initiating git repo in /usr/local/www/mastodon"
	su - mastodon -c "cd /usr/local/www/mastodon; git init"
	echo "Adding remote origin https://github.com/mastodon/mastodon.git"
	su - mastodon -c "cd /usr/local/www/mastodon; git remote add origin https://github.com/mastodon/mastodon.git"
	echo "Running git fetch"
	su - mastodon -c "cd /usr/local/www/mastodon; git fetch"
	echo "Checking out the mastodon release we want"
	su - mastodon -c "cd /usr/local/www/mastodon; git checkout origin/main -b 4.2.0"
	echo "Pulling files from git"
	su - mastodon -c "cd /usr/local/www/mastodon; git pull"
else
	echo ".git directory exists, not cloning repo"
fi

# moved from base file mastodon-s3.sh in anticipation switch to install from github
#
# The FreeBSD wiki has a set of instructions
# https://wiki.freebsd.org/Ports/net-im/mastodon
# however it is missing a step to 'yarn add node-gyp'
# as covered in the Bastillefile at
# https://codeberg.org/ddowse/mastodon/src/branch/main/Bastillefile

# enable corepack
echo "Enabling corepack"
/usr/local/bin/corepack enable

# Add node-gyp to yarn
echo "Adding node-gyp to yarn"
/usr/local/bin/yarn add node-gyp

# as user mastodon - set yarn classic
echo "Setting yarn to classic version"
su - mastodon -c "/usr/local/bin/yarn set version classic"

# as user mastodon - enable deployment
echo "Setting mastodon deployment to true"
su - mastodon -c "cd /usr/local/www/mastodon && /usr/local/bin/bundle config deployment 'true'"

# as user mastodon - remove development and test environments
echo "Removing development and test environments"
su - mastodon -c "cd /usr/local/www/mastodon && /usr/local/bin/bundle config without 'development test'"

# as user mastodon - bundle install
echo "Installing the required files with bundle"
su - mastodon -c "cd /usr/local/www/mastodon && /usr/local/bin/bundle install -j1"

# as user mastodon - yarn install process
echo "Installing the required files with yarn"
su - mastodon -c "cd /usr/local/www/mastodon && /usr/local/bin/yarn install --pure-lockfile"

# generate a rake secret if the file /mnt/mastodon/private/secret.key doesn't exist
if [ -f /mnt/mastodon/private/secret.key ]; then
	echo "Secret key exists, not creating"
	SECRETKEY=$(cat /mnt/mastodon/private/secret.key)
else
	echo "Creating a secret key, this takes a few seconds"
	su - mastodon -c 'cd /usr/local/www/mastodon && RAILS_ENV=production /usr/local/bin/bundle exec rake secret > /mnt/mastodon/private/secret.key'
	SECRETKEY=$(cat /mnt/mastodon/private/secret.key)
fi

# generate OTP secret if the file /mnt/mastodon/private/otp.key doesn't exist
if [ -f /mnt/mastodon/private/otp.key ]; then
	echo "OTP exists, not creating"
	OTPSECRET=$(cat /mnt/mastodon/private/otp.key)
else
	echo "Creating OTP key, this takes a few seconds"
	su - mastodon -c 'cd /usr/local/www/mastodon && RAILS_ENV=production /usr/local/bin/bundle exec rake secret > /mnt/mastodon/private/otp.key'
	OTPSECRET=$(cat /mnt/mastodon/private/otp.key)
fi

# generate vapid keys if the file /mnt/mastodon/private/vapid.keys doesn't exist
if [ -f /mnt/mastodon/private/vapid.keys ]; then
	echo "VAPID keys exist, not creating"
	VAPIDPRIVATEKEY=$(grep VAPID_PRIVATE_KEY /mnt/mastodon/private/vapid.keys | awk -F'=' '{print $2}')
	VAPIDPUBLICKEY=$(grep VAPID_PUBLIC_KEY /mnt/mastodon/private/vapid.keys | awk -F'=' '{print $2}')
else
	echo "Creating Vapid keys"
	su - mastodon -c 'cd /usr/local/www/mastodon && RAILS_ENV=production /usr/local/bin/bundle exec rake mastodon:webpush:generate_vapid_key > /mnt/mastodon/private/vapid.keys'
	VAPIDPRIVATEKEY=$(grep VAPID_PRIVATE_KEY /mnt/mastodon/private/vapid.keys | awk -F'=' '{print $2}')
	VAPIDPUBLICKEY=$(grep VAPID_PUBLIC_KEY /mnt/mastodon/private/vapid.keys | awk -F'=' '{print $2}')
fi

SCRIPT=$(readlink -f "$0")
TEMPLATEPATH=$(dirname "$SCRIPT")/../templates

# safe(r) separator for sed
# shellcheck disable=SC3003,SC2039
sep=$'\001'

# copy in custom mastodon environment file
< "$TEMPLATEPATH/env.production.in" \
  sed "s${sep}%%domain%%${sep}$DOMAIN${sep}g" | \
  sed "s${sep}%%secretkey%%${sep}$SECRETKEY${sep}g" | \
  sed "s${sep}%%otpsecret%%${sep}$OTPSECRET${sep}g" | \
  sed "s${sep}%%vapidprivatekey%%${sep}$VAPIDPRIVATEKEY${sep}g" | \
  sed "s${sep}%%vapidpublickey%%${sep}$VAPIDPUBLICKEY${sep}g" | \
  sed "s${sep}%%redishost%%${sep}$REDISHOST${sep}g" | \
  sed "s${sep}%%redisport%%${sep}$SETREDISPORT${sep}g" | \
  sed "s${sep}%%dbhost%%${sep}$DBHOST${sep}g" | \
  sed "s${sep}%%dbuser%%${sep}$DBUSER${sep}g" | \
  sed "s${sep}%%dbpass%%${sep}$DBPASS${sep}g" | \
  sed "s${sep}%%dbname%%${sep}$DBNAME${sep}g" | \
  sed "s${sep}%%dbport%%${sep}$SETDBPORT${sep}g" | \
  sed "s${sep}%%mailhost%%${sep}$MAILHOST${sep}g" | \
  sed "s${sep}%%mailport%%${sep}$SETMAILPORT${sep}g" | \
  sed "s${sep}%%mailuser%%${sep}$MAILUSER${sep}g" | \
  sed "s${sep}%%mailpass%%${sep}$MAILPASS${sep}g" | \
  sed "s${sep}%%mailfrom%%${sep}$MAILFROM${sep}g" | \
  sed "s${sep}%%bucket%%${sep}$BUCKETHOST${sep}g" | \
  sed "s${sep}%%s3user%%${sep}$BUCKETUSER${sep}g" | \
  sed "s${sep}%%s3pass%%${sep}$BUCKETPASS${sep}g" | \
  sed "s${sep}%%region%%${sep}$BUCKETREGION${sep}g" | \
  sed "s${sep}%%aliashost%%${sep}$BUCKETALIAS${sep}g" \
  > /usr/local/www/mastodon/.env.production

# set permissions on the file
chown mastodon:mastodon /usr/local/www/mastodon/.env.production

# remote command database check
dbcheck=$(PGPASSWORD="$DBPASS" /usr/local/bin/psql -h "$DBHOST" -p "$DBPORT" -U "$DBUSER" -lqt | grep "$DBNAME")
if [ -z "$dbcheck" ]; then
	echo "Setting up a new database"
	su - mastodon -c 'cd /usr/local/www/mastodon && RAILS_ENV=production SAFETY_ASSURED=1 /usr/local/bin/bundle exec rails db:setup'
else
	echo "Database $DBNAME already exists on $DBHOST, no need to create it."
fi

# precompile assets
# todo: we only want to do this if it hasn't already been done!
echo "Precompiling assets as mastodon user"
su - mastodon -c 'cd /usr/local/www/mastodon && RAILS_ENV=production /usr/local/bin/bundle exec rails assets:precompile'

# copy over RC scripts and set executable permissions
echo "Copying over RC scripts"
cp -f "$TEMPLATEPATH/rc.mastodon_sidekiq.in" /usr/local/etc/rc.d/mastodon_sidekiq
chmod +x /usr/local/etc/rc.d/mastodon_sidekiq

cp -f "$TEMPLATEPATH/rc.mastodon_streaming.in" /usr/local/etc/rc.d/mastodon_streaming
chmod +x /usr/local/etc/rc.d/mastodon_streaming

cp -f "$TEMPLATEPATH/rc.mastodon_web.in" /usr/local/etc/rc.d/mastodon_web
chmod +x /usr/local/etc/rc.d/mastodon_web

# enable services
echo "Enabling mastodon services"
service mastodon_sidekiq enable || true
service mastodon_streaming enable || true
service mastodon_web enable || true

# to-do
# add crontab entries
# bundle exec rake mastodon:media:remove_remote