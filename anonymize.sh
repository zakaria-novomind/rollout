#!/bin/sh
# shellcheck shell=dash
#
# HINT: deploy to any host like:
#       cd /GIT/imarket-datenbank-anonymisierung
#       ./anonymize.sh --deploy up40.imarket.priv.nmop.de

for WORD in "$@"; do {
	case "$WORD" in
		'--'[a-z]*) ARGS="$ARGS $WORD" ;;	# --switches for has_arg()
		*) test -z "$DBNAME" && DBNAME="$WORD"	# arguments without -- become DBNAME + SCHEMA
		   test -z "$SCHEMA" && SCHEMA="$WORD"
	esac
} done

usage_and_die()
{
	echo "Usage: $0 <dbname> <schema> [--zstd] [--keepdump] [--dumponly] [--noautocleanup]"
	echo
	echo " e.g.: $0 imarket_ber40 imarket_ber40"

	exit 1
}

PASSFILE='/home/imarket/.pgpass'
NEEDED_USER='postgres'
LOWPRIO='nice -n 10 ionice -c2 -n7'
BASE="$( basename -- "$0" )"

# on APP-Server we have .pgpass, so use that:
if [ -f "$PASSFILE" ]; then
	[ -z "$DBNAME" ] && [ -z "$SCHEMA" ] && {
		NEEDED_USER='imarket'

		# format: hostname:port:database:username:password
		# ignore comment-lines (starting with #)
		# e.g. ber41.imarket.priv.nmop.de:5432:imarket_ber40:imarket_ber40:XXX
		while read -r LINE || test "$LINE"; do {
			case "$LINE" in '#'*) ;; *)
				set -f
				# shellcheck disable=SC2046
				set +f -- $( echo "$LINE" | tr ':' ' ' )

				DBNAME="$3"
				SCHEMA="$4"	# for imarket: same as username
				export PGDATESTYLE='ISO,DMY'
				export PGDATABASE="$DBNAME"
				export PGHOST="$1"
				export PGUSER="$4"
				export PGPORT="$2" && break
			esac
		} done <"$PASSFILE"
	}
else
	[ -d .git ] || \
	echo "[HINT] can not read '$PASSFILE' - so the script should run as user '$NEEDED_USER'"
fi

has_arg()
{
	local arg wish="$1"	# e.g. gzip

	for arg in $ARGS; do {
		case "$arg" in "--$wish") return 0 ;; esac
	} done

	false
}

log()		# print to STDERR, e.g.: anonymize.sh|Feb 06 16:35:04|foo bar baz
{
	>&2 printf '%s\n' "$BASE|$( LC_ALL=C date '+%b %d %H:%M:%S' )|$1"
}

check_command()
{
	local package="$1"

	case "$package" in
		'pip3:'*)
			pip3 list 2>&1 | grep -q ^"${package#*:}" && return 0
		;;
		*)
			command -v "$package" >/dev/null && return 0
		;;
	esac

	log "command '$package' missing, please install"
	false
}

check_userinput()	# TODO: enforce screen?
{
	check_command 'psql' || return 1

	check_dbname || return 1
	check_schema || return 1
	check_user   || return 1

	if has_arg 'zstd'; then
		check_command 'zstd' || return 1
	else
		check_command 'gzip' || return 1
	fi

	check_command 'stat'    || return 1
	check_command 'jq'	|| return 1
	check_command 'nice'	|| return 1
	check_command 'find'	|| return 1
	check_command 'ionice'	|| return 1
	check_command 'pg_dump'	|| return 1
	check_command 'python3' || return 1
	check_command 'truncate' || return 1
	check_command 'pip3'	|| return 1
	check_command 'pip3:dataclasses' || return 1
}

check_dbname()
{
	test -n "$DBNAME" && return 0
	log "no database name given, see list:"

	# shellcheck disable=SC2005
	echo "$( psql -c "\list+" )"

	false
}

check_schema()
{
	test -n "$SCHEMA" && return 0
	log "no schema name given, see list:"

	# shellcheck disable=SC2005
	echo "$( psql -c "\c $DBNAME" -c "\dn+" )"

	false
}

check_user()
{
	test "$( id -nu )" = "$NEEDED_USER" && return 0
	log "wrong user, must be: $NEEDED_USER"
	false
}

check_connection()
{
	if psql -c "\q"; then
		log "[OK] DB-connection works"
	else
		log "[ERROR] connection to DB failed, check if ~/.pgpass has chmod 0600"
		false
	fi
}

filesize_bytes()
{
	stat --printf="%s" "$1"
}

filesize_mb()
{
	if SIZE_BYTES="$( filesize_bytes "$1" )"; then
		echo $(( SIZE_BYTES / 1024 / 1024 ))
	else
		echo 0
	fi
}

autocleanup()	# DCP-6543 - keep most recent 3 anondumps
{
	local dir="$1"
	local pattern="$2"

	local keep=3
	local filename

	# https://superuser.com/questions/294161/unix-linux-find-and-sort-by-date-modified
	#
	find "$dir" -type f -name "${pattern}*" -printf "%T@ %p\n" | \
	 sort -rn | \
	  tail -n "+$keep" | \
	   cut -d' ' -f2 | \
	    while read -r filename; do {
		log "[OK] autocleanup: $filename"
		rm -f "$filename"
	    } done
}

list_ignored_tables()	# e.g. OPS-317840 | see --exclude-table=...
{
	{
		psql -c "\t" -c "\dt $SCHEMA.tmp*"   2>/dev/null
		psql -c "\t" -c "\dt $SCHEMA.*.tmp*" 2>/dev/null
	} | grep -v 'Tuples only is on' | sort -u
}

has_arg 'deploy' && {
	DEST_HOSTNAME="$DBNAME"
	DEST_DIR='/srv/postgresql/AnonDump'
	TO="root@$DEST_HOSTNAME:$DEST_DIR/"
	RC=0
	log "[OK] will copy all scripts to host '$DEST_HOSTNAME' at '$DEST_DIR'"

	if [ -d '.git' ]; then
		scp "$0" main.py README.md "$TO" || {
			RC=$?
			log "[ERROR] scp to $TO"
		}
	else
		RC=66
	fi

	exit "$RC"
}

check_userinput || usage_and_die
check_connection || exit 77

[ -d "files" ] || {
	log "[ERROR] missing directory 'files' in working dir '$PWD'"
	log "        maybe start script with:"
	log "        cd '$( dirname -- "$0" )' && $( basename -- "$0" ) ..."
	exit 1
}

T1="$( date +%s )"
DUMP_PLAIN="files/dump.sql.gz"

log "[OK] start auf host '$( hostname -f )'"

# e.g. dump_anonymized_imarket_up40_20220317_135435.sql
FORMAT="dump_anonymized_${SCHEMA}_$( date '+%Y%m%d_%H%M%S' ).sql"

if has_arg 'zstd'; then
	METHOD='zstd' && DECOMPRESS='unzstd'
	DUMP_ANON="files/$FORMAT.zstd"
else
	METHOD='gzip' && DECOMPRESS='zcat'
	DUMP_ANON="files/$FORMAT.gz"
fi

log "[OK] jobs laufen mit niedriger cpu- und IO-prio"
log "[OK] erstelle plaintext-dump der Datenbank '$DBNAME', Schema '$SCHEMA' ..."
log "[OK] Zieldatei: '$DUMP_PLAIN'"

list_ignored_tables | while read -r LINE; do {
	log "[OK] these 'tmp' tables are ignored: $LINE"
} done

# we always compress the dump with 'gzip', because 'main.py' has support for reading it:
$LOWPRIO pg_dump "$DBNAME" \
	--schema="$SCHEMA" \
	--encoding=utf-8 \
	--clean \
	--if-exists \
	--exclude-table="*.tmp*" \
	--exclude-table="tmp_*" \
	--format=plain 2>"$DUMP_PLAIN.err" | gzip >"$DUMP_PLAIN" || exit 1

DUMPSIZE="$( filesize_bytes "$DUMP_PLAIN" )"

# more diag on error:
if T2="$( date +%s )" && TDIFF=$(( T2 - T1 )) && [ "$TDIFF" -lt 30 ]; then
	log "[WARNING] very short dumptime - DBNAME: '$DBNAME' SCHEMA: '$SCHEMA'"
	log "[WARNING] NEEDED_USER: '$NEEDED_USER' REAL_USER: '$( whoami )'"
	log "[WARNING] message: '$( grep . "$DUMP_PLAIN.err" || echo 'no error message found' )'"
	log "[WARNING] filesize: $DUMPSIZE bytes - see: '$DUMP_PLAIN'"
	rm -f "$DUMP_PLAIN.err"

	test "$DUMPSIZE" -gt 1024 || {
		log "[ERROR] dump smaller 1 kilobyte"
		exit 1
	}
else
	log "[OK] dump erstellt in $TDIFF seconds: '$DUMP_PLAIN' ($DUMPSIZE bytes)"
fi

[ -s "$DUMP_PLAIN.err" ] && \
	log "[ERROR] message: '$( cat "$DUMP_PLAIN.err" )'"

rm -f "$DUMP_PLAIN.err"

has_arg 'dumponly' && exit 0

log "[OK] anonymisiere und komprimiere ($METHOD) Daten ..."

if $LOWPRIO python3 main.py | $METHOD >"$DUMP_ANON"; then		# TODO: for zstd: --size-hint=...
	if has_arg 'keepdump'; then
		log "[OK] behalte volldump: '$DUMP_PLAIN'"
	else
		rm -f "$DUMP_PLAIN"
	fi

	T2="$( date +%s )" && TDIFF=$(( T2 - T1 ))
	FSIZE_MB="$( filesize_mb "$DUMP_ANON" )"

	log "[OK] ready in $TDIFF seconds, see file:"
	log "    '$PWD/$DUMP_ANON' ($FSIZE_MB mb)"

	if has_arg 'noautocleanup'; then
		log "[OK] autocleanup disabled"
	else
		autocleanup "$PWD" "dump_anonymized_${SCHEMA}_"
	fi

	test "$FSIZE_MB" -gt 0 || {
		log "[ERROR] anondump smaller 1 megabyte: try to debug with --dumponly"
		log "        see file: $PWD/$DUMP_ANON"

		"$DECOMPRESS" "$PWD/$DUMP_ANON" | while read -r LINE; do {
			log "[DEBUG] => '$LINE'"
		} done

		false
	}
else
	log "[ERROR] please check '$DUMP_PLAIN' and/or '$DUMP_ANON'"
	false
fi
