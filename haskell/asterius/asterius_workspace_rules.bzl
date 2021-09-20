load("@bazel_skylib//lib:paths.bzl", "paths")
load(
    "//haskell:private/workspace_utils.bzl",
    "default_constraints",
    "define_rule",
    "execute_or_fail_loudly",
    "find_python",
    "resolve_labels",
)
load("//haskell:private/validate_attrs.bzl", "check_deprecated_attribute_usage")
load(
    "//haskell:private/pkgdb_to_bzl.bzl",
    "pkgdb_to_bzl",
)
load(
    "//haskell/platforms:list.bzl",
    "arch_of_exec_constraints",
    "os_of_exec_constraints",
)

AHC_BINDIST = \
    {
        "0.0.1": {
            "darwin_x86_64": (
                "https://github.com/ylecornec/test_bundle/releases/download/test/asterius_bundle.tar.gz",
                "8b2321e7aef4486ad3e5eb516189da864bd200db85ef041eff1b68788cf22f30",
            ),
            "linux_x86_64": (
                "https://github.com/ylecornec/test_bundle/releases/download/test/asterius_bundle.tar.gz",
                "8b2321e7aef4486ad3e5eb516189da864bd200db85ef041eff1b68788cf22f30",
            ),
            "windows_x86_64": (
                "https://github.com/ylecornec/test_bundle/releases/download/test/asterius_bundle.tar.gz",
                "8b2321e7aef4486ad3e5eb516189da864bd200db85ef041eff1b68788cf22f30",
            ),
        },
    }

AHC_DEFAULT_VERSION = "0.0.1"

def labels_from_bundle_name(bundle_repo_name, asterius_version):
    """"""
    return (
        "@{}//:asterius-{}_data/.boot/asterius_lib/settings".format(
            bundle_repo_name,
            asterius_version,
        ),
        "@{}//:test/wrappers/ahc-pkg".format(bundle_repo_name),
        "@{}//:asterius_binaries".format(bundle_repo_name),
        "@{}//:local_asterius".format(bundle_repo_name),
    )

def ghc_platform_info(repository_ctx, ghc_label):
    """ Recovers platform info through ghc --info.

    Args:
      repository_ctx: repository context.
      ghc_label: The label of the ghc binary of interest.
    """
    ghc_path = repository_ctx.path(ghc_label)
    command = [
        find_python(repository_ctx),
        repository_ctx.path(Label("@rules_haskell//haskell:private/ghc_info_utils.py")),
        ghc_path,
    ]
    ghc_info = execute_or_fail_loudly(repository_ctx, command).stdout.strip()
    print(ghc_info)

    # TODO : parse output of ghc --info
    # for now we assume that:
    # ("Host platform","x86_64-unknown-linux")
    # ("Target platform","x86_64-unknown-linux")
    target_os = "linux"
    target_arch = "x86_64"
    exec_os = "linux"  # read from Host platform from ghc --info
    exec_arch = "x86_64"
    return (struct(
        target_os = target_os,
        target_arch = target_arch,
        exec_os = exec_os,
        exec_arch = exec_arch,
    ))

# TODO: does it make sens to only specify one of cpu/os ?
# If if does, this may need to be changed.

def _asterius_bundle_impl(repository_ctx):
    version = repository_ctx.attr.version
    print("got exec constraints = ", repository_ctx.attr.exec_constraints)
    if repository_ctx.attr.exec_constraints == []:
        # We do the same thing as in the _ghc_nixpkgs_toolchain rule.
        (_, exec_constraints) = default_constraints(repository_ctx)
        exec_constraints = [Label(c) for c in exec_constraints]
        print("got exec_constraints through default_constraints = ", exec_constraints)
    else:
        exec_constraints = repository_ctx.attr.exec_constraints

    exec_os = os_of_exec_constraints(exec_constraints)
    if exec_os == None:
        fail("Could not find os in constraints {}".format(exec_constraints))

    exec_arch = arch_of_exec_constraints(exec_constraints)
    if exec_arch == None:
        fail("Could not find arch in constraints {}".format(exec_constraints))

    exec_platform = "{}_{}".format(exec_os, exec_arch)
    if version not in AHC_BINDIST or AHC_BINDIST[version].get(exec_platform) == None:
        fail("Operating system {0} does not have a bindist for Asterius version {1}".format(exec_platform, version))
    else:
        url, sha256 = AHC_BINDIST[version][exec_platform]

    # bindist_dir = ctx.path(".")  # repo path

    # repository_ctx.name
    repository_ctx.download_and_extract(
        url = url,
        output = "",
        sha256 = sha256,
    )

# we may need a repository rule to use the BUILD file from the bundle.
asterius_bundle = repository_rule(
    _asterius_bundle_impl,
    local = False,
    attrs = {
        "version": attr.string(),
        "exec_constraints": attr.label_list(),
    },
)

def _ahc_bindist_toolchain_impl(ctx):
    # os_mapping = {
    #     "darwin": "@platforms//os:osx",
    #     "linux": "@platforms//os:linux",
    #     "windows": "@platforms//os:windows",
    # }
    # os_exec_constraint = os_mapping.get(ctx.attr.exec_os)
    # arch_exec_constraint = ARCH.get(ctx.attr.exec_arch)
    # if not os_exec_constraint:
    #     fail("Operating system {} is not part of known systems ({})".format(ctx.attr.exec_os, os_mapping.keys()))
    # if not arch_exec_constraint:
    #     fail("Arch {} is not part of known ones ({})".format(ctx.attr.exec_arch, ARCH.keys()))
    # exec_constraints = [os_exec_constraint, arch_exec_constraint]
    #target_constraints = [os_mapping.get(ctx.attr.target_os), "@platforms//cpu:wasm32"]
    if ctx.attr.exec_constraints == None:
        (_, exec_constraints) = default_constraints(ctx)
    else:
        exec_constraints = ctx.attr.exec_constraints

    exec_constraints = [str(c) for c in ctx.attr.exec_constraints]
    target_constraints = ["@rules_haskell//haskell:with_asterius"]

    #target_constraints = [os_mapping.get(ctx.attr.target_os)]
    ctx.file(
        "BUILD",
        executable = False,
        content = """
toolchain(
    name = "toolchain",
    toolchain_type = "@rules_haskell//haskell:toolchain",
    toolchain = "@{bindist_name}//:toolchain-impl",
    exec_compatible_with = {exec_constraints},
    target_compatible_with = {target_constraints},
)

toolchain(
    name = "asterius_toolchain",
    toolchain_type = "@rules_haskell//haskell:asterius-toolchain",
    toolchain = "@{bindist_name}//:asterius-toolchain-impl",
    exec_compatible_with = {exec_constraints},
    # target_compatible_with = {target_constraints},
)
        """.format(
            bindist_name = ctx.attr.bindist_name,
            exec_constraints = exec_constraints,
            target_constraints = target_constraints,
        ),
    )

_ahc_bindist_toolchain = repository_rule(
    _ahc_bindist_toolchain_impl,
    local = False,
    attrs = {
        "bindist_name": attr.string(),
        "exec_constraints": attr.label_list(),
    },
)

def _ahc_bindist_impl(ctx):
    filepaths = resolve_labels(ctx, [
        "@rules_haskell//haskell:ghc.BUILD.tpl",
        "@rules_haskell//haskell:private/pkgdb_to_bzl.py",
    ])
    lib_path = str(ctx.path(ctx.attr.asterius_lib_setting_file).dirname)
    ahc_pkg_path = ctx.path(ctx.attr.ahc_pkg)
    print("ahc_pkg_path=", ahc_pkg_path)

    docdir_path = execute_or_fail_loudly(ctx, [ahc_pkg_path, "field", "base", "haddock-html", "--simple-output"]).stdout.strip()
    ctx.symlink(lib_path, "asterius_lib")

    toolchain_libraries = pkgdb_to_bzl(ctx, filepaths, paths.basename(lib_path))

    # TODO: Do we also need this when using asterius ?
    # locale = ctx.attr.locale or ("en_US.UTF-8" if ctx.attr.target_os == "darwin" else "C.UTF-8")
    locale = ctx.attr.locale or "en_US.UTF-8"
    non_asterius_binaries = "@{}//:bin".format(ctx.attr.ghc_repo_name)
    toolchain = define_rule(
        "haskell_toolchain",
        name = "toolchain-impl",
        asterius = True,
        tools =
            [
                str(ctx.attr.asterius_binaries),
                str(ctx.attr.full_bundle),
                non_asterius_binaries,
            ],
        libraries = "toolchain_libraries",
        libdir_path = "\"{}\"".format(paths.basename(lib_path)),
        docdir_path = "\"{}\"".format(docdir_path),
        version = repr(ctx.attr.version),
        static_runtime = True,
        fully_static_link = True,
        ghcopts = ctx.attr.ghcopts,
        haddock_flags = ctx.attr.haddock_flags,
        repl_ghci_args = ctx.attr.repl_ghci_args,
        cabalopts = ctx.attr.cabalopts,
        locale = repr(locale),
    )

    asterius_toolchain = define_rule(
        "asterius_toolchain",
        name = "asterius-toolchain-impl",
        binaries = [str(ctx.attr.asterius_binaries)],
        tools = [str(ctx.attr.full_bundle)],
    )

    ctx.template(
        "BUILD",
        filepaths["@rules_haskell//haskell:ghc.BUILD.tpl"],
        substitutions = {
            "%{toolchain_libraries}": toolchain_libraries,
            "%{toolchain}": toolchain,
            "%{asterius_toolchain}": asterius_toolchain,
        },
        executable = False,
    )

_ahc_bindist = repository_rule(
    _ahc_bindist_impl,
    local = False,
    attrs = {
        "version": attr.string(
            default = AHC_DEFAULT_VERSION,
            values = AHC_BINDIST.keys(),
            doc = "The desired Asterius version",
        ),
        # "target_os": attr.string(),
        # "exec_os": attr.string(),
        # "exec_arch": attr.string(),
        # "non_asterius_binaries": attr.string(),
        #"ghc": attr.label(mandatory = True),
        "ghc_repo_name": attr.string(),
        "ghcopts": attr.string_list(),
        "haddock_flags": attr.string_list(),
        "repl_ghci_args": attr.string_list(),
        "cabalopts": attr.string_list(),
        "locale": attr.string(
            mandatory = False,
        ),
        "asterius_lib_setting_file": attr.label(),
        "ahc_pkg": attr.label(doc = "Label for the ahc_pkg binary"),
        "asterius_binaries": attr.label(
            doc = "Filegroup with the asterius binaries.",
        ),
        "full_bundle": attr.label(
            doc = "Filegroup with the full bundle, which is necessary for the binaries to run.",
        ),
    },
)

def ahc_bindist(
        name,
        version,
        exec_constraints,
        ghc_repo_name,
        asterius_lib_setting_file,
        ahc_pkg,
        asterius_binaries,
        full_bundle,
        compiler_flags = None,
        ghcopts = None,
        haddock_flags = None,
        repl_ghci_args = None,
        cabalopts = None,
        locale = None):
    ghcopts = check_deprecated_attribute_usage(
        old_attr_name = "compiler_flags",
        old_attr_value = compiler_flags,
        new_attr_name = "ghcopts",
        new_attr_value = ghcopts,
    )

    bindist_name = name
    toolchain_name = "{}-toolchain".format(name)

    _ahc_bindist(
        name = bindist_name,
        version = version,
        # exec_constraints = exec_constraints,
        # target_constraints = target_constraints,
        ghc_repo_name = ghc_repo_name,
        ghcopts = ghcopts,
        haddock_flags = haddock_flags,
        repl_ghci_args = repl_ghci_args,
        cabalopts = cabalopts,
        locale = locale,
        asterius_lib_setting_file = asterius_lib_setting_file,
        ahc_pkg = ahc_pkg,
        asterius_binaries = asterius_binaries,
        full_bundle = full_bundle,
    )

    _ahc_bindist_toolchain(
        name = toolchain_name,
        bindist_name = bindist_name,
        exec_constraints = exec_constraints,
    )
    native.register_toolchains("@{}//:toolchain".format(toolchain_name))
    native.register_toolchains("@{}//:asterius_toolchain".format(toolchain_name))
