### iMARKET Datenbank Anonymisierung

Dieses Script ersetzt personenbezogene Daten in plaintext-dumps durch Müll.


### Beispielaufruf:

```
ssh root@ber41.imarket.priv.nmop.de

[root@ber41 ~]# su - postgres
[postgres@ber41 ~]$ cd /srv/postgresql/AnonDump

[postgres@ber41 AnonDump]$ DB=imarket_ber40
[postgres@ber41 AnonDump]$ SCHEMA=imarket_ber40
[postgres@ber41 AnonDump]$ ./anonymize.sh $DB $SCHEMA zstd
[OK] fertig in 1342 Sekunden, siehe Datei 'files/dump_anonymized.sql.zstd' (6196 mb)"

```


### Beispiel manuell in Einzelschritten

```
ssh root@ber41.imarket.priv.nmop.de

[root@ber41 ~]# su - postgres
[postgres@ber41 ~]$ cd /srv/postgresql/AnonDump

# Plaintext-Dump dauert ca. 7 Minuten
[postgres@ber41 AnonDump]$ DB=imarket_ber40
[postgres@ber41 AnonDump]$ SCHEMA=imarket_ber40
[postgres@ber41 AnonDump]$ OUT=files/dump.sql
[postgres@ber41 AnonDump]$ pg_dump $DB --schema=$SCHEMA --format=plain --verbose >$OUT

# Kontrolle:
[postgres@ber41 AnonDump]$ ls -lh $OUT
-rw-r--r--. 1 postgres postgres 64G Mar  4 11:21 files/dump.sql
[postgres@ber41 AnonDump]$ grep -n -m1 Kaufmann $OUT
1112871:1       1       Richard & Annelie’s     Kaufmann+Meiermann und Familie  ...
^^^^^^^ Zeilennummer

# Anonymisierung dauert ca. 13 Minuten
[postgres@ber41 AnonDump]$ OUT=files/dump_anon.sql
[postgres@ber41 AnonDump]$ jq . files/anon_data.json && python3 main.py >$OUT

# Kontrolle Dateigrösse und der gleichen Zeile wie oben:
[postgres@ber41 AnonDump]$ ls -lh $OUT
-rw-r--r--. 1 postgres postgres 64G Mar  4 11:37 files/dump_anon.sql

[postgres@ber41 AnonDump]$ sed '1112871q;d' $OUT
1#1#1234#1234#1234#1234#1234#1234#1234#1234#1234#1234#12341#2#1234#1234#1234#1234#...
```

### Einrichtung API Client 

* add new User: anonymizer over hostname/portal/portal/user-roles
* use for password gen: https://www.datenschutz.org/passwort-generator/ 
* user for email: lrutz@novomind.com
* after add user go in to database:
SQL
```
insert into auth_user_perm_rel values ((select id from auth_user where "name" = 'imarket'), (select id from auth_permission where "name" = 'GET_SECTIONS'), 0);
```
if not null constraint use for no specific brand section the default anon_data.json else talk with pl

set the hostname and user credentials in the config file
```
[Client]
client_password = 2piopn463inp437
client_hostname = blabla01.novomind.com
```

### Wie schlimm war das früher alles?

https://opswiki.novomind.com/wiki/index.php/Bbittorf#PostgreSQL_dump_ziehen_und_anonymisieren


### ToDo

* howto einspielen? OPS-295485
* psql --dbname="$DB" -c "drop schema $SCHEMA cascade;"
* zcat "$FILE" | psql "$DB"
* psql -h ${host} -p ${port} -U "${user}" --dbname "${base}" -f "${dump}"
* alter schema imarket_up42 rename to imarket_up42tmp;
* alter schema imarket_up40 rename to imarket_up42;
* GRANT ALL PRIVILEGES ON DATABASE "imarket_up42" to imarket_up42;
* GRANT ALL ON SCHEMA imarket_up42 TO imarket_up42;
* GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA imarket_up42 to imarket_up42;
