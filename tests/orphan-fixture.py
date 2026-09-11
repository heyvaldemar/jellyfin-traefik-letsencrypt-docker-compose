#!/usr/bin/env python3
"""Database side of the orphan-cleanup test: seeding and counting.

Runs in the `orphans` service, which already has the library database mounted.
The tool under test deletes from tables the schema does not cascade, and a real
library only fills those in once somebody has generated trickplay images or set
a per-item sort order. So the test puts rows there itself, for a doomed item and
for a healthy one, and then checks that exactly one of the two lost them.
"""
import sqlite3
import sys

DB = "/config/data/jellyfin.db"
# The four the tool deletes by hand, plus one the schema cascades, so the test
# measures both halves of the work.
TABLES = ("TrickplayInfos", "MediaSegments", "ItemDisplayPreferences",
          "CustomItemDisplayPreferences", "Chapters")


def ids(db, like):
    return [r[0] for r in db.execute(
        "SELECT Id FROM BaseItems WHERE Path LIKE ?", (like,))]


def seed(db):
    user = db.execute("SELECT Id FROM Users LIMIT 1").fetchone()[0]
    doomed, healthy = ids(db, "/media/Shows%"), ids(db, "/media/Movies/%")
    if not doomed or not healthy:
        sys.exit("fixture: expected rows under both library roots, got %d and %d"
                 % (len(doomed), len(healthy)))
    for tag, group in (("d", doomed), ("h", healthy)):
        for item in group:
            db.execute("INSERT INTO TrickplayInfos VALUES (?,320,180,10,10,100,10000,500)",
                       (item,))
            db.execute("INSERT INTO MediaSegments VALUES (?,10,?,'test',0,1)",
                       (tag + item, item))
            db.execute("INSERT INTO ItemDisplayPreferences "
                       "(UserId,ItemId,Client,ViewType,RememberIndexing,"
                       "RememberSorting,SortBy,SortOrder) VALUES (?,?,'test',0,0,0,'Name',0)",
                       (user, item))
            db.execute("INSERT INTO CustomItemDisplayPreferences "
                       "(Client,ItemId,Key,UserId,Value) VALUES ('test',?,'k',?,'v')",
                       (item, user))
            db.execute("INSERT INTO Chapters (ItemId,ChapterIndex,StartPositionTicks) "
                       "VALUES (?,0,0)", (item,))
    db.commit()
    print("seeded=%d" % (len(doomed) + len(healthy)))


def counts(db):
    """One line of key=value the shell can read without parsing prose."""
    out = {
        "shows": len(ids(db, "/media/Shows%")),
        "movies": len(ids(db, "/media/Movies/%")),
    }
    dangling = 0
    for table in TABLES:
        n = db.execute(
            'SELECT count(*) FROM "%s" t LEFT JOIN BaseItems b ON b.Id = t.ItemId '
            "WHERE b.Id IS NULL" % table).fetchone()[0]
        out[table.lower()] = db.execute('SELECT count(*) FROM "%s"' % table).fetchone()[0]
        dangling += n
    out["dangling"] = dangling
    print(" ".join("%s=%s" % kv for kv in sorted(out.items())))


def main():
    what = sys.argv[1]
    path = sys.argv[2] if len(sys.argv) > 2 else DB
    if what == "seed":
        seed(sqlite3.connect(path))
    elif what == "counts":
        counts(sqlite3.connect("file:%s?mode=ro" % path, uri=True))
    else:
        sys.exit("usage: orphan-fixture.py seed|counts [db]")


if __name__ == "__main__":
    main()
