#!/usr/bin/env bash
# Start the hindsight postgres database
PGDATA=/var/lib/postgresql/hindsight-data
/usr/lib/postgresql/18/bin/pg_ctl -D "$PGDATA" -l /tmp/hindsight-db.log -o "-p 5433" status 2>/dev/null || \
/usr/lib/postgresql/18/bin/pg_ctl -D "$PGDATA" -l /tmp/hindsight-db.log -o "-p 5433" -w start
