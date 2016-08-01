// Written in the D programming language.
/**
Date: 2015-2016, Joakim Brännström
License: MPL-2, Mozilla Public License 2.0
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Generate a C test double implementation from data about the structural
representation.
*/
module plugin.backend.cvariant;

import std.typecons : Typedef, Flag;
import logger = std.experimental.logger;

import dsrcgen.cpp : CppModule, CppHModule;

import application.types;
import cpptooling.data.symbol.container;
import cpptooling.analyzer.clang.ast.visitor : Visitor;

/// Control various aspects of the analyze and generation like what nodes to
/// process.
@safe interface Controller {
    /// Query the controller with the filename of the AST node for a decision
    /// if it shall be processed.
    bool doFile(in string filename, in string info);

    /** A list of includes for the test double header.
     *
     * Part of the controller because they are dynamic, may change depending on
     * for example calls to doFile.
     */
    FileName[] getIncludes();

    /// Controls generation of google mock.
    bool doGoogleMock();

    /// Generate a pre_include header file from internal template?
    bool doPreIncludes();

    /// Generate a #include of the pre include header
    bool doIncludeOfPreIncludes();

    /// Generate a post_include header file from internal template?
    bool doPostIncludes();

    /// Generate a #include of the post include header
    bool doIncludeOfPostIncludes();

    /// Generate location of symbols as comments
    bool doLocationAsComment();
}

/// Parameters used during generation.
/// Important aspect that they do NOT change, therefore it is pure.
@safe pure interface Parameters {
    import std.typecons : Tuple;

    alias Files = Tuple!(FileName, "hdr", FileName, "impl", FileName, "globals",
            FileName, "gmock", FileName, "pre_incl", FileName, "post_incl");

    /// Source files used to generate the stub.
    FileName[] getIncludes();

    /// Output directory to store files in.
    DirName getOutputDirectory();

    /// Files to write generated test double data to.
    Files getFiles();

    /// Name affecting interface, namespace and output file.
    MainName getMainName();

    /** Namespace for the generated test double.
     *
     * Contains the adapter, C++ interface, gmock etc.
     */
    MainNs getMainNs();

    /** Name of the interface of the test double.
     *
     * Used in Adapter.
     */
    MainInterface getMainInterface();

    /** Prefix to use for the generated files.
     *
     * Affects both the filename and the preprocessor #include.
     */
    StubPrefix getFilePrefix();

    /// Prefix used for test artifacts.
    StubPrefix getArtifactPrefix();
}

/// Data produced by the generator like files.
@safe interface Products {
    /** Data pushed from the stub generator to be written to files.
     *
     * The put value is the code generation tree. It allows the caller of
     * Generator to inject more data in the tree before writing. For
     * example a custom header.
     *
     * Params:
     *   fname = file the content is intended to be written to.
     *   hdr_data = data to write to the file.
     */
    void putFile(FileName fname, CppHModule hdr_data);

    /// ditto.
    void putFile(FileName fname, CppModule impl_data);

    /** During the translation phase the location of symbols that aren't
     * filtered out are pushed to the variant.
     *
     * It is intended that the variant control the #include directive strategy.
     * Just the files that was input?
     * Deduplicated list of files where the symbols was found?
     */
    void putLocation(FileName loc, LocationType type);
}

/**
 *
 */
struct Generator {
    import std.typecons : Typedef;

    import cpptooling.data.representation : CppRoot;
    import cpptooling.utility.conv : str;

    static struct Modules {
        import plugin.utility : MakerInitializingClassMembers;

        mixin MakerInitializingClassMembers!Modules;

        CppModule hdr;
        CppModule impl;
        CppModule globals;
        CppModule gmock;
    }

    this(Controller ctrl, Parameters params, Products products) {
        this.ctrl = ctrl;
        this.params = params;
        this.products = products;
        this.raw = CppRoot.make;
    }

    /** Analyse and store the content of root.
     *
     * Analyse consist of a filtering.
     * filters the structural data.
     * Controller is involved to allow filtering of identifiers in files.
     */
    void analyse(ref CppRoot root, ref const(Container) container) {
        logger.trace("Raw:\n", root.toString());

        rawFilter(root, ctrl, products, raw);
        logger.tracef("Filtered:\n%s\n", raw.toString());
    }

    /** Process structural data to a test double.
     *
     * translate -> code generation.
     *
     * Translate analyzes what is left after filtering.
     * On demand extra data is created. An example of on demand is --gmock.
     *
     * Code generation is a straight up translation.
     * Logical decisions should have been handled in earlier stages.
     *
     * TODO refactor the control flow. Especially the gmock part.
     * TODO rename translate to rawFilter. See cppvariant.
     */
    auto process(ref const(Container) container) {
        makeImplStuff(raw, ctrl, params);

        logger.trace("Post processed:\n", raw.toString());

        auto m = Modules.make();
        generate(raw, ctrl, params, container, m.hdr, m.impl, m.globals, m.gmock);
        postProcess(m, ctrl, params, products);
    }

private:
    CppRoot raw;

    Controller ctrl;
    Parameters params;
    Products products;

    static void postProcess(Modules modules, Controller ctrl, Parameters params, Products prod) {
        import cpptooling.generator.includes : convToIncludeGuard,
            generatetPreInclude, generatePostInclude;

        /** Generate the C++ header file of the stub.
         * Params:
         *  filename = intended output filename, used for ifndef guard.
         */
        static auto outputHdr(CppModule hdr, FileName fname) {
            auto o = CppHModule(convToIncludeGuard(fname));
            o.content.append(hdr);

            return o;
        }

        static auto output(CppModule code, FileName incl_fname) {
            import std.path : baseName;

            auto o = new CppModule;
            o.suppressIndent(1);
            o.include(incl_fname.str.baseName);
            o.sep(2);
            o.append(code);

            return o;
        }

        prod.putFile(params.getFiles.hdr, outputHdr(modules.hdr, params.getFiles.hdr));
        prod.putFile(params.getFiles.impl, output(modules.impl, params.getFiles.hdr));
        prod.putFile(params.getFiles.globals, output(modules.globals, params.getFiles.hdr));

        if (ctrl.doPreIncludes) {
            prod.putFile(params.getFiles.pre_incl, generatetPreInclude(params.getFiles.pre_incl));
        }
        if (ctrl.doPostIncludes) {
            prod.putFile(params.getFiles.post_incl, generatePostInclude(params.getFiles.post_incl));
        }

        //TODO refactor. should never reach this stage.
        if (ctrl.doGoogleMock) {
            import cpptooling.generator.gmock : generateGmockHdr;

            prod.putFile(params.getFiles.gmock, generateGmockHdr(params.getFiles.hdr,
                    params.getFiles.gmock, modules.gmock));
        }
    }
}

final class CVisitor : Visitor {
    import std.typecons : scoped;

    import cpptooling.analyzer.clang.ast;
    import cpptooling.analyzer.clang.ast.visitor;
    import cpptooling.analyzer.clang.analyze_helper : analyzeFunctionDecl,
        analyzeVarDecl;
    import cpptooling.data.representation : CppRoot;
    import cpptooling.data.symbol.container : Container;
    import cpptooling.utility.clang : logNode, mixinNodeLog;

    alias visit = Visitor.visit;
    mixin generateIndentIncrDecr;

    CppRoot root;
    Container container;

    private {
        Controller ctrl;
        Products prod;
    }

    this(Controller ctrl, Products prod) {
        this.ctrl = ctrl;
        this.prod = prod;
        this.root = CppRoot(LocationTag(null));
    }

    override void visit(const(VarDecl) v) @trusted {
        import cpptooling.data.type : TypeKindVariable;
        import deimos.clang.index : CX_StorageClass;

        mixin(mixinNodeLog!());

        //TODO ugly hack. Move this information to the representation. But for
        //now skipping all definitions
        if (v.cursor.storageClass() == CX_StorageClass.CX_SC_Extern) {
            auto result = analyzeVarDecl(v, container, indent);
            auto var = CxGlobalVariable(TypeKindVariable(result.type, result.name), result.location);
            root.put(var);
        }
    }

    override void visit(const(FunctionDecl) v) {
        import cpptooling.data.type : CxReturnType;

        mixin(mixinNodeLog!());

        auto result = analyzeFunctionDecl(v, container, indent);
        if (result.isValid) {
            auto func = CFunction(result.name, result.params, CxReturnType(result.returnType),
                    result.isVariadic, result.storageClass, result.location);
            root.put(func);
        }
    }

    override void visit(const(TranslationUnit) v) {
        import cpptooling.generator.utility : validLocation;
        import cpptooling.analyzer.clang.type : makeLocation;

        mixin(mixinNodeLog!());

        LocationTag tu_loc;
        () @trusted{ tu_loc = LocationTag(Location(v.cursor.spelling, 0, 0)); }();

        foreach (loc; tu_loc.validLocation!(a => ctrl.doFile(a.file, "root " ~ a.toString))) {
            prod.putLocation(FileName(loc.file), LocationType.Root);
        }

        v.accept(this);
    }

    void toString(Writer)(scope Writer w) @safe const {
        root.toString(w);
    }

    override string toString() const {
        import std.exception : assumeUnique;

        char[] buf;
        buf.reserve(100);
        toString((const(char)[] s) { buf ~= s; });
        auto trustedUnique(T)(T t) @trusted {
            return assumeUnique(t);
        }

        return trustedUnique(buf);
    }
}

private:
@safe:

import cpptooling.data.representation : CppRoot, CppClass, CppMethod, CppCtor,
    CppDtor, CFunction, CppNamespace, CxGlobalVariable;
import cpptooling.data.type : LocationTag, Location;
import dsrcgen.cpp : E;

auto dummyLoc() {
    return LocationTag(Location("<test double>", 0, 0));
}

enum ClassType {
    Normal,
    Adapter,
    Gmock
}

enum NamespaceType {
    Normal,
    TestDoubleSingleton,
    TestDouble
}

/** Structurally transformed the input to a stub implementation.
 *
 * This stage:
 *  - removes C++ code.
 *  - removes according to directives via ctrl.
 */
void rawFilter(ref CppRoot input, Controller ctrl, Products prod, ref CppRoot raw) {
    import std.algorithm : filter, each;
    import cpptooling.data.representation : StorageClass;
    import cpptooling.generator.utility : storeValidLocations,
        filterAnyLocation;

    // dfmt off
    input.funcRange
        // by definition static functions can't be replaced by test doubles
        .filter!(a => a.storageClass != StorageClass.Static)
        // ask controller if to generate a test double for the function
        .filterAnyLocation!((value, loc) => ctrl.doFile(loc.file, cast(string) value.name ~ " " ~ loc.toString))
        // pass on location as a product to be used to calculate #include
        .storeValidLocations!(a => prod.putLocation(FileName(a.file), LocationType.Leaf))
        .each!(a => raw.put(a));

    input.globalRange()
        // ask controller if to generate a definitions
        .filterAnyLocation!((value, loc) => ctrl.doFile(loc.file, cast(string) value.name ~ " " ~ loc.toString))
        // pass on location as a product to be used to calculate #include
        .storeValidLocations!(a => prod.putLocation(FileName(a.file), LocationType.Leaf))
        .each!(a => raw.put(a));
    // dfmt on
}

/** Make stuff in root needed for the implementation IF root has any C functions.
 *
 * Make an adapter.
 * Make a namespace holding the test double.
 * Make a google mock if asked by the user.
 */
void makeImplStuff(ref CppRoot root, Controller ctrl, Parameters params) {
    import cpptooling.data.representation : CppNamespace, CppNs;
    import cpptooling.generator.func : makeFuncInterface;
    import cpptooling.generator.adapter : makeSingleton;
    import cpptooling.utility.conv : str;

    alias makeTestDoubleAdapter = cpptooling.generator.adapter.makeAdapter!(
            MainInterface, ClassType);

    if (root.funcRange.empty) {
        return;
    }

    root.put(makeSingleton!NamespaceType(params.getMainNs, params.getMainInterface));

    auto ns = CppNamespace.make(CppNs(params.getMainNs.str));
    ns.setKind(NamespaceType.TestDouble);

    auto c_if = makeFuncInterface(root.funcRange, params.getMainInterface);

    ns.put(c_if);
    if (ctrl.doGoogleMock) {
        // could reuse.. don't.
        auto mock = c_if;
        mock.setKind(ClassType.Gmock);
        ns.put(mock);
    }
    ns.put(makeTestDoubleAdapter(params.getMainInterface));
    root.put(ns);
}

void generate(ref CppRoot r, Controller ctrl, Parameters params, const ref Container container,
        CppModule hdr, CppModule impl, CppModule globals, CppModule gmock) {
    import std.algorithm : each;
    import std.array;
    import cpptooling.utility.conv : str;
    import cpptooling.generator.func : generateFuncImpl;
    import cpptooling.generator.includes;

    generateWrapIncludeInExternC(ctrl, params, hdr);

    auto global_macros = globals.base;
    global_macros.suppressIndent(1);
    globals.sep;
    auto global_definitions = globals.base;
    global_definitions.suppressIndent(1);

    foreach (a; r.globalRange) {
        generateCGlobalPreProcessorDefine(a, params.getArtifactPrefix.str, global_macros);
        generateCGlobalDefinition(a, cast(Flag!"locationAsComment") ctrl.doLocationAsComment,
                params.getArtifactPrefix.str, container, global_definitions);
    }

    foreach (ns; r.namespaceRange) {
        import cpptooling.generator.adapter : generateSingleton;

        final switch (cast(NamespaceType) ns.kind) {
        case NamespaceType.Normal:
            break;
        case NamespaceType.TestDoubleSingleton:
            generateSingleton(ns, impl);
            break;
        case NamespaceType.TestDouble:
            generateNsTestDoubleHdr(ns,
                    cast(Flag!"locationAsComment") ctrl.doLocationAsComment, params, hdr, gmock);
            generateNsTestDoubleImpl(ns, params, impl);
            break;
        }
    }

    // The generated functions must be extern C declared.
    auto extern_c = impl.suite("extern \"C\"");
    extern_c.suppressIndent(1);
    foreach (a; r.funcRange) {
        generateFuncImpl(a, extern_c);
    }
}

void generateCGlobalPreProcessorDefine(ref CxGlobalVariable g, string prefix, CppModule code) {
    import std.string : toUpper;
    import cpptooling.utility.conv : str;
    import cpptooling.analyzer.type : TypeKind, toStringDecl, toRepr;

    auto d_name = E((prefix ~ "Init_").toUpper ~ g.name.str);
    auto ifndef = code.IFNDEF(d_name);

    // example: #define TEST_INIT_extern_a int extern_a[4]
    final switch (g.type.kind.info.kind) with (TypeKind.Info) {
    case Kind.array:
    case Kind.func:
    case Kind.funcPtr:
    case Kind.pointer:
    case Kind.record:
    case Kind.simple:
    case Kind.typeRef:
        ifndef.define(d_name ~ E(g.type.toStringDecl(g.name.str)));
        break;
    case Kind.ctor:
        // a C test double shold never have preprocessor macros for a C++ ctor
        assert(false);
    case Kind.dtor:
        // a C test double shold never have preprocessor macros for a C++ dtor
        assert(false);
    case Kind.null_:
        logger.error("Type of global definition is null. Identifier ", g.name.str);
        break;
    }
}

void generateCGlobalDefinition(ref CxGlobalVariable g, Flag!"locationAsComment" loc_as_comment,
        string prefix, const ref Container container, CppModule code)
in {
    import std.algorithm : among;
    import cpptooling.analyzer.type : TypeKind;

    assert(!g.type.kind.info.kind.among(TypeKind.Info.Kind.ctor, TypeKind.Info.Kind.dtor));
}
body {
    import std.format : format;
    import std.string : toUpper;
    import cpptooling.utility.conv : str;
    import cpptooling.analyzer.type;

    string d_name = (prefix ~ "Init_").toUpper ~ g.name.str;

    if (loc_as_comment && g.location.kind == LocationTag.Kind.loc) {
        code.comment("Origin " ~ g.location.toString)[$.begin = "/// "];
    }
    code.stmt(d_name);
}

void generateClassHdr(ref CppClass c, CppModule hdr, CppModule gmock,
        Flag!"locationAsComment" loc_as_comment, Parameters params) {
    import cpptooling.generator.classes : generateHdr;
    import cpptooling.generator.gmock : generateGmock;

    final switch (cast(ClassType) c.kind()) {
    case ClassType.Normal:
    case ClassType.Adapter:
        generateHdr(c, hdr, loc_as_comment);
        break;
    case ClassType.Gmock:
        generateGmock!Parameters(c, gmock, params);
        break;
    }
}

void generateClassImpl(ref CppClass c, CppModule impl) {
    import cpptooling.generator.adapter : generateClassImplAdapter = generateImpl;

    final switch (cast(ClassType) c.kind()) {
    case ClassType.Normal:
        break;
    case ClassType.Adapter:
        generateClassImplAdapter(c, impl);
        break;
    case ClassType.Gmock:
        break;
    }
}

void generateNsTestDoubleHdr(ref CppNamespace ns, Flag!"locationAsComment" loc_as_comment,
        Parameters params, CppModule hdr, CppModule gmock) {
    import std.algorithm : each;
    import cpptooling.utility.conv : str;

    auto cpp_ns = hdr.namespace(ns.name.str);
    cpp_ns.suppressIndent(1);
    hdr.sep(2);

    ns.classRange().each!((a) {
        generateClassHdr(a, cpp_ns, gmock, loc_as_comment, params);
    });
}

void generateNsTestDoubleImpl(ref CppNamespace ns, Parameters params, CppModule impl) {
    import std.algorithm : each;
    import cpptooling.utility.conv : str;

    auto cpp_ns = impl.namespace(ns.name.str);
    cpp_ns.suppressIndent(1);
    impl.sep(2);

    ns.classRange().each!((a) { generateClassImpl(a, cpp_ns); });
}
