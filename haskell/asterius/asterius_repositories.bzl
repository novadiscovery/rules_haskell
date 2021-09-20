load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("@build_bazel_rules_nodejs//:index.bzl", "node_repositories", "yarn_install")

def asterius_dependencies_from_nix(nix_repository, nixpkgs_package_rule):
    maybe(
        nixpkgs_package_rule,
        name = "nixpkgs_nodejs",
        build_file_content = 'exports_files(glob(["nixpkgs_nodejs/**"]))',
        # XXX Indirection derivation to make all of NodeJS rooted in
        # a single directory. We shouldn't need this, but it's
        # a workaround for
        # https://github.com/bazelbuild/bazel/issues/2927.
        nix_file_content = """
        with import <nixpkgs> { config = {}; overlays = []; };
        runCommand "nodejs-rules_haskell" { buildInputs = [ nodejs ]; } ''
        mkdir -p $out/nixpkgs_nodejs
        cd $out/nixpkgs_nodejs
        for i in ${nodejs}/*; do ln -s $i; done
        ''
        """,
        nixopts = [
            "--option",
            "sandbox",
            "false",
        ],
        # repository = "@nixpkgs_default",
        repository = nix_repository,
        fail_not_supported = False,
    )

    node_repositories(
        #name = "nix_node_repository",
        vendored_node = "@nixpkgs_nodejs",
        preserve_symlinks = False,
    )

    node_repositories(
        #name = "bindist_node_repository",
        preserve_symlinks = False,
    )

    # Provides webpack for use by asterius rules
    # TODO: can it be removed from here ?
    maybe(
        yarn_install,
        name = "npm",
        package_json = "@rules_haskell//haskell:asterius/package.json",
        yarn_lock = "@rules_haskell//haskell:asterius/yarn.lock",
        # symlink_node_modules = False,
    )
