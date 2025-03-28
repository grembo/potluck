# Checklist for updates

## Versioning
```
X.Y.Z / 1.0.1

X = Major version
Y = Minor version
Z = Build updates
```

## Major/minor revisions
Changes to major or minor versions need to be logged in:
* `CHANGELOG.md`
* `nginx-nomad-alt.ini`
* Example job in `README.md`

## Automated build processing
To force a rebuild of the pot image for the potluck site, increment Z of version="x.y.Z" in:
* `nginx-nomad-alt.ini`

## PHP version changes
On PHP version changes, update the socket link `/var/run/php83-fpm.sock` to the new PHP version in files
* `nginx-nomad-alt.d/local/share/cook/templates/nginx.conf`
* `nginx-nomad-alt.d/local/share/cook/templates/www.conf.in`

## Shellcheck
Was `shellcheck` run on all applicable shell files?
