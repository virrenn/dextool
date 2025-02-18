/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: MPL-2
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

This Source Code Form is subject to the terms of the Mozilla Public License,
v.2.0. If a copy of the MPL was not distributed with this file, You can obtain
one at http://mozilla.org/MPL/2.0/.

This file contains functionality to take an unprocessed mutation point and
generate a mutant for it.
*/
module dextool.plugin.mutate.backend.generate_mutant;

import logger = std.experimental.logger;
import std.exception : collectException;
import std.path : buildPath;
import std.typecons : Nullable;
import std.utf : validate;

import blob_model : Blob, Edit, change, Interval, Uri, merge;

import dextool.type : AbsolutePath, ExitStatusType, Path;
import dextool.plugin.mutate.backend.database : Database, MutationEntry, MutationId, spinSql;
import dextool.plugin.mutate.backend.type : Language;
import dextool.plugin.mutate.backend.interface_ : FilesysIO, SafeOutput, ValidateLoc;
import dextool.plugin.mutate.type : MutationKind;

enum GenerateMutantStatus {
    error,
    filesysError,
    databaseError,
    checksumError,
    noMutation,
    ok
}

ExitStatusType runGenerateMutant(const AbsolutePath dbPath, MutationKind[] kind,
        MutationId user_mutation, FilesysIO fio, ValidateLoc val_loc) @trusted nothrow {
    import dextool.plugin.mutate.backend.mutation_type : toInternal;

    ExitStatusType helper(ref Database db) @safe {
        auto mutp = spinSql!(() => db.mutantApi.getMutation(user_mutation));

        if (mutp.isNull) {
            logger.error("No such mutation id: ", user_mutation).collectException;
            return ExitStatusType.Errors;
        }

        auto mut_file = AbsolutePath(buildPath(fio.getOutputDir, mutp.get.file));

        Blob content = fio.makeInput(mut_file);

        auto ofile = makeOutputFilename(val_loc, fio, mut_file);
        auto fout = fio.makeOutput(ofile);
        auto res = generateMutant(db, mutp.get, content, fout);
        if (res.status == GenerateMutantStatus.ok) {
            logger.infof("%s Mutate from '%s' to '%s' in %s", mutp.get.id,
                    cast(const(char)[]) res.from, cast(const(char)[]) res.to, ofile);
        }
        return ExitStatusType.Ok;
    }

    try {
        auto db = Database.make(dbPath);
        return helper(db);
    } catch (Exception e) {
        logger.error(e.msg).collectException;
    }

    return ExitStatusType.Errors;
}

private AbsolutePath makeOutputFilename(ValidateLoc val_loc, FilesysIO fio, AbsolutePath file) @safe {
    import std.path;

    if (val_loc.shouldMutate(file))
        return file;

    return AbsolutePath(Path(buildPath(fio.getOutputDir, file.baseName)));
}

struct GenerateMutantResult {
    GenerateMutantStatus status;
    const(ubyte)[] from;
    const(ubyte)[] to;
}

auto generateMutant(ref Database db, MutationEntry mutp, Blob original, ref SafeOutput fout) @safe nothrow {
    import std.algorithm : min;
    import dextool.plugin.mutate.backend.utility : checksum, Checksum;

    if (mutp.mp.mutations.length == 0)
        return GenerateMutantResult(GenerateMutantStatus.noMutation);

    Nullable!Checksum db_checksum;
    try {
        db_checksum = db.getFileChecksum(mutp.file);
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
        return GenerateMutantResult(GenerateMutantStatus.databaseError);
    }

    Checksum f_checksum;
    try {
        f_checksum = checksum(original.content);
    } catch (Exception e) {
        logger.warning(e.msg).collectException;
        return GenerateMutantResult(GenerateMutantStatus.filesysError);
    }

    if (db_checksum.isNull) {
        logger.errorf("Database contains erroneous data. A mutation point for %s exist but the file has no checksum",
                mutp.file).collectException;
        return GenerateMutantResult(GenerateMutantStatus.databaseError);
    } else if (db_checksum != f_checksum) {
        logger.errorf("Unable to mutate %s (%s) because the checksum is different from the one in the database (%s)",
                mutp.file, f_checksum.c0, db_checksum.get.c0).collectException;
        return GenerateMutantResult(GenerateMutantStatus.checksumError);
    }

    auto mut = makeMutation(mutp.mp.mutations[0].kind, mutp.lang);

    try {
        Edit[] edits;
        edits ~= new Edit(Interval(0, 0), mut.top());

        const end = min(mutp.mp.offset.end, original.content.length);
        const begin = min(mutp.mp.offset.begin, original.content.length, end);

        if (mutp.mp.offset.begin > original.content.length
                || mutp.mp.offset.end > original.content.length) {
            logger.tracef("Unable to correctly generate mutant %s. Offset is %s max length is %s",
                    mutp.mp.mutations[0].kind, mutp.mp.offset, original.content.length);
        } else if (mutp.mp.offset.begin > mutp.mp.offset.end) {
            logger.tracef("Unable to correctly generate mutant %s. Offset begin > end %s",
                    mutp.mp.mutations[0].kind, mutp.mp.offset);
        }

        auto from_ = original.content[begin .. end];
        auto to_ = mut.mutate(from_);

        edits ~= new Edit(Interval(begin, end), to_);

        // #SPC-file_security-header_as_warning
        edits ~= new Edit(Interval.append, "\n/* DEXTOOL: THIS FILE IS MUTATED */\n");

        auto blob = new Blob(original.uri, original.content);
        auto m = merge(blob, edits);
        blob = change(blob, m.edits);

        fout.write(blob.content);

        return GenerateMutantResult(GenerateMutantStatus.ok, from_, to_);
    } catch (Exception e) {
        return GenerateMutantResult(GenerateMutantStatus.filesysError);
    }
}

auto makeMutation(Mutation.Kind kind, Language lang) {
    import std.format : format;

    static auto toB(string s) @safe {
        return cast(const(ubyte)[]) s;
    }

    MutateImpl m;
    m.top = () { return null; };
    m.mutate = (const(ubyte)[] from) { return null; };

    auto clangTrue(const(ubyte)[]) {
        if (lang == Language.c)
            return toB("1");
        return toB("true");
    }

    auto clangFalse(const(ubyte)[]) {
        if (lang == Language.c)
            return cast(const(ubyte)[]) "0";
        return cast(const(ubyte)[]) "false";
    }

    final switch (kind) with (Mutation.Kind) {
        /// the kind is not initialized thus can only ignore the point
    case none:
        break;
        /// Relational operator replacement
    case rorLT:
        goto case;
    case rorpLT:
        m.mutate = (const(ubyte)[] expr) { return toB("<"); };
        break;
    case rorLE:
        goto case;
    case rorpLE:
        m.mutate = (const(ubyte)[] expr) { return toB("<="); };
        break;
    case rorGT:
        goto case;
    case rorpGT:
        m.mutate = (const(ubyte)[] expr) { return toB(">"); };
        break;
    case rorGE:
        goto case;
    case rorpGE:
        m.mutate = (const(ubyte)[] expr) { return toB(">="); };
        break;
    case rorEQ:
        goto case;
    case rorpEQ:
        m.mutate = (const(ubyte)[] expr) { return toB("=="); };
        break;
    case rorNE:
        goto case;
    case rorpNE:
        m.mutate = (const(ubyte)[] expr) { return toB("!="); };
        break;
    case rorTrue:
        m.mutate = &clangTrue;
        break;
    case rorFalse:
        m.mutate = &clangFalse;
        break;
        /// Logical connector replacement
        /// #SPC-mutation_lcr
    case lcrAnd:
        m.mutate = (const(ubyte)[] expr) { return toB("&&"); };
        break;
    case lcrOr:
        m.mutate = (const(ubyte)[] expr) { return toB("||"); };
        break;
    case lcrLhs:
        goto case;
    case lcrRhs:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
    case lcrTrue:
        m.mutate = &clangTrue;
        break;
    case lcrFalse:
        m.mutate = &clangFalse;
        break;
        /// Arithmetic operator replacement
        /// #SPC-mutation_aor
    case aorMul:
        goto case;
    case aorsMul:
        m.mutate = (const(ubyte)[] expr) { return toB("*"); };
        break;
    case aorDiv:
        goto case;
    case aorsDiv:
        m.mutate = (const(ubyte)[] expr) { return toB("/"); };
        break;
    case aorRem:
        m.mutate = (const(ubyte)[] expr) { return toB("%"); };
        break;
    case aorAdd:
        goto case;
    case aorsAdd:
        m.mutate = (const(ubyte)[] expr) { return toB("+"); };
        break;
    case aorSub:
        goto case;
    case aorsSub:
        m.mutate = (const(ubyte)[] expr) { return toB("-"); };
        break;
    case aorMulAssign:
        goto case;
    case aorsMulAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("*="); };
        break;
    case aorDivAssign:
        goto case;
    case aorsDivAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("/="); };
        break;
    case aorRemAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("%="); };
        break;
    case aorAddAssign:
        goto case;
    case aorsAddAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("+="); };
        break;
    case aorSubAssign:
        goto case;
    case aorsSubAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("-="); };
        break;
    case aorLhs:
        goto case;
    case aorRhs:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
        /// Unary operator insert on an lvalue
        /// #SPC-mutation_uoi
    case uoiPostInc:
        m.mutate = (const(ubyte)[] expr) { return expr ~ toB("++"); };
        break;
    case uoiPostDec:
        m.mutate = (const(ubyte)[] expr) { return expr ~ toB("--"); };
        break;
        // these work for rvalue
    case uoiPreInc:
        m.mutate = (const(ubyte)[] expr) { return toB("++") ~ expr; };
        break;
    case uoiPreDec:
        m.mutate = (const(ubyte)[] expr) { return toB("--") ~ expr; };
        break;
    case uoiAddress:
        m.mutate = (const(ubyte)[] expr) { return toB("&") ~ expr; };
        break;
    case uoiIndirection:
        m.mutate = (const(ubyte)[] expr) { return toB("*") ~ expr; };
        break;
    case uoiPositive:
        m.mutate = (const(ubyte)[] expr) { return toB("+") ~ expr; };
        break;
    case uoiNegative:
        m.mutate = (const(ubyte)[] expr) { return toB("-") ~ expr; };
        break;
    case uoiComplement:
        m.mutate = (const(ubyte)[] expr) { return toB("~") ~ expr; };
        break;
    case uoiNegation:
        m.mutate = (const(ubyte)[] expr) { return toB("!") ~ expr; };
        break;
    case uoiSizeof_:
        m.mutate = (const(ubyte)[] expr) { return toB("sizeof(") ~ expr ~ toB(")"); };
        break;
    case uoiDel:
        m.mutate = (const(ubyte)[] expr) { return toB("!") ~ expr; };
        break;
        /// Absolute value replacement
        /// #SPC-mutation_abs
    case absPos:
        m.top = () { return toB(preambleAbs); };
        m.mutate = (const(ubyte)[] b) { return toB("abs_dextool(") ~ b ~ toB(")"); };
        break;
    case absNeg:
        m.top = () { return toB(preambleAbs); };
        m.mutate = (const(ubyte)[] b) { return toB("-abs_dextool(") ~ b ~ toB(")"); };
        break;
    case absZero:
        m.top = () { return toB(preambleAbs); };
        m.mutate = (const(ubyte)[] b) {
            return toB("fail_on_zero_dextool(") ~ b ~ toB(")");
        };
        break;
    case stmtDel:
        /// #SPC-mutations_statement_del
        // delete by commenting out the code block
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
        /// Conditional Operator Replacement (reduced set)
        /// #SPC-mutation_cor
    case corAnd:
        assert(0);
    case corOr:
        assert(0);
    case corFalse:
        m.mutate = &clangFalse;
        break;
    case corLhs:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
    case corRhs:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
    case corEQ:
        m.mutate = (const(ubyte)[] expr) { return toB("=="); };
        break;
    case corNE:
        m.mutate = (const(ubyte)[] expr) { return toB("!="); };
        break;
    case corTrue:
        m.mutate = &clangTrue;
        break;
    case dcrTrue:
        m.mutate = &clangTrue;
        break;
    case dcrReturnTrue:
        m.mutate = (const(ubyte)[] expr) {
            return toB("return ") ~ clangTrue(null);
        };
        break;
    case dcrFalse:
        m.mutate = &clangFalse;
        break;
    case dcrReturnFalse:
        m.mutate = (const(ubyte)[] expr) {
            return toB("return ") ~ clangFalse(null);
        };
        break;
    case dcrBomb:
        // assigning null should crash the program, thus a 'bomb'
        m.mutate = (const(ubyte)[] expr) { return toB(`*((char*)0)='x';`); };
        break;
    case dcrCaseDel:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
    case lcrbAnd:
        m.mutate = (const(ubyte)[] expr) { return toB("&"); };
        break;
    case lcrbOr:
        m.mutate = (const(ubyte)[] expr) { return toB("|"); };
        break;
    case lcrbAndAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("&="); };
        break;
    case lcrbOrAssign:
        m.mutate = (const(ubyte)[] expr) { return toB("|="); };
        break;
    case lcrbLhs:
        goto case;
    case lcrbRhs:
        m.mutate = (const(ubyte)[] expr) { return toB(""); };
        break;
    case crZero:
        m.mutate = (const(ubyte)[] expr) { return toB("0"); };
        break;
    }

    return m;
}

@safe struct MakeMutationTextResult {
    import std.utf : validate;

    static immutable originalIsCorrupt = "Dextool: unable to open the file or it has changed since mutation where performed";

    const(ubyte)[] rawOriginal = cast(const(ubyte)[]) originalIsCorrupt;
    const(ubyte)[] rawMutation;

    const(char)[] original() const {
        auto r = cast(const(char)[]) rawOriginal;
        validate(r);
        return r;
    }

    const(char)[] mutation() const {
        auto r = cast(const(char)[]) rawMutation;
        validate(r);
        return r;
    }

    size_t toHash() nothrow @safe const {
        import my.hash;

        BuildChecksum64 hash;
        hash.put(rawOriginal);
        hash.put(rawMutation);
        return hash.toChecksum64.toHash;
    }

    bool opEquals(const typeof(this) o) const nothrow @safe {
        return rawOriginal == o.rawOriginal && rawMutation == o.rawMutation;
    }
}

/// Returns: a snippet of the mutation if it is OK otherwise an empty snippet.
MakeMutationTextResult makeMutationText(Blob file_, const Offset offs,
        Mutation.Kind kind, Language lang) @safe {
    import dextool.plugin.mutate.backend.generate_mutant : makeMutation;

    MakeMutationTextResult rval;

    if (offs.begin < offs.end && offs.end < file_.content.length) {
        rval.rawOriginal = file_.content[offs.begin .. offs.end];
    }

    auto mut = makeMutation(kind, lang);
    rval.rawMutation = mut.mutate(rval.rawOriginal);

    return rval;
}

private:
@safe:

import dextool.plugin.mutate.backend.type : Offset, Mutation;

struct MutateImpl {
    alias CallbackTop = const(ubyte)[]delegate() @safe;
    alias CallbackMut = const(ubyte)[]delegate(const(ubyte)[] from) @safe;

    /// Called before any other data has been written to the file.
    CallbackTop top;

    /// Called at the mutation point.
    CallbackMut mutate;
}

immutable string preambleAbs;

shared static this() {
    // this is ugly but works for now
    preambleAbs = `
#ifndef DEXTOOL_INJECTED_ABS_FUNCTION
#define DEXTOOL_INJECTED_ABS_FUNCTION
#define abs_dextool(v) (v < 0 ? -v : v)
#endif
#ifndef DEXTOOL_INJECTED_FAIL_ON_ZERO_FUNCTION
#define DEXTOOL_INJECTED_FAIL_ON_ZERO_FUNCTION
#define fail_on_zero_dextool(v) (!v && (*((char*)0) = 'x') ? v : v)
#endif
`;
}

auto drop(T = void[])(T content, const Offset offset) {
    return DropRange!T(content[0 .. offset.begin], content[offset.end .. $]);
}

struct DropRange(T) {
    private {
        T[2] data;
        size_t idx;
    }

    this(T d0, T d1) {
        data = [d0, d1];
    }

    T front() @safe pure nothrow {
        assert(!empty, "Can't get front of an empty range");
        return data[idx];
    }

    void popFront() @safe pure nothrow {
        assert(!empty, "Can't pop front of an empty range");
        ++idx;
    }

    bool empty() @safe pure nothrow const @nogc {
        return idx == data.length;
    }
}
