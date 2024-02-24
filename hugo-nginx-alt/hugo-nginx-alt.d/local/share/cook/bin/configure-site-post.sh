#!/bin/sh

# shellcheck disable=SC1091
if [ -e /root/.env.cook ]; then
    . /root/.env.cook
fi

set -e
# shellcheck disable=SC3040
set -o pipefail

export PATH=/usr/local/bin:$PATH

# set permissions so jenkins user can write files from jenkins image
chmod 777 "/mnt/$SITENAME"
chmod g+s "/mnt/$SITENAME"
chmod 777 "/mnt/$SITENAME/$CUSTOMDIR"
chmod g+s "/mnt/$SITENAME/$CUSTOMDIR"
chmod 777 "/mnt/$SITENAME/content"
chmod g+s "/mnt/$SITENAME/content"
chmod 777 "/mnt/$SITENAME/content/blog"
chmod g+s "/mnt/$SITENAME/content/blog"
chmod 777 "/mnt/$SITENAME/content/micro"
chmod g+s "/mnt/$SITENAME/content/micro"
chmod 777 "/mnt/$SITENAME/static"
chmod g+s "/mnt/$SITENAME/static"

# link in /usr/local/www/SITENAME to /root/SITENAME
ln -s "/mnt/$SITENAME/public" "/usr/local/www/$SITENAME"
chown -R www:www "/mnt/$SITENAME"

# setup git
cd "/mnt/$SITENAME"
# git init complains about dubious ownership and gives an error. whitelist the directory
/usr/local/bin/git config --global --add safe.directory "/mnt/$SITENAME" || true
/usr/local/bin/git init || true
/usr/local/bin/git config --replace-all user.email "$GITEMAIL" || true
/usr/local/bin/git config --replace-all user.name "$GITUSER" || true

# add content as submodule
if [ -n "$CONTENTSRC" ]; then
	/usr/local/bin/git submodule add "$CONTENTSRC" .customcontent || true
	/usr/local/bin/git config -f .gitmodules submodule.customcontent.update merge
fi

# copy custom content if exists
if [ -n "$CONTENTSRC" ]; then
	cp -Rf .customcontent/content/ content/
	cp -Rf .customcontent/static/ static/
fi

# add theme as submodule
/usr/local/bin/git submodule add "$THEMESRC" themes/"$THEMENAME" || true
sh -c "cd themes; /usr/local/bin/git config -f .gitmodules submodule.$THEMENAME.update merge"

# shellcheck disable=SC2035
/usr/local/bin/git add -v *

# copy across site icons and css
# shellcheck disable=SC2035
if [ -d "/mnt/$SITENAME/themes/$THEMENAME/static/" ] && [ -d "/mnt/$SITENAME/static/" ]; then
    cp -Rr "/mnt/$SITENAME/themes/$THEMENAME/static/" "/mnt/$SITENAME/static/"
else
    echo "There is an error with /mnt/$SITENAME/themes/$THEMENAME/static/ or /mnt/$SITENAME/static/"
    exit 1
fi