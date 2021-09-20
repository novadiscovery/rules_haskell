"""Rules for defining toolchains"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(":ghc_bindist.bzl", "haskell_register_ghc_bindists")
load(
    ":private/actions/compile.bzl",
    "compile_binary",
    "compile_library",
)
load(
    ":private/actions/link.bzl",
    "link_binary",
    "link_library_dynamic",
    "link_library_static",
    "merge_parameter_files",
)
load(":private/actions/package.bzl", "package")
load(":cc.bzl", "ghc_cc_program_args")
load(":private/validate_attrs.bzl", "check_deprecated_attribute_usage")

_GHC_BINARIES = ["ghc", "ghc-pkg", "hsc2hs", "haddock", "ghci", "runghc", "hpc"]
_ASTERIUS_BINARIES = {
    "ghc": "ahc",
    "ghc-pkg": "ahc-pkg",
    "hsc2hs": "hsc2hs",
    "haddock": "haddock",
    "ghci": "ghci",
    "runghc": "runghc",
    "hpc": "hpc",
}

def _run_ghc(hs, cc, inputs, outputs, mnemonic, arguments, env, params_file = None, progress_message = None, input_manifests = None):
    args = hs.actions.args()
    extra_inputs = []

    # Detect persistent worker support
    flagsfile_prefix = ""
    execution_requirements = {}
    tools = []
    if hs.worker != None:
        flagsfile_prefix = "@"
        execution_requirements = {"supports-workers": "1"}
        args.add(hs.worker.path)
        tools = [hs.worker]
    else:
        args.add(hs.tools.ghc)
        extra_inputs += [hs.tools.ghc]

    # XXX: We should also tether Bazel's CC toolchain to GHC's, so that we can properly mix Bazel-compiled
    # C libraries with Haskell targets.
    args.add_all(ghc_cc_program_args(hs, cc.tools.cc))

    compile_flags_file = hs.actions.declare_file("compile_flags_%s_%s" % (hs.name, mnemonic))
    extra_args_file = hs.actions.declare_file("extra_args_%s_%s" % (hs.name, mnemonic))

    args.set_param_file_format("multiline")
    arguments.set_param_file_format("multiline")
    hs.actions.write(compile_flags_file, args)
    hs.actions.write(extra_args_file, arguments)

    extra_inputs += [
        compile_flags_file,
        extra_args_file,
    ] + cc.files + hs.toolchain.bindir + hs.toolchain.libdir

    if hs.toolchain.locale_archive != None:
        extra_inputs.append(hs.toolchain.locale_archive)

    flagsfile = extra_args_file
    if params_file:
        flagsfile = merge_parameter_files(hs, extra_args_file, params_file)
        extra_inputs.append(flagsfile)

    if type(inputs) == type(depset()):
        inputs = depset(extra_inputs, transitive = [inputs])
    else:
        inputs += extra_inputs

    if input_manifests != None:
        input_manifests = input_manifests + cc.manifests
    else:
        input_manifests = cc.manifests

    sh_toolchain_path = ":".join(hs.toolchain.maybe_sh_toolchain.paths if hs.toolchain.maybe_sh_toolchain else [])
    nodejs_toolchain_path = ":".join([f.dirname for f in hs.toolchain.maybe_node_toolchain.nodeinfo.tool_files] if hs.toolchain.maybe_node_toolchain else [])

    # nodejs_toolchain_path = paths.dirname(hs.toolchain.maybe_node_toolchain.nodeinfo.target_tool_path) if hs.toolchain.maybe_node_toolchain else ""
    if sh_toolchain_path:
        if "PATH" in env and env["PATH"]:
            env["PATH"] = ":".join([env["PATH"], sh_toolchain_path])
        else:
            env["PATH"] = sh_toolchain_path

        # TODO: also add the sh_toolchain to tools ?
        # On nixos it is not needed because the path to the binaries are absolute.
        # But it may not always be the case.

    if nodejs_toolchain_path:
        if "PATH" in env and env["PATH"]:
            env["PATH"] = ":".join([env["PATH"], nodejs_toolchain_path])
        else:
            env["PATH"] = nodejs_toolchain_path
        tools.extend(hs.toolchain.maybe_node_toolchain.nodeinfo.tool_files)

    hs.actions.run(
        inputs = inputs,
        tools = tools,
        input_manifests = input_manifests,
        outputs = outputs,
        executable = hs.ghc_wrapper,
        mnemonic = mnemonic,
        progress_message = progress_message,
        env = env,
        arguments = [compile_flags_file.path, flagsfile_prefix + flagsfile.path],
        execution_requirements = execution_requirements,
    )

    return args

def _haskell_toolchain_impl(ctx):
    numeric_version = [int(x) for x in ctx.attr.version.split(".")]
    if numeric_version == [8, 10, 1] or numeric_version == [8, 10, 2]:
        fail("GHC 8.10.1 and 8.10.2 not supported. Upgrade to 8.10.3 or later.")

    # Store the binaries of interest in ghc_binaries.
    ghc_binaries = {}
    for tool in _GHC_BINARIES:
        for file in ctx.files.tools:
            if tool in ghc_binaries:
                continue
            basename_no_ext = paths.split_extension(file.basename)[0]
            if tool == basename_no_ext:
                ghc_binaries[tool] = file
            elif "%s-%s" % (tool, ctx.attr.version) == basename_no_ext:
                ghc_binaries[tool] = file
            elif _ASTERIUS_BINARIES[tool] == basename_no_ext:
                ghc_binaries[tool] = file
        if not tool in ghc_binaries:
            fail("Cannot find {} in {}".format(tool, ctx.attr.tools))

    # Get the libdir and docdir paths
    libdir = ctx.files.libdir
    if ctx.attr.libdir_path:
        libdir_path = ctx.attr.libdir_path
    elif libdir:
        # Find the `lib/settings` file and infer `libdir` from its path.
        for f in libdir:
            if f.path.endswith("lib/settings"):
                libdir_path = paths.dirname(f.path)
                break
        if libdir_path == None:
            fail("Could not infer `libdir_path` from provided `libdir` attribute. Missing `lib/settings` file.", "libdir")
    else:
        fail("One of `libdir` and `libdir_path` is required.")

    docdir = ctx.files.docdir
    if ctx.attr.docdir_path:
        docdir_path = ctx.attr.docdir_path
    elif docdir:
        # Find a file matching `html/libraries/base-*.*.*.*/*` and infer `docdir` from its path.
        # `GHC.Paths.docdir` reports paths such as `.../doc/html/libraries/base-4.13.0.0`.
        for f in docdir:
            html_start = f.path.find("html/libraries/base-")
            if html_start != -1:
                base_end = f.path.find("/", html_start + len("html/libraries/base-"))
                if base_end != -1:
                    docdir_path = f.path[:base_end]
                    break
        if docdir_path == None:
            fail("Could not infer `docdir_path` from provided `docdir` attribute. Missing `lib/settings` file.", "docdir")
    else:
        fail("One of `docdir` and `docdir_path` is required.")

    # Get the versions of every prebuilt package.
    ghc_pkg = ghc_binaries["ghc-pkg"]
    pkgdb_file = ctx.actions.declare_file("ghc-global-pkgdb")

    ctx.actions.run_shell(
        inputs = [ghc_pkg],
        outputs = [pkgdb_file],
        tools = ctx.files.tools if ctx.attr._asterius else [],
        mnemonic = "HaskellPackageDatabaseDump",
        command = "{ghc_pkg} dump --global > {output}".format(
            ghc_pkg = ghc_pkg.path,
            output = pkgdb_file.path,
        ),
    )

    tools_struct_args = {
        name.replace("-", "_"): file
        for name, file in ghc_binaries.items()
    }

    locale_archive = None

    if ctx.attr.locale_archive != None:
        locale_archive = ctx.file.locale_archive

    libraries = {
        lib.label.name: lib
        for lib in ctx.attr.libraries
    }

    (cc_wrapper_inputs, cc_wrapper_manifest) = ctx.resolve_tools(tools = [ctx.attr._cc_wrapper])
    cc_wrapper_info = ctx.attr._cc_wrapper[DefaultInfo]
    cc_wrapper_runfiles = cc_wrapper_info.default_runfiles.merge(
        cc_wrapper_info.data_runfiles,
    )

    return [
        platform_common.ToolchainInfo(
            name = ctx.label.name,
            tools = struct(**tools_struct_args),
            bindir = ctx.files.tools,
            libdir = libdir,
            libdir_path = libdir_path,
            docdir = docdir,
            docdir_path = docdir_path,
            ghcopts = ctx.attr.ghcopts,
            repl_ghci_args = ctx.attr.repl_ghci_args,
            haddock_flags = ctx.attr.haddock_flags,
            cabalopts = ctx.attr.cabalopts,
            locale = ctx.attr.locale,
            locale_archive = locale_archive,
            cc_wrapper = struct(
                executable = ctx.executable._cc_wrapper,
                inputs = cc_wrapper_inputs,
                manifests = cc_wrapper_manifest,
                runfiles = cc_wrapper_runfiles,
            ),
            mode = ctx.var["COMPILATION_MODE"],
            actions = struct(
                compile_binary = compile_binary,
                compile_library = compile_library,
                link_binary = link_binary,
                link_library_dynamic = link_library_dynamic,
                link_library_static = link_library_static,
                package = package,
                run_ghc = _run_ghc,
            ),
            libraries = libraries,
            is_darwin = ctx.attr.is_darwin,
            is_windows = ctx.attr.is_windows,
            static_runtime = ctx.attr.static_runtime,
            fully_static_link = ctx.attr.fully_static_link,
            version = ctx.attr.version,
            numeric_version = numeric_version,
            global_pkg_db = pkgdb_file,
            protoc = ctx.executable._protoc,
            rule_info_proto = ctx.attr._rule_info_proto,
            maybe_sh_toolchain = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"] if ctx.attr._asterius else None,
            maybe_node_toolchain = ctx.toolchains["@build_bazel_rules_nodejs//toolchains/node:toolchain_type"] if ctx.attr._asterius else None,
        ),
    ]

common_attrs = {
    "tools": attr.label_list(
        mandatory = True,
    ),
    "libraries": attr.label_list(
        mandatory = True,
    ),
    "libdir": attr.label_list(
        doc = "The files contained in GHC's libdir that Bazel should track. C.f. `ghc --print-libdir`. Do not specify this for a globally installed GHC distribution, e.g. a Nix provided one. One of `libdir` or `libdir_path` is required.",
    ),
    "libdir_path": attr.string(
        doc = "The absolute path to GHC's libdir. C.f. `ghc --print-libdir`. Specify this if `libdir` is left empty. One of `libdir` or `libdir_path` is required.",
    ),
    "docdir": attr.label_list(
        doc = "The files contained in GHC's docdir that Bazel should track. C.f. `GHC.Paths.docdir` from `ghc-paths`. Do not specify this for a globally installed GHC distribution, e.g. a Nix provided one. One of `docdir` or `docdir_path` is required.",
    ),
    "docdir_path": attr.string(
        doc = "The absolute path to GHC's docdir. C.f. `GHC.Paths.docdir` from `ghc-paths`. Specify this if `docdir` is left empty. One of `docdir` or `docdir_path` is required.",
    ),
    "ghcopts": attr.string_list(),
    "repl_ghci_args": attr.string_list(),
    "haddock_flags": attr.string_list(),
    "cabalopts": attr.string_list(),
    "version": attr.string(
        mandatory = True,
    ),
    "is_darwin": attr.bool(
        doc = "Whether compile on and for Darwin (macOS).",
        mandatory = True,
    ),
    "is_windows": attr.bool(
        doc = "Whether compile on and for Windows.",
        mandatory = True,
    ),
    "static_runtime": attr.bool(),
    "fully_static_link": attr.bool(),
    "locale": attr.string(
        default = "C.UTF-8",
        doc = "Locale that will be set during compiler invocations.",
    ),
    "locale_archive": attr.label(
        allow_single_file = True,
    ),
    "_cc_wrapper": attr.label(
        cfg = "host",
        default = Label("@rules_haskell//haskell:cc_wrapper"),
        executable = True,
    ),
    "_protoc": attr.label(
        executable = True,
        cfg = "host",
        default = Label("@com_google_protobuf//:protoc"),
    ),
    "_rule_info_proto": attr.label(
        allow_single_file = True,
        default = Label("@rules_haskell//rule_info:rule_info_proto"),
    ),
}

_ahc_haskell_toolchain = rule(
    _haskell_toolchain_impl,
    toolchains = [
        "@rules_sh//sh/posix:toolchain_type",
        "@build_bazel_rules_nodejs//toolchains/node:toolchain_type",
    ],
    attrs = dict(
        common_attrs,
        _asterius = attr.bool(default = True),
    ),
)

_haskell_toolchain = rule(
    _haskell_toolchain_impl,
    attrs = dict(
        common_attrs,
        _asterius = attr.bool(default = False),
    ),
)

def haskell_toolchain(
        name,
        version,
        static_runtime,
        fully_static_link,
        tools,
        libraries,
        asterius = False,
        compiler_flags = [],
        ghcopts = [],
        repl_ghci_args = [],
        haddock_flags = [],
        cabalopts = [],
        locale_archive = None,
        **kwargs):
    """Declare a compiler toolchain.

    You need at least one of these declared somewhere in your `BUILD` files
    for the other rules to work. Once declared, you then need to *register*
    the toolchain using `register_toolchains` in your `WORKSPACE` file (see
    example below).

    ### Examples

      In a `BUILD` file:

      ```bzl
      haskell_toolchain(
          name = "ghc",
          version = "1.2.3",
          static_runtime = static_runtime,
          fully_static_link = fully_static_link,
          tools = ["@sys_ghc//:bin"],
          ghcopts = ["-Wall"],
      )
      ```

      where `@sys_ghc` is an external repository defined in the `WORKSPACE`,
      e.g. using:

      ```bzl
      nixpkgs_package(
          name = 'sys_ghc',
          attribute_path = 'haskell.compiler.ghc822',
      )

      register_toolchains("//:ghc")
      ```

    Args:
      name: A unique name for this toolchain.
      version: Version of your GHC compiler. It has to match the version reported by the GHC used by bazel.
      static_runtime: Whether GHC was linked with a static runtime.
      fully_static_link: Whether GHC should build fully-statically-linked binaries.
      tools: GHC and executables that come with it. First item takes precedence.
      libraries: The set of libraries that come with GHC. Requires haskell_import targets.
      asterius: whether this is a toolchain based on asterius.
      ghcopts: A collection of flags that will be passed to GHC on every invocation.
      compiler_flags: DEPRECATED. Use new name ghcopts.
      repl_ghci_args: A collection of flags that will be passed to GHCI on repl invocation. It extends the `ghcopts` collection.\\
        Flags set here have precedance over `ghcopts`.
      haddock_flags: A collection of flags that will be passed to haddock.
      cabalopts: Additional flags to pass to `Setup.hs configure` for all Cabal rules.\\
        Note, Cabal rules do not read the toolchain attributes `ghcopts`, `compiler_flags` or `haddock_flags`.\\
        Use `--ghc-option=OPT` to configure additional compiler flags.\\
        Use `--haddock-option=OPT` to configure additional haddock flags.\\
        Use `--haddock-option=--optghc=OPT` if haddock generation requires additional compiler flags.
      locale_archive: Label pointing to the locale archive file to use.\\
        Linux-specific and mostly useful on NixOS.
      **kwargs: Common rule attributes. See [Bazel documentation](https://docs.bazel.build/versions/master/be/common-definitions.html#common-attributes).

    """
    corrected_ghci_args = repl_ghci_args + ["-no-user-package-db"]
    ghcopts = check_deprecated_attribute_usage(
        old_attr_name = "compiler_flags",
        old_attr_value = compiler_flags,
        new_attr_name = "ghcopts",
        new_attr_value = ghcopts,
    )

    toolchain_rule = _ahc_haskell_toolchain if asterius else _haskell_toolchain
    toolchain_rule(
        name = name,
        version = version,
        static_runtime = static_runtime,
        fully_static_link = fully_static_link,
        tools = tools,
        libraries = libraries,
        ghcopts = ghcopts,
        repl_ghci_args = corrected_ghci_args,
        haddock_flags = haddock_flags,
        cabalopts = cabalopts,
        is_darwin = select({
            "@rules_haskell//haskell/platforms:darwin": True,
            "//conditions:default": False,
        }),
        is_windows = select({
            "@rules_haskell//haskell/platforms:mingw32": True,
            "//conditions:default": False,
        }),
        # Ignore this attribute on any platform that is not Linux. The
        # LOCALE_ARCHIVE environment variable is a Linux-specific
        # Nixpkgs hack.
        locale_archive = select({
            "@rules_haskell//haskell/platforms:linux": locale_archive,
            "//conditions:default": None,
        }),
        **kwargs
    )

def rules_haskell_toolchains(
        version = None,
        compiler_flags = None,
        ghcopts = None,
        haddock_flags = None,
        repl_ghci_args = None,
        cabalopts = None,
        locale = None):
    """Register GHC binary distributions for all platforms as toolchains.

    Toolchains can be used to compile Haskell code. This function
    registers one toolchain for each known binary distribution on all
    platforms of the given GHC version. During the build, one
    toolchain will be selected based on the host and target platforms
    (See [toolchain resolution][toolchain-resolution]).

    [toolchain-resolution]: https://docs.bazel.build/versions/master/toolchains.html#toolchain-resolution

    Args:
      version: The desired GHC version
      locale: Locale that will be set during compiler
        invocations. Default: C.UTF-8 (en_US.UTF-8 on MacOS)
      compiler_flags: DEPRECATED. Use new name ghcopts.
      ghcopts: A collection of flags that will be passed to GHC on every invocation.

    """

    haskell_register_ghc_bindists(
        version = version,
        compiler_flags = compiler_flags,
        ghcopts = ghcopts,
        haddock_flags = haddock_flags,
        repl_ghci_args = repl_ghci_args,
        cabalopts = cabalopts,
        locale = locale,
    )
