/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

#TST-mutation_ror
*/
module dextool_test.mutate_ror;

import std.format : format;

import dextool_test.utility;
import dextool_test.fixtures;

import unit_threaded;

// dfmt off

struct Ex {
    string[] ops;
    string expr;
}

@(testId ~ "shall produce all ROR mutations for primitives")
unittest {
    mixin(envSetup(globalTestdir));

    Ex[string] tbl = [
        "<": Ex(["<=", "!="], "false"),
        ">": Ex([">=", "!="], "false"),
        "<=": Ex(["<", "=="], "true"),
        ">=": Ex([">", "=="], "true"),
        "==": Ex(["<=", ">="], "false"),
        "!=": Ex(["<", ">"], "true"),
    ];

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_primitive.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;
    verifyRor(r.output, tbl);
}

@(testId ~ "shall produce all ROR mutants for overloads")
unittest {
    mixin(envSetup(globalTestdir));

    Ex[string] tbl = [
        "<": Ex(["<=", "!="], "false"),
        ">": Ex([">=", "!="], "false"),
        "<=": Ex(["<", "=="], "true"),
        ">=": Ex([">", "=="], "true"),
        "==": Ex(["!="], "false"),
        "!=": Ex(["=="], "true"),
    ];

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_overload.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;
    verifyRor(r.output, tbl);
}

void verifyRor(string[] txt, Ex[string] tbl) {
    foreach (mut; tbl.byKeyValue) {
        foreach (op; mut.value.ops) {
            auto expected = format("from '%s' to '%s'", mut.key, op);
            testAnyOrder!SubStr([expected]).shouldBeIn(txt);
        }

        auto expected = format("from 'a %s b' to '%s'", mut.key, mut.value.expr);
        testAnyOrder!SubStr([expected]).shouldBeIn(txt);
    }
}

@(testId ~ "shall produce all ROR mutations according to the alternative schema when both types are floating point types")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_float_primitive.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;
    verifyFloatRor(r.output);
}

void verifyFloatRor(string[] txt) {
    import std.algorithm;

    static struct Ex {
        string[] ops;
        string expr;
    }
    Ex[string] tbl = [
        "<": Ex([">"], "false"),
        ">": Ex(["<"], "false"),
        "<=": Ex([">"], "true"),
        ">=": Ex(["<"], "true"),
        "==": Ex(["<=", ">="], "false"),
        "!=": Ex(["<", ">"], "true"),
    ];

    foreach (mut; tbl.byKeyValue) {
        foreach (op; mut.value.ops) {
            auto expected = format("from '%s' to '%s'", mut.key, op);
            logger.info("Testing: ", expected);
            txt.sliceContains(expected).shouldBeTrue;
        }

        auto expected = format("from 'a %s b' to '%s'", mut.key, mut.value.expr);
        logger.info("Testing: ", expected);
        txt.sliceContains(expected).shouldBeTrue;
    }
}

@(testId ~ "shall produce all ROR mutations according to the enum schema when both types are enum type and one is an enum const declaration")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_enum_primitive.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;

    testAnyOrder!SubStr([
        "from '<' to '<='",
        "from '<' to '!='",
        "from 'a < MyE::C' to 'false'",

        "from '<' to '<='",
        "from '<' to '!='",
        "from 'MyE::C < b' to 'false'",

        "from '>' to '>='",
        "from '>' to '!='",
        "from 'a > MyE::C' to 'false'",

        "from '>' to '>='",
        "from '>' to '!='",
        "from 'MyE::C > b' to 'false'",

        "from '<=' to '<'",
        "from '<=' to '=='",
        // this will always be true. Generating it for now because code like this should not exist
        "from 'a <= MyE::C' to 'true'",

        // No test case can catch this. Generating it for now because code like this should not exist
        "from '<=' to '<'",
        "from '<=' to '=='",
        "from 'MyE::C <= b' to 'true'",

        "from '>=' to '>'",
        "from '>=' to '=='",
        "from 'a >= MyE::C' to 'true'",

        "from '>=' to '>'",
        "from '>=' to '=='",
        "from 'MyE::C >= b' to 'true'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to the enum schema for equal when both types are enum type and one is an enum const declaration")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_enum_primitive_equal.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;

    testAnyOrder!SubStr([
        "from '==' to '<='",
        "from '==' to '>='",
        "from 'a == b' to 'false'",

        "from '==' to '<='",
        "from 'MyE::A == b' to 'false'",

        "from '==' to '<='",
        "from '==' to '>='",
        "from 'MyE::B == b' to 'false'",

        "from '==' to '>='",
        "from 'MyE::C == b' to 'false'",

        "from '==' to '>='",
        "from 'a == MyE::A' to 'false'",

        "from '==' to '<='",
        "from '==' to '>='",
        "from 'a == MyE::B' to 'false'",

        "from '==' to '<='",
        "from 'a == MyE::C' to 'false'",

        "from 'a == MyE::C' to 'false'",
        // test that g4 do NOT generate a <= because the left side is already min
        "from '==' to '<='",
        "from '==' to '>='",
        "from 'a == MyE::A' to 'false'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to the enum schema for not-equal when both types are enum type and one is an enum const declaration")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_enum_primitive_not_equal.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;

    testAnyOrder!SubStr([
        "from '!=' to '<'",
        "from '!=' to '>'",
        "from 'a != b' to 'true'",

        "from '!=' to '<'",
        "from 'MyE::A != b' to 'true'",

        "from '!=' to '<'",
        "from '!=' to '>'",
        "from 'MyE::B != b' to 'true'",

        "from '!=' to '>'",
        "from 'a != MyE::A' to 'true'",

        "from '!=' to '<'",
        "from '!=' to '>'",
        "from 'a != MyE::B' to 'true'",

        "from '!=' to '<'",
        "from 'a != MyE::C' to 'true'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to floating point schema when either type are pointers")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_pointer_primitive.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "rorp"])
        .run;

    testAnyOrder!SubStr([
        "from '==' to '!='",
        "from 'a0 == a1' to 'false'",

        "from '!=' to '=='",
        "from 'b0 != b1' to 'true'",

        "from '==' to '!='",
        "from 'c0 == 0' to 'false'",

        "from '!=' to '=='",
        "from 'd0 != 0' to 'true'",

        "from '==' to '<='",
        "from '==' to '>='",
        "from 'e0 == e1' to 'false'",

        "from '!=' to '<'",
        "from '!=' to '>'",
        "from 'f0 != f1' to 'true'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to floating point schema when either type are pointers")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_pointer_return_value.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "rorp"])
        .run;

    testAnyOrder!SubStr([
        "from '!=' to '=='",
        "from 'clone_ != &Foo::initRef' to 'true'",

        "from '==' to '!='",
        "from 'a0() == a1()' to 'false'",

        "from '!=' to '=='",
        "from 'b0() != b1()' to 'true'",

        "from '==' to '!='",
        "from 'c0() == 0' to 'false'",

        "from '!=' to '=='",
        "from 'd0() != 0' to 'true'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to the bool schema when both types are bools")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_bool_primitive.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;

    testAnyOrder!SubStr([
        "from '==' to '!='",
        "from 'a0 == a1' to 'false'",

        "from '!=' to '=='",
        "from 'b0 != b1' to 'true'",
    ]).shouldBeIn(r.output);
}

@(testId ~ "shall produce all ROR mutations according to the bool schema when both functions return type is bool")
unittest {
    mixin(envSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "ror_bool_return_value.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "ror"])
        .run;

    testAnyOrder!SubStr([
        "from '==' to '!='",
        "from 'a0() == a1()' to 'false'",

        "from '!=' to '=='",
        "from 'b0() != b1()' to 'true'",
    ]).shouldBeIn(r.output);
}

class ShallOnlyGenerateValidRorSchemas : SchemataFixutre {
    override string programFile() {
        return (testData ~ "schemata_ror.cpp").toString;
    }

    override void test() {
        mixin(EnvSetup(globalTestdir));
        precondition(testEnv);

        makeDextoolAnalyze(testEnv).addInputArg(programCode).addFlag("-std=c++11").run;

        auto r = runDextoolTest(testEnv).addPostArg(["--mutant", "rorp"]).addFlag("-std=c++11").run;
    }
}
