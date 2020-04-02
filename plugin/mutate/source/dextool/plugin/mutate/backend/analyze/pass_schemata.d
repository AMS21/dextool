/**
Copyright: Copyright (c) 2020, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.
*/
module dextool.plugin.mutate.backend.analyze.pass_schemata;

import logger = std.experimental.logger;
import std.algorithm : among, map, sort, filter, canFind, copy;
import std.array : appender, empty, array, Appender;
import std.conv : to;
import std.exception : collectException;
import std.format : formattedWrite;
import std.meta : AliasSeq;
import std.range : retro, ElementType;
import std.traits : EnumMembers;
import std.typecons : Nullable, tuple, Tuple, scoped;

import automem : vector, Vector;

import dextool.type : AbsolutePath, Path;

import dextool.plugin.mutate.backend.analyze.ast : Interval, Location;
import dextool.plugin.mutate.backend.analyze.extensions;
import dextool.plugin.mutate.backend.analyze.internal;
import dextool.plugin.mutate.backend.analyze.utility;
import dextool.plugin.mutate.backend.database.type : SchemataFragment;
import dextool.plugin.mutate.backend.interface_ : FilesysIO;
import dextool.plugin.mutate.backend.type : Language, SourceLoc, Offset,
    Mutation, SourceLocRange, CodeMutant, SchemataChecksum, Checksum;

import dextool.plugin.mutate.backend.analyze.ast;
import dextool.plugin.mutate.backend.analyze.pass_mutant : CodeMutantsResult;

/// Translate a mutation AST to a schemata.
SchemataResult toSchemata(ref Ast ast, FilesysIO fio, CodeMutantsResult cresult) @trusted {
    auto rval = new SchemataResult(fio);
    auto index = scoped!CodeMutantIndex(cresult);

    final switch (ast.lang) {
    case Language.c:
        break;
    case Language.assumeCpp:
        goto case;
    case Language.cpp:
        auto visitor = () @trusted {
            return new CppSchemataVisitor(&ast, index, fio, rval);
        }();
        ast.accept(visitor);
        break;
    }

    return rval;
}

@safe:

/// Language generic
class SchemataResult {
    import dextool.set;
    import dextool.plugin.mutate.backend.database.type : SchemataFragment;

    static struct Fragment {
        Offset offset;
        const(ubyte)[] text;
    }

    static struct Schemata {
        Fragment[] fragments;
        Set!CodeMutant mutants;
    }

    private {
        Schemata[MutantGroup][AbsolutePath] schematas;
        FilesysIO fio;
    }

    this(FilesysIO fio) {
        this.fio = fio;
    }

    SchematasRange getSchematas() @safe {
        return SchematasRange(fio, schematas);
    }

    /// Assuming that all fragments for a file should be merged to one huge.
    private void putFragment(AbsolutePath file, MutantGroup g, Fragment sf, CodeMutant[] m) {
        if (auto v = file in schematas) {
            (*v)[g].fragments ~= sf;
            (*v)[g].mutants.add(m);
        } else {
            foreach (a; [EnumMembers!MutantGroup]) {
                schematas[file][a] = Schemata.init;
            }
            schematas[file][g] = Schemata([sf], m.toSet);
        }
    }

    override string toString() @safe {
        import std.range : put;
        import std.utf : byUTF;

        auto w = appender!string();

        void toBuf(Schemata s) {
            formattedWrite(w, "Mutants\n%(%s\n%)\n", s.mutants.toArray);
            foreach (f; s.fragments) {
                formattedWrite(w, "%s: %s\n", f.offset,
                        (cast(const(char)[]) f.text).byUTF!(const(char)));
            }
        }

        void toBufGroups(Schemata[MutantGroup] s) {
            foreach (a; s.byKeyValue) {
                formattedWrite(w, "Group %s ", a.key);
                toBuf(a.value);
            }
        }

        foreach (k; schematas.byKey.array.sort) {
            try {
                formattedWrite(w, "%s:\n", k);
                toBufGroups(schematas[k]);
            } catch (Exception e) {
            }
        }

        return w.data;
    }
}

private:

/** All mutants for a file that is part of the same group are merged to one schemata.
 *
 * Each file can have multiple groups.
 */
enum MutantGroup {
    any,
    aor,
}

auto defaultHeader(Path f) {
    static immutable code = `
#ifndef DEXTOOL_MUTANT_SCHEMATA_INCL_GUARD
#define DEXTOOL_MUTANT_SCHEMATA_INCL_GUARD
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t gDEXTOOL_MUTID;

__attribute__((constructor))
static void init_dextool_mutid(void) {
    gDEXTOOL_MUTID = 0;
    const char* e = getenv("DEXTOOL_MUTID");
    if (e != NULL) {
        sscanf(e, "%lu", &gDEXTOOL_MUTID);
    }
}

#endif /* DEXTOOL_MUTANT_SCHEMATA_INCL_GUARD */
`;
    return SchemataFragment(f, Offset(0, 0), cast(const(ubyte)[]) code);
}

struct SchematasRange {
    alias ET = Tuple!(SchemataFragment[], "fragments", CodeMutant[], "mutants",
            SchemataChecksum, "checksum");

    private {
        FilesysIO fio;
        ET[] values;
    }

    this(FilesysIO fio, SchemataResult.Schemata[MutantGroup][AbsolutePath] raw) {
        this.fio = fio;

        // TODO: maybe accumulate the fragments for more files? that would make
        // it possible to easily create a large schemata.
        auto values_ = appender!(ET[])();
        foreach (group; raw.byKeyValue) {
            auto relp = fio.toRelativeRoot(group.key);
            auto app = appender!(SchemataFragment[])();
            foreach (a; group.value.byKeyValue) {
                ET v;

                app.put(defaultHeader(relp));
                a.value.fragments.map!(a => SchemataFragment(relp, a.offset, a.text)).copy(app);
                v.fragments = app.data;

                v.mutants = a.value.mutants.toArray;
                v.checksum = toSchemataChecksum(v.mutants);
                values_.put(v);
                app.clear;
            }
        }
        this.values = values_.data;
    }

    ET front() @safe pure nothrow {
        assert(!empty, "Can't get front of an empty range");
        return values[0];
    }

    void popFront() @safe {
        assert(!empty, "Can't pop front of an empty range");
        values = values[1 .. $];
    }

    bool empty() @safe pure nothrow const @nogc {
        return values.empty;
    }
}

// An index over the mutants and the interval they apply for.
class CodeMutantIndex {
    CodeMutant[][Offset][AbsolutePath] index;

    this(CodeMutantsResult result) {
        foreach (p; result.points.byKeyValue) {
            CodeMutant[][Offset] e;
            foreach (mp; p.value) {
                if (auto v = mp.offset in e) {
                    (*v) ~= mp.mutants;
                } else {
                    e[mp.offset] = mp.mutants;
                }
            }
            index[p.key] = e;
        }
    }

    CodeMutant[] get(AbsolutePath file, Offset o) {
        if (auto v = file in index) {
            if (auto w = o in *v) {
                return *w;
            }
        }
        return null;
    }
}

class CppSchemataVisitor : DepthFirstVisitor {
    import dextool.plugin.mutate.backend.mutation_type.aor : aorMutationsAll;

    Ast* ast;
    CodeMutantIndex index;
    SchemataResult result;
    FilesysIO fio;

    this(Ast* ast, CodeMutantIndex index, FilesysIO fio, SchemataResult result) {
        this.ast = ast;
        this.index = index;
        this.fio = fio;
        this.result = result;
    }

    alias visit = DepthFirstVisitor.visit;

    override void visit(OpAdd n) {
        visitBinaryOp(n, aorMutationsAll, MutantGroup.aor);
        accept(n, this);
    }

    override void visit(OpSub n) {
        visitBinaryOp(n, aorMutationsAll, MutantGroup.aor);
        accept(n, this);
    }

    override void visit(OpMul n) {
        visitBinaryOp(n, aorMutationsAll, MutantGroup.aor);
        accept(n, this);
    }

    override void visit(OpMod n) {
        visitBinaryOp(n, aorMutationsAll, MutantGroup.aor);
        accept(n, this);
    }

    override void visit(OpDiv n) {
        visitBinaryOp(n, aorMutationsAll, MutantGroup.aor);
        accept(n, this);
    }

    private void visitBinaryOp(T)(T n, const Mutation.Kind[] kinds, const MutantGroup group) {
        import dextool.plugin.mutate.backend.generate_mutant : makeMutation;

        auto loc = ast.location(n.operator);
        auto mutants = index.get(loc.file, loc.interval)
            .filter!(a => canFind(kinds, a.mut.kind)).array;
        if (mutants.empty)
            return;

        auto locExpr = ast.location(n);
        auto locLhs = ast.location(n.lhs);
        auto locRhs = ast.location(n.rhs);
        if (locLhs is null || locRhs is null)
            return;

        auto app = appender!(const(ubyte)[])();
        auto fin = fio.makeInput(loc.file);
        app.put("(".rewrite);
        foreach (const mutant; mutants) {
            app.put("(gDEXTOOL_MUTID == ".rewrite);
            app.put(mutant.id.c0.to!string.rewrite);
            app.put("ull".rewrite);
            app.put(") ? (".rewrite);
            app.put(fin.content[locLhs.interval.begin .. locLhs.interval.end]);
            app.put(makeMutation(mutant.mut.kind, ast.lang).mutate(null));
            app.put(fin.content[locRhs.interval.begin .. locRhs.interval.end]);
            app.put(") : ".rewrite);
        }
        app.put("(".rewrite);
        app.put(fin.content[locExpr.interval.begin .. locExpr.interval.end]);
        app.put("))".rewrite);

        result.putFragment(loc.file, group, rewrite(locExpr, app.data), mutants);
    }
}

const(ubyte)[] rewrite(string s) {
    return cast(const(ubyte)[]) s;
}

SchemataResult.Fragment rewrite(Location loc, string s) {
    return rewrite(loc, cast(const(ubyte)[]) s);
}

/// Create a fragment that rewrite a source code location to `s`.
SchemataResult.Fragment rewrite(Location loc, const(ubyte)[] s) {
    return SchemataResult.Fragment(loc.interval, s);
}
/** A schemata is uniquely identified by the mutants that it contains.
 *
 * The order of the mutants are irrelevant because they are always sorted by
 * their value before the checksum is calculated.
 *
 */
SchemataChecksum toSchemataChecksum(CodeMutant[] mutants) {
    import dextool.plugin.mutate.backend.utility : BuildChecksum, toChecksum, toBytes;
    import dextool.utility : dextoolBinaryId;

    BuildChecksum h;
    // this make sure that schematas for a new version av always added to the
    // database.
    h.put(dextoolBinaryId.toBytes);
    foreach (a; mutants.sort!((a, b) => a.id.value < b.id.value)
            .map!(a => a.id.value)) {
        h.put(a.c0.toBytes);
        h.put(a.c1.toBytes);
    }

    return SchemataChecksum(toChecksum(h));
}
