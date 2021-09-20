load(
    "@rules_haskell//haskell/asterius:asterius.bzl",
    "ahc_dist",
    "asterius_binary",
    "asterius_test",
)

package(default_testonly = 1)

ahc_dist(
    name = "test_ahc_dist",
    dep = "//tests/binary-with-lib",
    main_output = "custom_output_name.mjs",
    target = "node",
)

asterius_binary(
    name = "my_binary",
    data = [":test_ahc_dist"],
    entry_point = ":custom_output_name.mjs",
)

asterius_test(
    name = "my_test",
    data = [":test_ahc_dist"],
    entry_point = ":custom_output_name.mjs",
)
