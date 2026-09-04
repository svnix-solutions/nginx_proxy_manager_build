#!/bin/sh
# Snapshot Nginx Proxy Manager's /data volume to a backup target.
#
# NPM keeps its state in SQLite plus a handful of files that are NOT in the
# database -- keys.json (JWT signing keys), access lists, custom certificates.
# So the volume is what needs backing up, not just the database.
#
# The database is snapshotted with SQLite's online backup API rather than
# copied. A plain cp of a live SQLite file can capture a torn write and
# produce an archive that restores into a corrupt database.
#
# Runs on alpine because the NPM image ships no sqlite3 binary.

set -eu
set -o pipefail

DEST="${BACKUP_DEST:-/backup}"
SRC="${BACKUP_SRC:-/data}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
SENTINEL="$DEST/.npmbackup-target"
STAGE=/tmp/npm-stage

if [ ! -f "$SENTINEL" ]; then
  echo "FATAL: $SENTINEL is missing." >&2
  echo "The NAS is almost certainly not mounted at $DEST. Refusing to write" >&2
  echo "backups to what is probably the node's local disk." >&2
  exit 1
fi

command -v sqlite3 >/dev/null || { echo "FATAL: sqlite3 unavailable." >&2; exit 1; }

TS="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$DEST/npm-data-${TS}.tar.gz"
TMP="${OUT}.partial"

echo "==> staging $SRC"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# Logs are noise and regenerate; everything else is state worth keeping.
tar -cf - -C "$SRC" --exclude=./logs . | tar -xf - -C "$STAGE"

if [ -f "$SRC/database.sqlite" ]; then
  echo "==> consistent sqlite snapshot"
  rm -f "$STAGE/database.sqlite"
  # .backup uses SQLite's online backup API: safe against concurrent writers.
  sqlite3 "$SRC/database.sqlite" ".backup '$STAGE/database.sqlite'"
  sqlite3 "$STAGE/database.sqlite" "pragma integrity_check;" | head -1
else
  echo "==> no database.sqlite found (external database in use?)"
fi

echo "==> archiving"
tar -czf "$TMP" -C "$STAGE" .

echo "==> verifying archive"
gzip -t "$TMP"
tar -tzf "$TMP" >/dev/null

mv "$TMP" "$OUT"
rm -rf "$STAGE"
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))"

echo "==> pruning archives older than ${RETENTION_DAYS} days"
find "$DEST" -maxdepth 1 -type f -name 'npm-data-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true
find "$DEST" -maxdepth 1 -type f -name '*.partial' -mtime +1 -print -delete || true

echo "==> archives on the target:"
ls -lh "$DEST"/npm-data-*.tar.gz 2>/dev/null | tail -20 || echo "(none)"
echo "==> free space:"
df -h "$DEST" | tail -1
