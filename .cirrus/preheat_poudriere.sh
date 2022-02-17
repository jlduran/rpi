#!/bin/sh

# Pre-heat Poudriere
#
# Download pre-built packages to avoid CI timeouts and speed up the process.

PREHEAT_FREEBSD_VERSION="13"
PREHEAT_ARCH="aarch64"
PREHEAT_POUDRIERE_JAILNAME="rpi"
PREHEAT_POUDRIERE_PTNAME="quarterly"
PREHEAT_PYTHON_SUFFIX="py38"

full_pkglist="$(mktemp pkglist.XXXXXX)"

_preheat_add_pkg_to_full_pkglist()
{
	_origin="$1"

	echo "$_origin" >> "$full_pkglist"
}

_preheat_process_deps()
{
	_origin="$1"

	## fetch each origin from deps
	for _origin_dep in $(_preheat_origin_get_deps_origin "$_origin"); do
		if [ -z "$_origin_dep" ]; then
			continue
		fi

		_preheat_add_pkg_to_full_pkglist "$_origin_dep"
		_preheat_process_deps "$_origin_dep"
	done
}

_preheat_fetch_packagesite()
{
	fetch http://pkg.freebsd.org/FreeBSD:${PREHEAT_FREEBSD_VERSION}:${PREHEAT_ARCH}/${PREHEAT_POUDRIERE_PTNAME}/packagesite.txz
	tar -zxf packagesite.txz packagesite.yaml
}

_preheat_fetch_pkg()
{
	_origin="$1"

	_path="$(_preheat_origin_get_path "$_origin")"
	fetch -o /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path}" \
	    http://pkg.freebsd.org/FreeBSD:${PREHEAT_FREEBSD_VERSION}:${PREHEAT_ARCH}/${PREHEAT_POUDRIERE_PTNAME}/"${_path}"

	_path_txz="${_path%%.pkg}.txz"
	ln -fs /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path}" \
	    /usr/local/poudriere/data/packages/${PREHEAT_POUDRIERE_JAILNAME}-${PREHEAT_POUDRIERE_PTNAME}/"${_path_txz}"
}

_preheat_origin_get_deps_origin()
{
	_origin="$1"
	_origin="$(_preheat_fix_origin "$_origin")"

	_name="$(_preheat_get_name "$_origin")"

	jq --arg origin "$_origin" --arg name "$_name" 'select(.origin == $origin) | select(.name == $name) | .deps | .[]? | .origin' packagesite.yaml | tr -d '"'
}

_preheat_origin_get_path()
{
	_origin="$1"

	_name="$(_preheat_get_name "$_origin")"
	_origin="$(_preheat_fix_origin "$_origin")"

	jq --arg origin "$_origin" --arg name "$_name" 'select(.origin == $origin) | select(.name == $name) | .path' packagesite.yaml | tr -d '"'
}

_preheat_get_name()
{
	_origin="$1"

	echo "${_origin##*/}" | sed -e "s/py-/${PREHEAT_PYTHON_SUFFIX}-/g" -e "s/\@/-/g"
}

_preheat_fix_origin()
{
	_origin="$1"

	echo "${_origin}" | sed -e "s/\@.*//g"
}

# Pre-heat
#
## bootstrap pkg
## XXX pre-heat this as well
_preheat_fetch_packagesite

echo "ports-mgmt/pkg" > pkglist.bootstrap
poudriere bulk -j ${PREHEAT_POUDRIERE_JAILNAME} -p ${PREHEAT_POUDRIERE_PTNAME} -f pkglist.bootstrap

## build the full package list from pkglist
echo "Building full package list.."
while read -r _origin; do
	_preheat_add_pkg_to_full_pkglist "$_origin"
	_preheat_process_deps "$_origin"
done < pkglist

## fetch each pkg from pkglist
echo "Fetching full package list.."
for _origin in $(sort -u "$full_pkglist"); do
	_preheat_fetch_pkg "$_origin"
done

## cleanup
## XXX trap this
rm -f "$full_pkglist" pkglist.bootstrap packagesite.txz packagesite.yaml
