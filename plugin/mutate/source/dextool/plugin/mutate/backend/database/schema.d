/**
Copyright: Copyright (c) 2018, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

This module contains the schema to initialize the database.

To ensure that the upgrade path for a database always work a database is
created at the "lowest supported" and upgraded to the latest.

# How to add schema change

1. add an upgrade function, upgradeVX.

The function makeUpgradeTable will then automatically find it and use it. X
 **must** be the version upgrading FROM.

# Style
A database schema upgrade path shall have a comment stating what date it was added.
Each change to the database schema must have an equal upgrade added.

# Sqlite3
From the sqlite3 manual $(LINK https://www.sqlite.org/datatype3.html):
Each value stored in an SQLite database (or manipulated by the database
engine) has one of the following storage classes:

NULL. The value is a NULL value.

INTEGER. The value is a signed integer, stored in 1, 2, 3, 4, 6, or 8 bytes
depending on the magnitude of the value.

REAL. The value is a floating point value, stored as an 8-byte IEEE floating
point number.

TEXT. The value is a text string, stored using the database encoding (UTF-8,
UTF-16BE or UTF-16LE).

BLOB. The value is a blob of data, stored exactly as it was input.

A storage class is more general than a datatype. The INTEGER storage class, for
example, includes 6 different integer datatypes of different lengths.  This
makes a difference on disk. But as soon as INTEGER values are read off of disk
and into memory for processing, they are converted to the most general datatype
(8-byte signed integer). And so for the most part, "storage class" is
indistinguishable from "datatype" and the two terms can be used
interchangeably.
*/
module dextool.plugin.mutate.backend.database.schema;

import logger = std.experimental.logger;
import std.array : array, empty;
import std.datetime : SysTime;
import std.exception : collectException;
import std.format : format;

import dextool.plugin.mutate.backend.type : Language;

import d2sqlite3 : SqlDatabase = Database;
import miniorm : Miniorm, TableName, buildSchema, ColumnParam, TableForeignKey,
    TableConstraint, TablePrimaryKey, KeyRef, KeyParam, ColumnName, delete_, insert, select;

immutable allTestCaseTable = "all_test_case";
immutable filesTable = "files";
immutable killedTestCaseTable = "killed_test_case";
immutable markedMutantTable = "marked_mutant";
immutable mutantTimeoutCtxTable = "mutant_timeout_ctx";
immutable mutantTimeoutWorklistTable = "mutant_timeout_worklist";
immutable mutationPointTable = "mutation_point";
immutable mutationStatusTable = "mutation_status";
immutable mutationTable = "mutation";
immutable nomutDataTable = "nomut_data";
immutable nomutTable = "nomut";
immutable rawSrcMetadataTable = "raw_src_metadata";
immutable schemaVersionTable = "schema_version";
immutable srcMetadataTable = "src_metadata";
immutable schemataMutantTable = "schemata_mutant";
immutable schemataTable = "schemata";
immutable schemataFragmentTable = "schemata_fragment";
immutable schemataUsedTable = "schemata_used";

private immutable invalidSchemataTable = "invalid_schemata";
private immutable schemataWorkListTable = "schemata_worklist";
private immutable testCaseTableV1 = "test_case";

/** Initialize or open an existing database.
 *
 * Params:
 *  p = path where to initialize a new database or open an existing
 *
 * Returns: an open sqlite3 database object.
 */
Miniorm initializeDB(const string p) @trusted
in {
    assert(p.length != 0);
}
do {
    import std.parallelism : totalCPUs;
    import d2sqlite3 : SQLITE_OPEN_CREATE, SQLITE_OPEN_READWRITE;

    static void setPragmas(ref SqlDatabase db) {
        // dfmt off
        auto pragmas = [
            // required for foreign keys with cascade to work
            "PRAGMA foreign_keys=ON;",
            // use optimal number of worker threads. Should improve performance
            // a bit without having an adverse effect.
            // This should probably be user configurable.
            format!"PRAGMA threads = %s;"(totalCPUs),
        ];
        // dfmt on

        foreach (p; pragmas) {
            db.run(p);
        }
    }

    SqlDatabase sqliteDb;

    try {
        sqliteDb = SqlDatabase(p, SQLITE_OPEN_READWRITE);
    } catch (Exception e) {
        logger.trace(e.msg);
        logger.trace("Initializing a new sqlite3 database");
        sqliteDb = SqlDatabase(p, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE);
    }

    auto db = Miniorm(sqliteDb);

    // TODO: remove all key off in upgrade schemas.
    db.run("PRAGMA foreign_keys=OFF;");
    try {
        upgrade(db);
    } catch (Exception e) {
        logger.error("Unable to upgrade the database to the latest schema");
        throw e;
    }
    setPragmas(sqliteDb);

    return db;
}

package:

// metadata about mutants that occur on a line extracted from the source code.
// It is intended to further refined.
// nomut = if the line should ignore mutants.
// tag = a user defined tag for a NOMUT.
// comment = a user defined comment.
@TableName(rawSrcMetadataTable)
@TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
@TableConstraint("unique_line_in_file UNIQUE (file_id, line)")
struct RawSrcMetadata {
    long id;

    @ColumnName("file_id")
    long fileId;

    @ColumnParam("")
    uint line;

    @ColumnParam("")
    long nomut;

    @ColumnParam("")
    string tag;

    @ColumnParam("")
    string comment;
}

@TableName(srcMetadataTable)
@TableForeignKey("mut_id", KeyRef("mutation(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("st_id", KeyRef("mutation_status(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("mp_id", KeyRef("mutation_point(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
struct SrcMetadataTable {
    @ColumnName("mut_id")
    long mutationId;

    @ColumnName("st_id")
    long mutationStatusId;

    @ColumnName("mp_id")
    long mutationPointId;

    @ColumnName("file_id")
    long fileId;

    @ColumnName("nomut")
    long nomutCount;
}

// Reconstruct the nomut table in Miniorm.
@TableName(nomutTable)
@TableForeignKey("mp_id", KeyRef("mutation_point(id)"), KeyParam("ON DELETE CASCADE"))
struct NomutTbl {
    @ColumnName("mp_id")
    long mutationPointId;

    long line;

    /// != 0 when a nomut is tagged on the line.
    long status;
}

@TableName(nomutDataTable)
@TableForeignKey("mut_id", KeyRef("mutation(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("mp_id", KeyRef("mutation_point(id)"), KeyParam("ON DELETE CASCADE"))
struct NomutDataTbl {
    @ColumnName("mut_id")
    long mutationId;

    @ColumnName("mp_id")
    long mutationPointId;

    long line;

    @ColumnParam("")
    string tag;

    @ColumnParam("")
    string comment;
}

@TableName(schemaVersionTable)
struct VersionTbl {
    @ColumnName("version")
    long version_;
}

/// checksum is 128bit. Using a integer to better represent and search for them
/// in queries.
@TableName(filesTable)
@TableConstraint("unique_ UNIQUE (path)")
struct FilesTbl {
    long id;

    @ColumnParam("")
    string path;

    long checksum0;
    long checksum1;
    Language lang;
}

/// there shall never exist two mutations points for the same file+offset.
@TableName(mutationPointTable)
@TableConstraint("file_offset UNIQUE (file_id, offset_begin, offset_end)")
@TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
struct MutationPointTbl {
    long id;
    long file_id;
    uint offset_begin;
    uint offset_end;

    /// line start from zero
    @ColumnParam("")
    uint line;
    @ColumnParam("")
    uint column;

    @ColumnParam("")
    uint line_end;

    @ColumnParam("")
    uint column_end;
}

@TableName(mutationTable)
@TableForeignKey("mp_id", KeyRef("mutation_point(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("st_id", KeyRef("mutation_status(id)"))
@TableConstraint("unique_ UNIQUE (mp_id, kind)")
struct MutationTbl {
    long id;

    long mp_id;

    @ColumnParam("")
    long st_id;

    long kind;
}

/**
 * This could use an intermediate adapter table to normalise the test_case data
 * but I chose not to do that because it makes it harder to add test cases and
 * do a cleanup.
 */
@TableName(killedTestCaseTable)
@TableForeignKey("st_id", KeyRef("mutation_status(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("tc_id", KeyRef("all_test_case(id)"), KeyParam("ON DELETE CASCADE"))
struct TestCaseKilledTbl {
    long id;

    @ColumnName("st_id")
    long mutationStatusId;
    @ColumnName("tc_id")
    long testCaseId;

    // location is a filesystem location or other suitable helper for a user to
    // locate the test.
    @ColumnParam("")
    string location;
}

/**
 * Track all test cases that has been found by the test suite output analyzer.
 * Useful to find test cases that has never killed any mutant.
 * name should match test_case_killed_v2_tbl
 * TODO: name should be the primary key. on a conflict a counter should be updated.
 */
@TableName(allTestCaseTable)
struct AllTestCaseTbl {
    long id;

    @ColumnParam("")
    string name;
}

/**
 * the status of a mutant. if it is killed or otherwise.
 * multiple mutation operators can result in the same change of the source
 * code. By coupling the mutant status to the checksum of the source code
 * change it means that two mutations that have the same checksum will
 * "cooperate".
 * TODO: change the checksum to being NOT NULL in the future. Can't for now
 * when migrating to schema version 5->6.
 * time = ms spent on verifying the mutant
 * timestamp = is when the status where last updated. Seconds at UTC+0.
 * added_ts = when the mutant where added to the system. UTC+0.
 * test_cnt = nr of times the mutant has been tested without being killed.
 */
@TableName(mutationStatusTable)
@TableConstraint("checksum UNIQUE (checksum0, checksum1)")
struct MutationStatusTbl {
    long id;
    long status;

    @ColumnParam("")
    long time;

    @ColumnName("test_cnt")
    long testCnt;

    @ColumnParam("")
    @ColumnName("update_ts")
    SysTime updated;

    @ColumnParam("")
    @ColumnName("added_ts")
    SysTime added;

    long checksum0;
    long checksum1;
}

@TableName(mutantTimeoutWorklistTable)
@TableForeignKey("id", KeyRef("mutation_status(id)"), KeyParam("ON DELETE CASCADE"))
struct MutantTimeoutWorklistTbl {
    long id;
}

/** The defaults for the schema is the state that the state machine start in.
 *
 * This mean that if there are nothing in the database then `.init` is the correct starting point.
 */
@TableName(mutantTimeoutCtxTable)
struct MutantTimeoutCtxTbl {
    /// What iteration the timeout testing is at.
    long iter;

    /// Last count of the mutants in the worklist that where in the timeout state.
    long worklistCount;

    enum State {
        init_,
        running,
        done
    }

    /// State of the timeout algorithm.
    State state;
}

/** The lower 64bit of the checksum should be good enough as the primary key.
 * By doing it this way it is easier to update a marked mutant without
 * "peeking" in the database ("insert or update").
 *
 * Both `st_id` and `mut_id` are values that sqlite can reuse between analyzes
 * if they have been previously removed thus the only assured connection
 * between a marked mutant and future code changes is the checksum.
 */
@TableName(markedMutantTable)
@TablePrimaryKey("checksum0")
struct MarkedMutantTbl {
    /// Checksum of the mutant status the marking is related to.
    long checksum0;
    long checksum1;

    /// updated each analyze.
    @ColumnName("st_id")
    long mutationStatusId;

    /// updated each analyze.
    @ColumnName("mut_id")
    long mutationId;

    uint line;
    uint column;
    string path;

    /// The status it should always be changed to.
    long toStatus;

    /// Time when the mutant where marked.
    SysTime time;

    string rationale;

    string mutText;
}

@TableName(schemataMutantTable)
@TableForeignKey("st_id", KeyRef("mutation_status(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("schem_id", KeyRef("schemata(id)"), KeyParam("ON DELETE CASCADE"))
@TableConstraint("unique_ UNIQUE (st_id, schem_id)")
struct SchemataMutantTable {
    @ColumnName("st_id")
    long statusId;
    @ColumnName("schem_id")
    long schemaId;
}

@TableName(schemataTable)
struct SchemataTable {
    long id;

    // number of fragments the schemata consist of.
    // used to detect if a fragment has been removed because its related file
    // was changed.
    long fragments;

    // runtime generated constant that make it possible to "prune" old
    // schematas automatically. it assumes that each new version of dextool may
    // contain updates to the schematas thus the old schemats should be
    // removed.
    @ColumnName("version")
    long version_;
}

@TableName(schemataUsedTable)
@TableForeignKey("id", KeyRef("schemata(id)"), KeyParam("ON DELETE CASCADE"))
struct SchemataUsedTable {
    long id;
}

@TableName(schemataFragmentTable)
@TableForeignKey("schem_id", KeyRef("schemata(id)"), KeyParam("ON DELETE CASCADE"))
@TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
struct SchemataFragmentTable {
    long id;

    @ColumnName("schem_id")
    long schemataId;

    @ColumnName("file_id")
    long fileId;

    @ColumnName("order_")
    long order;

    @ColumnParam("")
    const(ubyte)[] text;

    @ColumnName("offset_begin")
    uint offsetBegin;
    @ColumnName("offset_end")
    uint offsetEnd;
}

void updateSchemaVersion(ref Miniorm db, long ver) nothrow {
    try {
        db.run(delete_!VersionTbl);
        db.run(insert!VersionTbl.insert, VersionTbl(ver));
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }
}

long getSchemaVersion(ref Miniorm db) nothrow {
    try {
        auto v = db.run(select!VersionTbl);
        return v.empty ? 0 : v.front.version_;
    } catch (Exception e) {
    }
    return 0;
}

void upgrade(ref Miniorm db) {
    import d2sqlite3;

    immutable maxIndex = 5;

    alias upgradeFunc = void function(ref Miniorm db);
    auto tbl = makeUpgradeTable;

    bool hasUpdated;

    bool running = true;
    while (running) {
        long version_ = 0;

        try {
            version_ = getSchemaVersion(db);
        } catch (Exception e) {
            logger.trace(e.msg).collectException;
        }

        if (version_ >= tbl.latestSchemaVersion) {
            running = false;
            continue;
        }

        logger.infof("Upgrading database from %s", version_).collectException;

        if (!hasUpdated)
            try {
                // only do this once and always before any changes to the database.
                foreach (i; 0 .. maxIndex) {
                    db.run(format!"DROP INDEX IF EXISTS i%s"(i));
                }
            } catch (Exception e) {
                logger.warning(e.msg).collectException;
                logger.warning("Unable to drop database indexes").collectException;
            }

        if (auto f = version_ in tbl) {
            try {
                auto trans = db.transaction;
                hasUpdated = true;

                (*f)(db);
                if (version_ != 0)
                    updateSchemaVersion(db, version_ + 1);
                trans.commit;
            } catch (Exception e) {
                logger.trace(e).collectException;
                logger.error(e.msg).collectException;
                logger.warningf("Unable to upgrade a database of version %s",
                        version_).collectException;
                logger.warning("This might impact the functionality. It is unwise to continue")
                    .collectException;
                return;
            }
        } else {
            logger.info("Upgrade successful").collectException;
            running = false;
        }
    }

    // add indexes assuming the lastest database schema
    if (hasUpdated)
        try {
            auto trans = db.transaction;
            int i;
            db.run(format!"CREATE INDEX i%s ON %s(file_id)"(i++, mutationPointTable));
            db.run(format!"CREATE INDEX i%s ON %s(path)"(i++, filesTable));

            // improve getTestCaseMutantKills by 10x
            db.run(format!"CREATE INDEX i%s ON %s(tc_id,st_id)"(i++, killedTestCaseTable));
            db.run(format!"CREATE INDEX i%s ON %s(st_id)"(i++, mutationTable));

            assert(i <= maxIndex);
            trans.commit;
        } catch (Exception e) {
            logger.warning(e.msg).collectException;
            logger.warning("Unable to create database indexes").collectException;
        }
}

/** If the database start it version 0, not initialized, then initialize to the
 * latest schema version.
 */
void upgradeV0(ref Miniorm db) {
    auto tbl = makeUpgradeTable;

    db.run(buildSchema!(VersionTbl, RawSrcMetadata, FilesTbl,
            MutationPointTbl, MutationTbl, TestCaseKilledTbl, AllTestCaseTbl,
            MutationStatusTbl, MutantTimeoutCtxTbl, MutantTimeoutWorklistTbl,
            MarkedMutantTbl, SrcMetadataTable, NomutTbl, NomutDataTbl,
            NomutDataTbl, SchemataTable, SchemataFragmentTable,
            SchemataMutantTable, SchemataUsedTable));

    updateSchemaVersion(db, tbl.latestSchemaVersion);
}

/// 2018-04-08
void upgradeV1(ref Miniorm db) {
    @TableName(testCaseTableV1)
    @TableForeignKey("mut_id", KeyRef("mutation(id)"), KeyParam("ON DELETE CASCADE"))
    static struct TestCaseKilledTblV1 {
        ulong id;

        @ColumnName("mut_id")
        ulong mutantId;

        /// test_case is whatever identifier the user choose.
        @ColumnName("test_case")
        string testCase;
    }

    db.run(buildSchema!TestCaseKilledTblV1);
}

/// 2018-04-22
void upgradeV2(ref Miniorm db) {
    @TableName(filesTable)
    static struct FilesTbl {
        ulong id;

        @ColumnParam("")
        string path;

        ulong checksum0;
        ulong checksum1;
        Language lang;
    }

    immutable new_tbl = "new_" ~ filesTable;

    db.run(buildSchema!FilesTbl("new_"));
    db.run(format("INSERT INTO %s (id,path,checksum0,checksum1) SELECT * FROM %s",
            new_tbl, filesTable));
    db.replaceTbl(new_tbl, filesTable);
}

/// 2018-09-01
void upgradeV3(ref Miniorm db) {
    @TableName(killedTestCaseTable)
    @TableForeignKey("mut_id", KeyRef("mutation(id)"), KeyParam("ON DELETE CASCADE"))
    struct TestCaseKilledTblV2 {
        ulong id;

        @ColumnName("mut_id")
        ulong mutantId;

        @ColumnParam("")
        string name;

        // location is a filesystem location or other suitable helper for a user to
        // locate the test.
        @ColumnParam("")
        string location;
    }

    db.run(buildSchema!TestCaseKilledTblV2);
    db.run(format("INSERT INTO %s (id,mut_id,name) SELECT * FROM %s",
            killedTestCaseTable, testCaseTableV1));
    db.run(format("DROP TABLE %s", testCaseTableV1));

    db.run(buildSchema!AllTestCaseTbl);
}

/// 2018-09-24
void upgradeV4(ref Miniorm db) {
    @TableName(killedTestCaseTable)
    @TableForeignKey("mut_id", KeyRef("mutation(id)"), KeyParam("ON DELETE CASCADE"))
    @TableForeignKey("tc_id", KeyRef("all_test_case(id)"), KeyParam("ON DELETE CASCADE"))
    static struct TestCaseKilledTblV3 {
        ulong id;

        @ColumnName("mut_id")
        ulong mutantId;
        @ColumnName("tc_id")
        ulong testCaseId;

        // location is a filesystem location or other suitable helper for a user to
        // locate the test.
        @ColumnParam("")
        string location;
    }

    immutable new_tbl = "new_" ~ killedTestCaseTable;

    db.run(buildSchema!TestCaseKilledTblV3("new_"));

    // add all missing test cases to all_test_case
    db.run(format("INSERT INTO %s (name) SELECT DISTINCT t1.name FROM %s t1 LEFT JOIN %s t2 ON t2.name = t1.name WHERE t2.name IS NULL",
            allTestCaseTable, killedTestCaseTable, allTestCaseTable));
    // https://stackoverflow.com/questions/2686254/how-to-select-all-records-from-one-table-that-do-not-exist-in-another-table
    //Q: What is happening here?
    //
    //A: Conceptually, we select all rows from table1 and for each row we
    //attempt to find a row in table2 with the same value for the name column.
    //If there is no such row, we just leave the table2 portion of our result
    //empty for that row. Then we constrain our selection by picking only those
    //rows in the result where the matching row does not exist. Finally, We
    //ignore all fields from our result except for the name column (the one we
    //are sure that exists, from table1).
    //
    //While it may not be the most performant method possible in all cases, it
    //should work in basically every database engine ever that attempts to
    //implement ANSI 92 SQL

    // This do NOT WORK. The result is that that this upgrade is broken because
    // it drops all maps between killed_test_case and mutation.
    //db.run(format("INSERT INTO %s (id,mut_id,tc_id,location) SELECT t1.id,t1.mut_id,t2.id,t1.location FROM %s t1 INNER JOIN %s t2 ON t1.name = t2.name",
    //        new_tbl, killedTestCaseTable, allTestCaseTable));

    db.replaceTbl(new_tbl, killedTestCaseTable);
}

/** 2018-09-30
 *
 * This upgrade will drop all existing mutations and thus all results.
 * It is too complex trying to upgrade and keep the results.
 *
 * When removing this function also remove the status field in mutation_v2_tbl.
 */
void upgradeV5(ref Miniorm db) {
    @TableName(mutationTable)
    @TableForeignKey("mp_id", KeyRef("mutation_point(id)"), KeyParam("ON DELETE CASCADE"))
    @TableForeignKey("st_id", KeyRef("mutation_status(id)"))
    @TableConstraint("unique_ UNIQUE (mp_id, kind)")
    static struct MutationTbl {
        ulong id;

        ulong mp_id;

        @ColumnParam("")
        ulong st_id;

        ulong kind;

        @ColumnParam("")
        ulong status;

        /// time in ms spent on verifying the mutant
        @ColumnParam("")
        ulong time;
    }

    @TableName(mutationStatusTable)
    @TableConstraint("checksum UNIQUE (checksum0, checksum1)")
    static struct MutationStatusTbl {
        ulong id;
        ulong status;
        ulong checksum0;
        ulong checksum1;
    }

    immutable new_mut_tbl = "new_" ~ mutationTable;
    db.run(buildSchema!MutationStatusTbl);

    db.run(format("DROP TABLE %s", mutationTable));
    db.run(buildSchema!MutationTbl);

    immutable new_files_tbl = "new_" ~ filesTable;
    db.run(buildSchema!FilesTbl("new_"));
    db.run(format("INSERT OR IGNORE INTO %s (id,path,checksum0,checksum1,lang) SELECT * FROM %s",
            new_files_tbl, filesTable));
    db.replaceTbl(new_files_tbl, filesTable);
}

/// 2018-10-11
void upgradeV6(ref Miniorm db) {
    @TableName(mutationStatusTable)
    @TableConstraint("checksum UNIQUE (checksum0, checksum1)")
    static struct MutationStatusTbl {
        ulong id;
        ulong status;
        ulong time;
        SysTime timestamp;
        ulong checksum0;
        ulong checksum1;
    }

    immutable new_mut_tbl = "new_" ~ mutationTable;

    db.run(buildSchema!MutationTbl("new_"));

    db.run(format("INSERT INTO %s (id,mp_id,st_id,kind) SELECT id,mp_id,st_id,kind FROM %s",
            new_mut_tbl, mutationTable));
    db.replaceTbl(new_mut_tbl, mutationTable);

    immutable new_muts_tbl = "new_" ~ mutationStatusTable;
    db.run(buildSchema!MutationStatusTbl("new_"));
    db.run(format("INSERT INTO %s (id,status,checksum0,checksum1) SELECT id,status,checksum0,checksum1 FROM %s",
            new_muts_tbl, mutationStatusTable));
    db.replaceTbl(new_muts_tbl, mutationStatusTable);
}

/// 2018-10-15
void upgradeV7(ref Miniorm db) {
    immutable new_tbl = "new_" ~ killedTestCaseTable;

    db.run(buildSchema!TestCaseKilledTbl("new_"));

    db.run(format("INSERT INTO %s (id,st_id,tc_id,location)
        SELECT t0.id,t1.st_id,t0.tc_id,t0.location
        FROM %s t0, %s t1
        WHERE
        t0.mut_id = t1.id", new_tbl,
            killedTestCaseTable, mutationTable));

    db.replaceTbl(new_tbl, killedTestCaseTable);
}

/// 2018-10-20
void upgradeV8(ref Miniorm db) {
    immutable new_tbl = "new_" ~ mutationPointTable;
    db.run(buildSchema!MutationPointTbl("new_"));
    db.run(format("INSERT INTO %s (id,file_id,offset_begin,offset_end,line,column)
        SELECT t0.id,t0.file_id,t0.offset_begin,t0.offset_end,t0.line,t0.column
        FROM %s t0",
            new_tbl, mutationPointTable));

    db.replaceTbl(new_tbl, mutationPointTable);
}

/// 2018-11-10
void upgradeV9(ref Miniorm db) {
    immutable new_tbl = "new_" ~ mutationStatusTable;
    db.run(buildSchema!MutationStatusTbl("new_"));
    db.run(format("INSERT INTO %s (id,status,time,test_cnt,update_ts,checksum0,checksum1)
        SELECT t0.id,t0.status,t0.time,0,t0.timestamp,t0.checksum0,t0.checksum1
        FROM %s t0",
            new_tbl, mutationStatusTable));

    replaceTbl(db, new_tbl, mutationStatusTable);
}

/// 2018-11-25
void upgradeV10(ref Miniorm db) {
    @TableName(rawSrcMetadataTable)
    @TableForeignKey("file_id", KeyRef("files(id)"), KeyParam("ON DELETE CASCADE"))
    @TableConstraint("unique_line_in_file UNIQUE (file_id, line)")
    struct RawSrcMetadata {
        ulong id;

        @ColumnName("file_id")
        ulong fileId;

        @ColumnParam("")
        uint line;

        @ColumnParam("")
        ulong nomut;
    }

    db.run(buildSchema!RawSrcMetadata);
    void makeSrcMetadataView(ref Miniorm db) {
        // check if a NOMUT is on or between the start and end of a mutant.
        immutable src_metadata_v1_tbl = "CREATE VIEW %s
            AS
            SELECT
            t0.id AS mut_id,
            t1.id AS st_id,
            t2.id AS mp_id,
            t3.id AS file_id,
            (SELECT count(*) FROM %s in_t0, %s in_t1
             WHERE
             in_t0.file_id = in_t1.file_id AND
             t0.mp_id = in_t0.id AND
             (in_t1.line BETWEEN in_t0.line AND in_t0.line_end)) AS nomut
                FROM %s t0, %s t1, %s t2, %s t3
                WHERE
                t0.mp_id = t2.id AND
                t0.st_id = t1.id AND
                t2.file_id = t3.id
                ";

        db.run(format(src_metadata_v1_tbl, srcMetadataTable, mutationPointTable, rawSrcMetadataTable,
                mutationTable, mutationStatusTable, mutationPointTable, filesTable));
    }

    makeSrcMetadataView(db);
}

/// 2019-04-06
void upgradeV11(ref Miniorm db) {
    immutable new_tbl = "new_" ~ rawSrcMetadataTable;
    db.run(buildSchema!RawSrcMetadata("new_"));
    db.run(format!"INSERT INTO %s (id,file_id,line,nomut) SELECT t.id,t.file_id,t.line,t.nomut FROM %s t"(new_tbl,
            rawSrcMetadataTable));
    replaceTbl(db, new_tbl, rawSrcMetadataTable);

    db.run(format("DROP VIEW %s", srcMetadataTable)).collectException;

    // Associate metadata from lines with the mutation status.
    void makeSrcMetadataView(ref Miniorm db) {
        // check if a NOMUT is on or between the start and end of a mutant.
        immutable src_metadata_tbl = "CREATE VIEW %s
        AS
        SELECT DISTINCT
        t0.id AS mut_id,
        t1.id AS st_id,
        t2.id AS mp_id,
        t3.id AS file_id,
        (SELECT count(*) FROM %s WHERE nomut.mp_id = t2.id) as nomut
        FROM %s t0, %s t1, %s t2, %s t3
        WHERE
        t0.mp_id = t2.id AND
        t0.st_id = t1.id AND
        t2.file_id = t3.id";
        db.run(format(src_metadata_tbl, srcMetadataTable, nomutTable,
                mutationTable, mutationStatusTable, mutationPointTable, filesTable));

        immutable nomut_tbl = "CREATE VIEW %s
        AS
        SELECT
        t0.id mp_id,
        t1.line line,
        count(*) status
        FROM %s t0, %s t1
        WHERE
        t0.file_id = t1.file_id AND
        (t1.line BETWEEN t0.line AND t0.line_end)
        GROUP BY
        t0.id";
        db.run(format(nomut_tbl, nomutTable, mutationPointTable, rawSrcMetadataTable));

        immutable nomut_data_tbl = "CREATE VIEW %s
        AS
        SELECT
        t0.id as mut_id,
        t0.mp_id as mp_id,
        t1.line as line,
        t1.tag as tag,
        t1.comment as comment
        FROM %s t0, %s t1, %s t2
        WHERE
        t0.mp_id = t2.mp_id AND
        t1.line = t2.line";
        db.run(format(nomut_data_tbl, nomutDataTable, mutationTable,
                rawSrcMetadataTable, nomutTable));
    }

    makeSrcMetadataView(db);
}

/// 2019-08-28
void upgradeV12(ref Miniorm db) {
    db.run(buildSchema!(MutantTimeoutCtxTbl, MutantTimeoutWorklistTbl));
}

/// 2019-11-12
void upgradeV13(ref Miniorm db) {
    @TableName(markedMutantTable)
    @TablePrimaryKey("st_id")
    struct MarkedMutantTbl {
        @ColumnName("st_id")
        long mutationStatusId;

        @ColumnName("mut_id")
        long mutationId;

        uint line;

        uint column;

        string path;

        @ColumnName("to_status")
        ulong toStatus;

        SysTime time;

        string rationale;

        @ColumnName("mut_text")
        string mutText;
    }

    db.run(buildSchema!(MarkedMutantTbl));
}

/// 2020-01-12
void upgradeV14(ref Miniorm db) {
    db.run(format!"DROP VIEW %s"(srcMetadataTable));
    db.run(format!"DROP VIEW %s"(nomutTable));
    db.run(format!"DROP VIEW %s"(nomutDataTable));

    db.run(buildSchema!(SrcMetadataTable, NomutTbl, NomutDataTbl));
    logger.info("Re-execute analyze to update the NOMUT data");
}

/// 2020-01-21
void upgradeV15(ref Miniorm db) {
    // fix bug in the marked mutant table
    db.run(format!"DROP TABLE %s"(markedMutantTable));
    db.run(buildSchema!MarkedMutantTbl);
    logger.info("Dropping all marked mutants because of database changes");
}

/// 2020-02-12
void upgradeV16(ref Miniorm db) {
    @TableName(schemataWorkListTable)
    @TableForeignKey("id", KeyRef("schemata(id)"), KeyParam("ON DELETE CASCADE"))
    static struct SchemataWorkListTable {
        long id;
    }

    @TableName(schemataMutantTable)
    @TableForeignKey("st_id", KeyRef("mutation_status(id)"), KeyParam("ON DELETE CASCADE"))
    @TableForeignKey("schem_id", KeyRef("schemata_fragment(id)"), KeyParam("ON DELETE CASCADE"))
    static struct SchemataMutantTable {
        @ColumnName("st_id")
        long statusId;
        @ColumnName("schem_id")
        long schemaId;
    }

    db.run(buildSchema!(SchemataFragmentTable, SchemataWorkListTable, SchemataMutantTable));
}

/// 2020-02-12
void upgradeV17(ref Miniorm db) {
    @TableName(schemataTable)
    static struct SchemataTable {
        long id;
    }

    db.run(buildSchema!(SchemataTable));
}

/// 2020-03-21
void upgradeV18(ref Miniorm db) {
    // this force an old database to add indexes
}

/// 2020-04-01
void upgradeV19(ref Miniorm db) {
    db.run("DROP TABLE " ~ schemataWorkListTable);
    db.run("DROP TABLE " ~ schemataTable);
    db.run("DROP TABLE " ~ schemataMutantTable);

    @TableName(invalidSchemataTable)
    @TableForeignKey("id", KeyRef("schemata(id)"), KeyParam("ON DELETE CASCADE"))
    struct InvalidSchemataTable {
        long id;
    }

    db.run(buildSchema!(SchemataTable, SchemataMutantTable, InvalidSchemataTable));
}

/// 2020-06-01
void upgradeV20(ref Miniorm db) {
    db.run("DROP TABLE " ~ schemataMutantTable);
    db.run(buildSchema!(SchemataMutantTable));
}

void upgradeV21(ref Miniorm db) {
    db.run("DROP TABLE " ~ invalidSchemataTable);
    db.run(buildSchema!(SchemataUsedTable));
}

void replaceTbl(ref Miniorm db, string src, string dst) {
    db.run("DROP TABLE " ~ dst);
    db.run(format("ALTER TABLE %s RENAME TO %s", src, dst));
}

struct UpgradeTable {
    alias UpgradeFunc = void function(ref Miniorm db);
    UpgradeFunc[long] tbl;
    alias tbl this;

    immutable long latestSchemaVersion;
}

/** Inspects a module for functions starting with upgradeV to create a table of
 * functions that can be used to upgrade a database.
 */
UpgradeTable makeUpgradeTable() {
    import std.algorithm : sort, startsWith;
    import std.conv : to;
    import std.typecons : Tuple;

    immutable prefix = "upgradeV";

    alias Module = dextool.plugin.mutate.backend.database.schema;

    // the second parameter is the database version to upgrade FROM.
    alias UpgradeFx = Tuple!(UpgradeTable.UpgradeFunc, long);

    UpgradeFx[] upgradeFx;
    long last_from;

    static foreach (member; __traits(allMembers, Module)) {
        static if (member.startsWith(prefix))
            upgradeFx ~= UpgradeFx(&__traits(getMember, Module, member),
                    member[prefix.length .. $].to!long);
    }

    typeof(UpgradeTable.tbl) tbl;
    foreach (fn; upgradeFx.sort!((a, b) => a[1] < b[1])) {
        last_from = fn[1];
        tbl[last_from] = fn[0];
    }

    return UpgradeTable(tbl, last_from + 1);
}
