#!/usr/bin/env python3
"""Report, and on request remove, library rows whose file is no longer on disk.

Runs inside the `orphans` service, which mounts the same config volume and the
same media directory as Jellyfin itself. It is never started by `up`; the
jellyfin-drop-orphans.sh script in this repository is what invokes it.

WHERE ORPHANS COME FROM. A library scan removes missing items only in the
folders it can enter. A folder it cannot enter is left alone entirely, and that
is the right call: an unreachable library root is indistinguishable from a
detached disk, and Jellyfin would rather keep a library than erase one because a
NAS was slow to mount. The cost is that a root which goes away for good strands
everything below it. Measured on the pinned version, and reproduced in this
repository's CI: move a library root aside, scan, and the rows underneath it
survive that scan, a restart, and every scan after that. They have to. Nothing
will ever walk that path again.

That is why the tool exists, and it is also why it is careful. Restoring an
older config archive over a library that has moved on produces exactly the same
state, and so does editing JELLYFIN_MEDIA_PATH.

WHY NOT THROUGH THE API. DELETE /Items/{id} removes the row AND THE FILE. For an
orphan there is nothing to delete, which sounds safe until one of the rows
points at a path that exists in a different Unicode normal form. That is a real
case, not a hypothetical: a decomposed "La chevre Extras" recorded in the
database, whose composed twin on disk belongs to a different and perfectly
healthy row. If Jellyfin normalises the path on its way to the delete, it takes
the neighbour's file. Editing the database cannot make that mistake.

THE PATH CHECK IS BYTE FOR BYTE, AND THAT IS THE POINT. It is tempting to be
tolerant here and accept a file that exists in either normal form, the way a
disk report should. Do not. The tolerant check is what declared that decomposed
row healthy and left it in the library. A filesystem is byte-exact: a path
Jellyfin cannot open is broken whether or not something similar sits beside it.
Normalising helps you FIND a folder and lies to you about a RECORDED path.

Usage:  drop-orphans.py [dry|apply]
"""
import os
import sqlite3
import sys
import time

DB = os.environ.get("JELLYFIN_DB", "/config/data/jellyfin.db")
MEDIA = os.environ.get("JELLYFIN_MEDIA_ROOT", "/media").rstrip("/") or "/"
BACKUP_DIR = os.environ.get("JELLYFIN_DB_BACKUP_DIR", "/backups")
# A ceiling, not a policy: raise it deliberately if you really did delete half
# your library. The default refuses to act on a number that looks like an
# accident. See the refusal message below for why the number is the signal.
LIMIT = int(os.environ.get("JELLYFIN_ORPHAN_LIMIT", "50"))

# Tables whose ItemId is a BaseItems.Id but which carry no foreign key, so
# nothing removes their rows for us. Everything else that references an item
# declares ON DELETE CASCADE and is handled by the schema once foreign keys are
# switched on, including BaseItems.ParentId, which takes an item's children.
NO_FOREIGN_KEY = ("CustomItemDisplayPreferences", "ItemDisplayPreferences",
                  "MediaSegments", "TrickplayInfos")

# A column called ItemId is not always a reference to an item. ActivityLogs.ItemId
# is the activity feed, which should keep saying what happened even after the
# item is gone and is usually NULL anyway. DisplayPreferences.ItemId is a
# per-user, per-client view setting that defaults to the all-zero GUID. Deleting
# by ItemId in either table would remove somebody's settings or rewrite history,
# so both are named here rather than left to look like an oversight.
NOT_AN_ITEM_REFERENCE = ("ActivityLogs", "DisplayPreferences")


def cascading_tables(db):
    """Tables SQLite will clear for us, read from the schema rather than a list."""
    found = set()
    for (table,) in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"):
        for fk in db.execute('PRAGMA foreign_key_list("%s")' % table):
            if fk[2] == "BaseItems" and fk[6] == "CASCADE":
                found.add(table)
    return found


def tables_with_item_id(db):
    found = set()
    for (table,) in db.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'"):
        if any(c[1] == "ItemId" for c in db.execute('PRAGMA table_info("%s")' % table)):
            found.add(table)
    return found


def find_orphans(db):
    """Rows under the media root whose path cannot be opened. Byte-exact."""
    out = []
    for item_id, name, typ, path in db.execute(
            "SELECT Id, Name, Type, Path FROM BaseItems WHERE Path LIKE ?",
            (MEDIA + "/%",)):
        if not os.path.exists(path):
            out.append((item_id, str(typ).split(".")[-1], name or "", path))
    return out


def missing_ancestor(path):
    """The highest thing on this path that is not there, the path itself included.

    One missing season folder and one missing mount produce the same flat list
    of file paths, and they call for opposite actions. Naming the folder that
    went away turns forty thousand lines into one, and turns "what is all this?"
    into "that is the disk that did not come up".
    """
    missing = path
    cur = os.path.dirname(path)
    while len(cur) > len(MEDIA):
        if not os.path.exists(cur):
            missing = cur
        cur = os.path.dirname(cur)
    return missing


def report(orphans):
    groups = {}
    for item_id, typ, name, path in orphans:
        groups.setdefault(missing_ancestor(path), []).append((typ, name, path))
    # A group of one whose key is its own path is a file that was deleted while
    # its folder stayed. Anything else is a folder that took rows down with it.
    singles = [g[0] for k, g in groups.items() if len(g) == 1 and g[0][2] == k]
    folders = {k: g for k, g in groups.items() if not (len(g) == 1 and g[0][2] == k)}

    for folder in sorted(folders):
        rows = folders[folder]
        print("  %s is not there - %d row%s at or below it:"
              % (folder, len(rows), "" if len(rows) == 1 else "s"))
        for typ, name, path in sorted(rows, key=lambda r: r[2])[:20]:
            print("      [%s] %s" % (typ, name))
            print("          %s" % path)
        if len(rows) > 20:
            print("      ... and %d more" % (len(rows) - 20))
    if singles:
        print("  files that are gone while their folder is still there:")
        for typ, name, path in sorted(singles, key=lambda r: r[2]):
            print("      [%s] %s" % (typ, name))
            print("          %s" % path)


def check_media_mounted():
    """An empty media root means the mount is missing, not that you deleted everything."""
    if not os.path.isdir(MEDIA):
        sys.exit("  REFUSED: %s is not a directory inside this container.\n"
                 "           Nothing was read. Check JELLYFIN_MEDIA_PATH." % MEDIA)
    if not os.listdir(MEDIA):
        sys.exit("  REFUSED: %s is empty. Every row would look like an orphan.\n"
                 "           Mount the library before cleaning the database." % MEDIA)


def back_up(db_path):
    """sqlite3 .backup, not cp: a live database has a -wal beside it and a plain
    copy of the .db file alone is a database missing its most recent writes."""
    os.makedirs(BACKUP_DIR, exist_ok=True)
    dest = os.path.join(
        BACKUP_DIR,
        "jellyfin-db-before-orphan-drop-%s.db" % time.strftime("%Y-%m-%d_%H-%M-%S"))
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(dest)
    with dst:
        src.backup(dst)
    dst.close()
    src.close()
    return dest


def delete(db, ids):
    db.execute("PRAGMA foreign_keys = ON")
    marks = ",".join("?" * len(ids))
    manual = 0
    present = tables_with_item_id(db)
    for table in NO_FOREIGN_KEY:
        if table not in present:
            continue
        n = db.execute('DELETE FROM "%s" WHERE ItemId IN (%s)' % (table, marks),
                       ids).rowcount
        manual += n
        if n:
            print("  %s: %d" % (table, n))
    # Counted as a difference, not from rowcount. ON DELETE CASCADE also walks
    # BaseItems.ParentId, so deleting a missing folder takes its children with
    # it - and rowcount sees only the rows the statement itself named. It
    # reported 1 for a delete that removed 5.
    before = db.execute("SELECT count(*) FROM BaseItems").fetchone()[0]
    db.execute("DELETE FROM BaseItems WHERE Id IN (%s)" % marks, ids)
    db.commit()
    after = db.execute("SELECT count(*) FROM BaseItems").fetchone()[0]
    return before - after, manual


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "dry"
    if mode not in ("dry", "apply"):
        sys.exit("usage: drop-orphans.py [dry|apply]")
    check_media_mounted()
    if not os.path.exists(DB):
        sys.exit("  the library database is not at %s" % DB)

    db = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)
    known = cascading_tables(db) | set(NO_FOREIGN_KEY) | set(NOT_AN_ITEM_REFERENCE)
    drift = sorted(tables_with_item_id(db) - known - {"BaseItems"})
    orphans = find_orphans(db)
    db.close()

    print("  database: %s" % DB)
    print("  orphans:  %d" % len(orphans))
    if not orphans:
        print("  every library row points at a file that is there.")
        return 0
    report(orphans)

    if drift:
        # Better to say so than to delete from a table nobody has looked at, and
        # better than silently leaving rows behind.
        print("\n  NOTE: this schema has table(s) carrying an ItemId that this tool")
        print("  does not know about: %s" % ", ".join(drift))
        print("  Their rows for these items will be left behind. Worth reporting.")

    if len(orphans) > LIMIT:
        print("\n  REFUSED: %d is more than the limit of %d." % (len(orphans), LIMIT))
        print("  That number is what a disk that did not mount looks like, and it is")
        print("  indistinguishable from real cleanup by reading the database alone.")
        print("  Check the missing folders above against what should be mounted. If")
        print("  they really are gone for good, set JELLYFIN_ORPHAN_LIMIT above %d."
              % len(orphans))
        return 2

    if mode != "apply":
        print("\n  dry run, nothing changed. Pass 'apply' to remove these rows.")
        return 0

    backup = back_up(DB)
    print("\n  database copied to %s" % backup)

    db = sqlite3.connect(DB)
    # Derived again, now that Jellyfin is stopped. Between the report above and
    # this line a file can come back, and deleting from a minute-old list means
    # trusting an unchanging disk that nobody promised.
    fresh = {o[0] for o in find_orphans(db)}
    returned = [o for o in orphans if o[0] not in fresh]
    if returned:
        print("  the file came back for %d of them; those are kept:" % len(returned))
        for _, _, name, path in returned[:5]:
            print("      %s" % path)
    ids = [o[0] for o in orphans if o[0] in fresh]
    if not ids:
        print("  nothing left to remove.")
        return 0

    gone, manual = delete(db, ids)
    left = db.execute(
        "SELECT count(*) FROM BaseItems WHERE Id IN (%s)" % ",".join("?" * len(ids)),
        ids).fetchone()[0]
    db.close()
    print("  removed %d item row%s, %d of them listed above"
          % (gone, "" if gone == 1 else "s", len(ids)))
    if gone > len(ids):
        print("  the extra %d were children the schema removed with their parent"
              % (gone - len(ids)))
    print("  and %d row%s in the tables the schema does not cascade"
          % (manual, "" if manual == 1 else "s"))
    if left:
        print("  %d of them are still there - the edit did not take" % left)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
