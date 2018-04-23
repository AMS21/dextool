/**
Copyright: Copyright (c) 2017, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module dextool_test.mutate_abs;

import dextool_test.utility;

// dfmt off

@("shall produce all ABS mutations")
unittest {
    mixin(EnvSetup(globalTestdir));

    makeDextoolAnalyze(testEnv)
        .addInputArg(testData ~ "abs.cpp")
        .run;
    auto r = makeDextool(testEnv)
        .addArg(["test"])
        .addArg(["--mutant", "abs"])
        .run;

    testAnyOrder!SubStr([
        "abs_dextool(a + b)",
        "-abs_dextool(a + b)",
        "fail_on_zero_dextool(a + b)",
        "abs_dextool(a)",
        "-abs_dextool(a)",
        "fail_on_zero_dextool(a)",
        "abs_dextool(b)",
        "-abs_dextool(b)",
        "fail_on_zero_dextool(b)",
    ]).shouldBeIn(r.stdout);
}

@("shall produce an ABS mutation")
unittest {
    mixin(EnvSetup(globalTestdir));

    immutable dst = testEnv.outdir ~ "abs.cpp";

    copy(testData ~ "abs.cpp", dst);

    makeDextoolAnalyze(testEnv)
        .addInputArg(dst)
        .run;
    auto r = dextool_test.makeDextool(testEnv)
        .setWorkdir(workDir)
        .args(["mutate"])
        .addArg(["generate"])
        .addArg(["--id", "5"])
        .addPostArg(["--db", (testEnv.outdir ~ defaultDb).toString])
        .run;

    testAnyOrder!SubStr([
        "abs_dextool(a + b)",
    ]).shouldBeIn(readOutput(testEnv, "abs.cpp"));
}
