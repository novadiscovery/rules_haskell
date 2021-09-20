# Setup a toolchain for the asterius binaries which are outside of the
# scope of the haskell toolchain. (ahc-link, ahc-dist and ahc-cabal)

load("//haskell:providers.bzl", "HaskellInfo")
load("@bazel_skylib//lib:new_sets.bzl", "sets")
load("@bazel_skylib//lib:paths.bzl", "paths")

# load("@npm//webpack-cli:index.bzl", webpack = "webpack_cli")

load("@build_bazel_rules_nodejs//:index.bzl", "nodejs_binary", "nodejs_test", "npm_package_bin")

def _asterius_toolchain_impl(ctx):
    asterius_binaries = sets.make(["ahc-link", "ahc-dist", "ahc-cabal"])
    found_binaries = {}
    for file in ctx.files.binaries:
        basename_no_ext = paths.split_extension(file.basename)[0]
        if sets.contains(asterius_binaries, basename_no_ext):
            found_binaries[basename_no_ext] = file
    not_found = sets.difference(asterius_binaries, sets.make(found_binaries.keys()))
    if sets.length(not_found) != 0:
        fail("Some binaries where not found when defining the asterius toolchain: {}".format(not_found))

    return [
        platform_common.ToolchainInfo(
            name = ctx.label.name,
            ahc_link = found_binaries["ahc-link"],
            ahc_dist = found_binaries["ahc-dist"],
            ahc_cabal = found_binaries["ahc-cabal"],
            tools = ctx.files.tools,
        ),
    ]

asterius_toolchain = rule(
    _asterius_toolchain_impl,
    # toolchains = ["@rules_sh//sh/posix:toolchain_type"],
    attrs = {
        "binaries": attr.label_list(
            mandatory = True,
            doc = "The asterius top level wrappers",
        ),
        "tools": attr.label_list(
            mandatory = True,
            doc = "The complete asterius bundle, which is needed to execute the wrappers.",
        ),
    },
)

def _asterius_transition(settings, attr):
    return {"//command_line_option:platforms": "@rules_haskell//haskell:asterius_platform"}

asterius_transition = transition(
    implementation = _asterius_transition,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

AhcDistInfo = provider(
    "Info about the output files of ahc_dist.",
    fields = {
        "target": "one of node or desktop",
        "webpack_config": "The webpack_config file that may be used by the asterius_webpack rule ",
        "entrypoint": "The entrypoint js file",
    },
)

javascript_runtime_modules = [
    "rts.autoapply.mjs",
    "rts.closuretypes.mjs",
    "rts.constants.mjs",
    "rts.eventlog.mjs",
    "rts.exception.mjs",
    "rts.exports.mjs",
    "rts.float.mjs",
    "rts.fs.mjs",
    "rts.funtypes.mjs",
    "rts.gc.mjs",
    "rts.heapalloc.mjs",
    "rts.integer.mjs",
    "rts.jsval.mjs",
    "rts.memory.mjs",
    "rts.memorytrap.mjs",
    "rts.messages.mjs",
    "rts.mjs",
    "rts.modulify.mjs",
    "rts.reentrancy.mjs",
    "rts.scheduler.mjs",
    "rts.setimmediate.mjs",
    "rts.stablename.mjs",
    "rts.stableptr.mjs",
    "rts.staticptr.mjs",
    "rts.symtable.mjs",
    "rts.time.mjs",
    "rts.tracing.mjs",
    "rts.unicode.mjs",
    "rts.wasi.mjs",
    "default.mjs",
]

# Label of the template file to use.
_TEMPLATE = "//haskell/asterius:asterius_webpack_config.js.tpl"

def _ahc_dist_impl(ctx):
    rule_name = ctx.label.name
    print("rule_name=", rule_name)
    print("main_out label=", ctx.attr.main_output)
    print("main_out name=", ctx.attr.main_output.name)

    # sh_toolchain = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    asterius_toolchain = ctx.toolchains["@rules_haskell//haskell:asterius-toolchain"]
    posix_info = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]

    nodejs_toolchain = ctx.toolchains["@build_bazel_rules_nodejs//toolchains/node:toolchain_type"]
    node_toolfiles = nodejs_toolchain.nodeinfo.tool_files

    all_output_files = [ctx.outputs.main_output]

    # declare the runtime modules
    for m in javascript_runtime_modules:
        f = ctx.actions.declare_file(m)
        all_output_files.append(f)

    file = ctx.file.dep

    (output_prefix, _) = paths.split_extension(ctx.outputs.main_output.basename)
    for ext in [".wasm", ".wasm.mjs", ".req.mjs"]:
        p = "{}{}".format(output_prefix, ext)
        f = ctx.actions.declare_file(p)
        all_output_files.append(f)

    # file was generated in the asterius platform configuration,
    # and we want to generate js files in the current configuration.
    # So we copy it to the folder corresponding to the current platform.
    file_copy_path = paths.join(all_output_files[0].dirname, ctx.file.dep.basename)
    entrypoint_path = paths.replace_extension(file_copy_path, ".mjs")

    browser = " --browser" if ctx.attr.target == "browser" else ""
    command = " && ".join([
        "cp $2 $3",
        "$1 --input-exe $3 --verbose --output-prefix {} {}".format(output_prefix, browser),
    ])
    ctx.actions.run_shell(
        inputs = [ctx.file.dep],
        outputs = all_output_files,
        command = command,
        env = {"PATH": ":".join(posix_info.paths + [node_toolfiles[0].dirname])},
        arguments = [
            asterius_toolchain.ahc_dist.path,
            ctx.file.dep.path,
            file_copy_path,
        ],
        tools = asterius_toolchain.tools + node_toolfiles + ctx.files.tools,
    )

    webpack_config = ctx.actions.declare_file("{}.webpack.config.js".format(ctx.label.name))
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = webpack_config,
        substitutions = {
            "{ENTRY}": ctx.outputs.main_output.basename,
        },
    )

    all_output_files.append(webpack_config)

    return [
        DefaultInfo(files = depset(all_output_files)),
        AhcDistInfo(
            target = ctx.attr.target,
            entrypoint = ctx.outputs.main_output,
            webpack_config = webpack_config,
        ),
    ]

# def _only_entrypoint_impl(ctx):
#     entrypoint_file = ctx.attr.ahc_dist[AhcDistInfo].entrypoint
#     return [DefaultInfo(files=depset([entrypoint_file]))]

# only_entrypoint = rule(
#     _only_entrypoint_impl,
#     attrs = {
#         "ahc_dist" : attr.label(
#             mandatory = True,
#             doc = "The ahc_dist target of interest.",
#         )
#     }
# )

ahc_dist = rule(
    _ahc_dist_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
            allow_single_file = True,
            cfg = asterius_transition,
        ),
        "target": attr.string(
            mandatory = True,
            values = ["browser", "node"],
            doc = """
            Whether the build output is intended to run with node, or on the browser.
            The asterius_webpack rule only accepts dependencies built for the browser.
            """,
        ),
        "main_output": attr.output(
            mandatory = True,
            doc = "The name for the output file corresponding to the entrypoint. It must terminate by '.mjs'",
        ),
        "tools": attr.label_list(),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
        "_template": attr.label(
            default = Label(_TEMPLATE),
            allow_single_file = True,
        ),
    },
    # exec_groups = {
    #     "exec": exec_group(
    #         toolchains = [
    #             "@build_bazel_rules_nodejs//toolchains/node:toolchain_type",
    #         ],
    #     )},
    toolchains = [
        "@rules_sh//sh/posix:toolchain_type",
        "@rules_haskell//haskell:asterius-toolchain",
        "@build_bazel_rules_nodejs//toolchains/node:toolchain_type",
    ],
)

# def paths_of_tools(tools):
#     path = sets.make()
#     for d in tools:
#         for f in d.files.to_list():
#             sets.insert(path, paths.dirname(f.path))
#     return sets.to_list(path)

def asterius_webpack_impl(ctx):
    ahc_dist_info = ctx.attr.dep[AhcDistInfo]
    print(ctx.attr.dep.label)
    if ahc_dist_info.target != "browser":
        fail("{} was built with target attribute '{}' but rule asterius_webpack_impl only works with the 'browser' target.".format(
            ctx.attr.dep.label,
            ahc_dist_info.target,
        ))

    output_file = ctx.actions.declare_file("{}.mjs".format(ctx.label.name))
    posix_info = ctx.toolchains["@rules_sh//sh/posix:toolchain_type"]
    all_paths = posix_info.paths + [paths.dirname(ctx.executable._webpack.path)]

    # webpack_config_path = None
    # for f in ctx.attr.dep[DefaultInfo].files.to_list():
    #     if f.basename == "webpack.config.js":
    #         webpack_config_path = f.path
    # if not webpack_config_path:
    #     fail("rule {} did not create a webpack.config.js".format(ctx.attr.dep.label))

    webpack_config_path = ahc_dist_info.webpack_config.path
    print("output_file.basename=", output_file.basename)
    print("output_file.path=", output_file.path)
    ctx.actions.run_shell(
        inputs = ctx.files.dep,
        outputs = [output_file],
        command = " ".join([
            "webpack.sh",
            "--nobazel_node_patches ",
            "--config",
            webpack_config_path,
            "-o .",
            "--output-filename",
            output_file.path,
        ]),
        env = {"PATH": ":".join(all_paths)},
        arguments = [],
        tools = ctx.files._webpack,
    )

    return [DefaultInfo(files = depset([output_file]))]

asterius_webpack = rule(
    asterius_webpack_impl,
    attrs = {
        "dep": attr.label(
            mandatory = True,
        ),
        "out": attr.string(mandatory = True),
        "_webpack": attr.label(
            default = "@rules_haskell//haskell/asterius:webpack",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_sh//sh/posix:toolchain_type",
    ],
)

# Copied from https://github.com/tweag/asterius/blob/master/asterius/test/ghc-testsuite.hs
node_options = [
    "--experimental-modules",
    "--experimental-wasi-unstable-preview1",
    "--experimental-wasm-bigint",
    "--experimental-wasm-return-call",
    "--no-wasm-bounds-checks",
    "--no-wasm-stack-checks",
    "--unhandled-rejections=strict",
    "--wasm-lazy-compilation",
    "--wasm-lazy-validation",
    "--unhandled-rejections=strict",
]

def asterius_binary(name, entry_point, data):
    nodejs_binary(
        name = name,
        entry_point = entry_point,
        templated_args = ["--node_options={}".format(opt) for opt in node_options],
        chdir = native.package_name(),
        data = data + ["@npm//:node_modules"],
    )

def asterius_test(name, entry_point, data):
    nodejs_test(
        name = name,
        entry_point = entry_point,
        templated_args = ["--node_options={}".format(opt) for opt in node_options],
        chdir = native.package_name(),
        data = data + ["@npm//:node_modules"],
    )
