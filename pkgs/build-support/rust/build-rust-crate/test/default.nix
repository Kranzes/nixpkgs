{
  lib,
  buildPackages,
  buildRustCrate,
  callPackage,
  releaseTools,
  runCommand,
  runCommandCC,
  stdenv,
  symlinkJoin,
  testers,
  writeTextFile,
  pkgsCross,
}:

let
  mkCrate =
    buildRustCrate: args:
    let
      p = {
        crateName = "nixtestcrate";
        version = "0.1.0";
        authors = [ "Test <test@example.com>" ];
      }
      // args;
    in
    buildRustCrate p;
  mkHostCrate = mkCrate buildRustCrate;

  mkCargoToml =
    {
      name,
      crateVersion ? "0.1.0",
      path ? "Cargo.toml",
    }:
    mkFile path ''
      [package]
      name = ${builtins.toJSON name}
      version = ${builtins.toJSON crateVersion}
    '';

  mkFile =
    destination: text:
    writeTextFile {
      name = "src";
      destination = "/${destination}";
      inherit text;
    };

  mkBin =
    name:
    mkFile name ''
      use std::env;
      fn main() {
        let name: String = env::args().nth(0).unwrap();
        println!("executed {}", name);
      }
    '';

  mkBinExtern =
    name: extern:
    mkFile name ''
      extern crate ${extern};
      fn main() {
        assert_eq!(${extern}::test(), 23);
      }
    '';

  mkTestFile =
    name: functionName:
    mkFile name ''
      #[cfg(test)]
      #[test]
      fn ${functionName}() {
        assert!(true);
      }
    '';
  mkTestFileWithMain =
    name: functionName:
    mkFile name ''
      #[cfg(test)]
      #[test]
      fn ${functionName}() {
        assert!(true);
      }

      fn main() {}
    '';

  mkLib = name: mkFile name "pub fn test() -> i32 { return 23; }";

  # Bin plus rlib dependency built with the same `lto` value, the way a
  # cargo profile applies to the whole dependency graph.
  mkLtoCase = ltoVal: {
    lto = ltoVal;
    crateBin = [ { name = "lto-bin"; } ];
    src = mkBinExtern "src/main.rs" "lto_dep";
    dependencies = [
      (mkHostCrate {
        crateName = "lto-dep";
        lto = ltoVal;
        src = mkLib "src/lib.rs";
      })
    ];
  };

  mkTest =
    crateArgs:
    let
      crate = mkHostCrate (
        removeAttrs crateArgs [
          "expectedTestOutputs"
          "expectedTestBinaries"
        ]
      );
      hasTests = crateArgs.buildTests or false;
      expectedTestOutputs = crateArgs.expectedTestOutputs or null;
      expectedTestBinaries = crateArgs.expectedTestBinaries or [ ];
      binaries = map (v: lib.escapeShellArg v.name) (crateArgs.crateBin or [ ]);
      isLib = crateArgs ? libName || crateArgs ? libPath;
      crateName = crateArgs.crateName or "nixtestcrate";
      libName = crateArgs.libName or crateName;

      libTestBinary =
        if !isLib then
          null
        else
          mkHostCrate {
            crateName = "run-test-${crateName}";
            dependencies = [ crate ];
            src = mkBinExtern "src/main.rs" libName;
          };

    in
    assert expectedTestOutputs != null -> hasTests;
    assert hasTests -> expectedTestOutputs != null;

    runCommand "run-buildRustCrate-${crateName}-test"
      {
        nativeBuildInputs = [ crate ];
      }
      (
        if !hasTests then
          ''
            ${lib.concatMapStringsSep "\n" (
              binary:
              # Can't actually run the binary when cross-compiling
              (lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) "type ") + binary
            ) binaries}
            ${lib.optionalString isLib ''
              test -e ${crate}/lib/*.rlib || exit 1
              ${lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) "test -x "} \
                ${libTestBinary}/bin/run-test-${crateName}
            ''}
            touch $out
          ''
        else if stdenv.hostPlatform == stdenv.buildPlatform then
          ''
            ${lib.concatMapStringsSep "\n" (
              b:
              "test -x ${crate}/tests/${lib.escapeShellArg b} || { echo 'expected test binary \"${b}\" not found in:'; ls ${crate}/tests; exit 23; }"
            ) expectedTestBinaries}
            for file in ${crate}/tests/*; do
              $file 2>&1 >> $out
            done
            set -e
            ${lib.concatMapStringsSep "\n" (
              o: "grep '${o}' $out || {  echo 'output \"${o}\" not found in:'; cat $out; exit 23; }"
            ) expectedTestOutputs}
          ''
        else
          ''
            for file in ${crate}/tests/*; do
              test -x "$file"
            done
            touch "$out"
          ''
      );

  /*
    Returns a derivation that asserts that the crate specified by `crateArgs`
    has the specified files as output.

    `name` is used as part of the derivation name that performs the checking.

    `mkCrate` can be used to override the `mkCrate` call/implementation to use to
    override the `buildRustCrate`, useful for cross compilation. Uses `mkHostCrate` by default.

    `crateArgs` is passed to `mkCrate` to build the crate with `buildRustCrate`

    `expectedFiles` contains a list of expected file paths in the output. E.g.
    `[ "./bin/my_binary" ]`.

    `output` specifies the name of the output to use. By default, the default
    output is used but e.g. `output = "lib";` will cause the lib output
    to be checked instead. You do not need to specify any directories.
  */
  assertOutputs =
    {
      name,
      mkCrate ? mkHostCrate,
      crateArgs,
      expectedFiles,
      output ? null,
    }:
    assert (builtins.isString name);
    assert (builtins.isAttrs crateArgs);
    assert (builtins.isList expectedFiles);

    let
      crate = mkCrate (removeAttrs crateArgs [ "expectedTestOutput" ]);
      crateOutput = if output == null then crate else crate."${output}";
      expectedFilesFile = writeTextFile {
        name = "expected-files-${name}";
        text =
          let
            sorted = builtins.sort (a: b: a < b) expectedFiles;
            concatenated = builtins.concatStringsSep "\n" sorted;
          in
          "${concatenated}\n";
      };
    in
    runCommand "assert-outputs-${name}"
      {
      }
      (
        ''
          local actualFiles=$(mktemp)

          cd "${crateOutput}"
          find . -type f \
            | sort \
        ''
        # sed out the hash because it differs per platform
        + ''
            | sed 's/-${crate.metadata}//g' \
            > "$actualFiles"
          diff -q ${expectedFilesFile} "$actualFiles" > /dev/null || {
            echo -e "\033[0;1;31mERROR: Difference in expected output files in ${crateOutput} \033[0m" >&2
            echo === Got:
            sed -e 's/^/  /' $actualFiles
            echo === Expected:
            sed -e 's/^/  /' ${expectedFilesFile}
            echo === Diff:
            diff -u ${expectedFilesFile} $actualFiles |\
              tail -n +3 |\
              sed -e 's/^/  /'
            exit 1
          }
          touch $out
        ''
      );

in
rec {

  tests = lib.recurseIntoAttrs (
    let
      cases = rec {
        libPath = {
          libPath = "src/my_lib.rs";
          src = mkLib "src/my_lib.rs";
        };
        srcLib = {
          src = mkLib "src/lib.rs";
        };

        # This used to be supported by cargo but as of 1.40.0 I can't make it work like that with just cargo anymore.
        # This might be a regression or deprecated thing they finally removed…
        # customLibName =  { libName = "test_lib"; src = mkLib "src/test_lib.rs"; };
        # rustLibTestsCustomLibName = {
        #   libName = "test_lib";
        #   src = mkTestFile "src/test_lib.rs" "foo";
        #   buildTests = true;
        #   expectedTestOutputs = [ "test foo ... ok" ];
        # };

        customLibNameAndLibPath = {
          libName = "test_lib";
          libPath = "src/best-lib.rs";
          src = mkLib "src/best-lib.rs";
        };
        crateBinWithPath = {
          crateBin = [
            {
              name = "test_binary1";
              path = "src/foobar.rs";
            }
          ];
          src = mkBin "src/foobar.rs";
        };
        crateBinNoPath1 = {
          crateBin = [ { name = "my-binary2"; } ];
          src = mkBin "src/my_binary2.rs";
        };
        crateBinNoPath2 = {
          crateBin = [
            { name = "my-binary3"; }
            { name = "my-binary4"; }
          ];
          src = symlinkJoin {
            name = "buildRustCrateMultipleBinariesCase";
            paths = [
              (mkBin "src/bin/my_binary3.rs")
              (mkBin "src/bin/my_binary4.rs")
            ];
          };
        };
        crateBinNoPath3 = {
          crateBin = [ { name = "my-binary5"; } ];
          src = mkBin "src/bin/main.rs";
        };
        crateBinNoPath4 = {
          crateBin = [ { name = "my-binary6"; } ];
          src = mkBin "src/main.rs";
        };
        crateBinRename1 = {
          crateBin = [ { name = "my-binary-rename1"; } ];
          src = mkBinExtern "src/main.rs" "foo_renamed";
          dependencies = [
            (mkHostCrate {
              crateName = "foo";
              src = mkLib "src/lib.rs";
            })
          ];
          crateRenames = {
            "foo" = "foo_renamed";
          };
        };
        crateBinRename2 = {
          crateBin = [ { name = "my-binary-rename2"; } ];
          src = mkBinExtern "src/main.rs" "foo_renamed";
          dependencies = [
            (mkHostCrate {
              crateName = "foo";
              libName = "foolib";
              src = mkLib "src/lib.rs";
            })
          ];
          crateRenames = {
            "foo" = "foo_renamed";
          };
        };
        crateBinRenameMultiVersion =
          let
            crateWithVersion =
              version:
              mkHostCrate {
                crateName = "my_lib";
                inherit version;
                src = mkFile "src/lib.rs" ''
                  pub const version: &str = "${version}";
                '';
              };
            depCrate01 = crateWithVersion "0.1.2";
            depCrate02 = crateWithVersion "0.2.1";
          in
          {
            crateName = "my_bin";
            src = symlinkJoin {
              name = "my_bin_src";
              paths = [
                (mkFile "src/main.rs" ''
                  #[test]
                  fn my_lib_01() { assert_eq!(lib01::version, "0.1.2"); }

                  #[test]
                  fn my_lib_02() { assert_eq!(lib02::version, "0.2.1"); }

                  fn main() { }
                '')
              ];
            };
            dependencies = [
              depCrate01
              depCrate02
            ];
            crateRenames = {
              "my_lib" = [
                {
                  version = "0.1.2";
                  rename = "lib01";
                }
                {
                  version = "0.2.1";
                  rename = "lib02";
                }
              ];
            };
            buildTests = true;
            expectedTestOutputs = [
              "test my_lib_01 ... ok"
              "test my_lib_02 ... ok"
            ];
          };
        rustLibTestsDefault = {
          src = mkTestFile "src/lib.rs" "baz";
          buildTests = true;
          expectedTestOutputs = [ "test baz ... ok" ];
        };
        rustLibTestsCustomLibPath = {
          libPath = "src/test_path.rs";
          src = mkTestFile "src/test_path.rs" "bar";
          buildTests = true;
          expectedTestOutputs = [ "test bar ... ok" ];
        };
        rustLibTestsCustomLibPathWithTests = {
          libPath = "src/test_path.rs";
          src = symlinkJoin {
            name = "rust-lib-tests-custom-lib-path-with-tests-dir";
            paths = [
              (mkTestFile "src/test_path.rs" "bar")
              (mkTestFile "tests/something.rs" "something")
            ];
          };
          buildTests = true;
          expectedTestOutputs = [
            "test bar ... ok"
            "test something ... ok"
          ];
        };
        rustLibTestsWithDevDependency =
          let
            devDep = mkHostCrate {
              crateName = "dev-dep";
              src = mkLib "src/lib.rs";
            };
          in
          {
            src = mkFile "src/lib.rs" ''
              #[cfg(test)]
              mod tests {
                  #[test]
                  fn uses_dev_dep() {
                      assert_eq!(dev_dep::test(), 23);
                  }
              }
            '';
            devDependencies = [ devDep ];
            buildTests = true;
            expectedTestOutputs = [ "test tests::uses_dev_dep ... ok" ];
          };
        rustBinTestsCombined = {
          src = symlinkJoin {
            name = "rust-bin-tests-combined";
            paths = [
              (mkTestFileWithMain "src/main.rs" "src_main")
              (mkTestFile "tests/foo.rs" "tests_foo")
              (mkTestFile "tests/bar.rs" "tests_bar")
            ];
          };
          buildTests = true;
          expectedTestOutputs = [
            "test src_main ... ok"
            "test tests_foo ... ok"
            "test tests_bar ... ok"
          ];
        };
        rustBinTestsSubdirCombined = {
          src = symlinkJoin {
            name = "rust-bin-tests-subdir-combined";
            paths = [
              (mkTestFileWithMain "src/main.rs" "src_main")
              (mkTestFile "tests/foo/main.rs" "tests_foo")
              (mkTestFile "tests/bar/main.rs" "tests_bar")
            ];
          };
          buildTests = true;
          # Cargo names tests/<dir>/main.rs as <dir>, not <dir>_main.
          expectedTestBinaries = [
            "foo"
            "bar"
          ];
          expectedTestOutputs = [
            "test src_main ... ok"
            "test tests_foo ... ok"
            "test tests_bar ... ok"
          ];
        };
        rustBinTestsFlatMainSuffix = {
          # A flat-style test whose name happens to end in _main must keep
          # its suffix — only tests/<dir>/main.rs gets the _main stripped.
          src = symlinkJoin {
            name = "rust-bin-tests-flat-main-suffix";
            paths = [
              (mkTestFileWithMain "src/main.rs" "src_main")
              (mkTestFile "tests/foo_main.rs" "flat_test")
            ];
          };
          buildTests = true;
          expectedTestBinaries = [ "foo_main" ];
          expectedTestOutputs = [
            "test src_main ... ok"
            "test flat_test ... ok"
          ];
        };
        rustBinTestsCargoBinExe = {
          # Integration tests locate the crate's own binary via
          # `env!("CARGO_BIN_EXE_<name>")`, which cargo sets automatically.
          crateName = "my-crate";
          src = symlinkJoin {
            name = "rust-bin-tests-cargo-bin-exe";
            paths = [
              (mkFile "src/main.rs" ''
                fn main() { println!("hello from my-crate"); }
              '')
              (mkFile "tests/run_bin.rs" ''
                #[test]
                fn runs_binary() {
                    let bin = env!("CARGO_BIN_EXE_my-crate");
                    let out = std::process::Command::new(bin)
                        .output()
                        .expect("spawn");
                    assert!(out.status.success());
                    assert_eq!(
                        String::from_utf8_lossy(&out.stdout).trim(),
                        "hello from my-crate"
                    );
                }
              '')
            ];
          };
          buildTests = true;
          expectedTestOutputs = [
            "test runs_binary ... ok"
          ];
        };
        rustBinTestsCargoBinExeAutoDetect = {
          # Verify CARGO_BIN_EXE_<name> is also set for auto-detected
          # src/bin/*.rs binaries, not just src/main.rs or explicit
          # crateBin entries.
          crateName = "multi-bin";
          src = symlinkJoin {
            name = "rust-bin-tests-cargo-bin-exe-auto";
            paths = [
              (mkFile "src/lib.rs" "")
              (mkFile "src/bin/tool-a.rs" ''
                fn main() { println!("tool-a ran"); }
              '')
              (mkFile "src/bin/tool-b.rs" ''
                fn main() { println!("tool-b ran"); }
              '')
              (mkFile "tests/run_tools.rs" ''
                #[test]
                fn runs_both() {
                    for (bin, want) in [
                        (env!("CARGO_BIN_EXE_tool-a"), "tool-a ran"),
                        (env!("CARGO_BIN_EXE_tool-b"), "tool-b ran"),
                    ] {
                        let out = std::process::Command::new(bin)
                            .output()
                            .expect("spawn");
                        assert!(out.status.success());
                        assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), want);
                    }
                }
              '')
            ];
          };
          buildTests = true;
          expectedTestOutputs = [
            "test runs_both ... ok"
          ];
        };
        linkAgainstRlibCrate = {
          crateName = "foo";
          src = mkFile "src/main.rs" ''
            extern crate somerlib;
            fn main() {}
          '';
          dependencies = [
            (mkHostCrate {
              crateName = "somerlib";
              type = [ "rlib" ];
              src = mkLib "src/lib.rs";
            })
          ];
        };
        buildScriptDeps =
          let
            depCrate =
              buildRustCrate: boolVal:
              mkCrate buildRustCrate {
                crateName = "bar";
                src = mkFile "src/lib.rs" ''
                  pub const baz: bool = ${boolVal};
                '';
              };
          in
          {
            crateName = "foo";
            src = symlinkJoin {
              name = "build-script-and-main";
              paths = [
                (mkFile "src/main.rs" ''
                  extern crate bar;
                  #[cfg(test)]
                  #[test]
                  fn baz_false() { assert!(!bar::baz); }
                  fn main() { }
                '')
                (mkFile "build.rs" ''
                  extern crate bar;
                  fn main() { assert!(bar::baz); }
                '')
              ];
            };
            buildDependencies = [ (depCrate buildPackages.buildRustCrate "true") ];
            dependencies = [ (depCrate buildRustCrate "false") ];
            buildTests = true;
            expectedTestOutputs = [ "test baz_false ... ok" ];
          };
        buildScriptFeatureEnv = {
          crateName = "build-script-feature-env";
          features = [
            "some-feature"
            "some-c++17-thing"
            "crate/another_feature"
          ];
          src = symlinkJoin {
            name = "build-script-feature-env";
            paths = [
              (mkFile "src/main.rs" ''
                #[cfg(test)]
                #[test]
                fn feature_not_visible() {
                  assert!(std::env::var("CARGO_FEATURE_SOME_FEATURE").is_err());
                  assert!(option_env!("CARGO_FEATURE_SOME_FEATURE").is_none());
                  assert!(std::env::var("CARGO_FEATURE_SOME_C++17_THING").is_err());
                  assert!(option_env!("CARGO_FEATURE_SOME_C++17_THING").is_none());
                  assert!(std::env::var("CARGO_FEATURE_ANOTHER_FEATURE").is_err());
                  assert!(option_env!("CARGO_FEATURE_ANOTHER_FEATURE").is_none());
                }
                fn main() {}
              '')
              (mkFile "build.rs" ''
                fn main() {
                  assert!(std::env::var("CARGO_FEATURE_SOME_FEATURE").is_ok());
                  assert!(option_env!("CARGO_FEATURE_SOME_FEATURE").is_none());
                  assert!(std::env::var("CARGO_FEATURE_SOME_C++17_THING").is_ok());
                  assert!(option_env!("CARGO_FEATURE_SOME_C++17_THING").is_none());
                  assert!(std::env::var("CARGO_FEATURE_ANOTHER_FEATURE").is_err());
                  assert!(option_env!("CARGO_FEATURE_ANOTHER_FEATURE").is_none());
                }
              '')
            ];
          };
          buildTests = true;
          expectedTestOutputs = [ "test feature_not_visible ... ok" ];
        };
        # Regression test for https://github.com/NixOS/nixpkgs/pull/88054
        # Build script output should be rewritten as valid env vars.
        buildScriptIncludeDirDeps =
          let
            depCrate = mkHostCrate {
              crateName = "bar";
              src = symlinkJoin {
                name = "build-script-and-include-dir-bar";
                paths = [
                  (mkFile "src/lib.rs" ''
                    fn main() { }
                  '')
                  (mkFile "build.rs" ''
                    use std::path::PathBuf;
                    fn main() { println!("cargo:include-dir={}/src", std::env::current_dir().unwrap_or(PathBuf::from(".")).to_str().unwrap()); }
                  '')
                ];
              };
            };
          in
          {
            crateName = "foo";
            src = symlinkJoin {
              name = "build-script-and-include-dir-foo";
              paths = [
                (mkFile "src/main.rs" ''
                  fn main() { }
                '')
                (mkFile "build.rs" ''
                  fn main() { assert!(std::env::var_os("DEP_BAR_INCLUDE_DIR").is_some()); }
                '')
              ];
            };
            buildDependencies = [ depCrate ];
            dependencies = [ depCrate ];
          };
        # Support new invocation prefix for build scripts `cargo::`
        # https://doc.rust-lang.org/cargo/reference/build-scripts.html#outputs-of-the-build-script
        buildScriptInvocationPrefix =
          let
            depCrate =
              buildRustCrate:
              mkCrate buildRustCrate {
                crateName = "bar";
                src = mkFile "build.rs" ''
                  fn main() {
                    // Old invocation prefix
                    // We likely won't see be mixing these syntaxes in the same build script in the wild.
                    println!("cargo:key_old=value_old");

                    // New invocation prefix
                    println!("cargo::metadata=key=value");
                    println!("cargo::metadata=key_complex=complex(value)");
                  }
                '';
              };
          in
          {
            crateName = "foo";
            src = symlinkJoin {
              name = "build-script-and-main-invocation-prefix";
              paths = [
                (mkFile "src/main.rs" ''
                  const BUILDFOO: &'static str = env!("BUILDFOO");

                  #[test]
                  fn build_foo_check() { assert!(BUILDFOO == "yes(check)"); }

                  fn main() { }
                '')
                (mkFile "build.rs" ''
                  use std::env;
                  fn main() {
                    assert!(env::var_os("DEP_BAR_KEY_OLD").expect("metadata key 'key_old' not set in dependency") == "value_old");
                    assert!(env::var_os("DEP_BAR_KEY").expect("metadata key 'key' not set in dependency") == "value");
                    assert!(env::var_os("DEP_BAR_KEY_COMPLEX").expect("metadata key 'key_complex' not set in dependency") == "complex(value)");

                    println!("cargo::rustc-env=BUILDFOO=yes(check)");
                  }
                '')
              ];
            };
            buildDependencies = [ (depCrate buildPackages.buildRustCrate) ];
            dependencies = [ (depCrate buildRustCrate) ];
            buildTests = true;
            expectedTestOutputs = [ "test build_foo_check ... ok" ];
          };
        # Regression test for https://github.com/NixOS/nixpkgs/issues/74071
        # Whenevever a build.rs file is generating files those should not be overlaid onto the actual source dir
        buildRsOutDirOverlay = {
          src = symlinkJoin {
            name = "buildrs-out-dir-overlay";
            paths = [
              (mkLib "src/lib.rs")
              (mkFile "build.rs" ''
                use std::env;
                use std::ffi::OsString;
                use std::fs;
                use std::path::Path;
                fn main() {
                  let out_dir = env::var_os("OUT_DIR").expect("OUT_DIR not set");
                  let out_file = Path::new(&out_dir).join("lib.rs");
                  fs::write(out_file, "invalid rust code!").expect("failed to write lib.rs");
                }
              '')
            ];
          };
        };
        # Regression test for https://github.com/NixOS/nixpkgs/pull/83379
        # link flag order should be preserved
        linkOrder = {
          src = symlinkJoin {
            name = "buildrs-out-dir-overlay";
            paths = [
              (mkFile "build.rs" ''
                fn main() {
                  // in the other order, linkage will fail
                  println!("cargo:rustc-link-lib=b");
                  println!("cargo:rustc-link-lib=a");
                }
              '')
              (mkFile "src/main.rs" ''
                extern "C" {
                  fn hello_world();
                }
                fn main() {
                  unsafe {
                    hello_world();
                  }
                }
              '')
            ];
          };
          buildInputs =
            let
              compile =
                name: text:
                let
                  src = writeTextFile {
                    name = "${name}-src.c";
                    inherit text;
                  };
                in
                runCommandCC name { } ''
                  mkdir -p $out/lib
                  # Note: On darwin (which defaults to clang) we have to add
                  # `-undefined dynamic_lookup` as otherwise the compilation fails.
                  $CC -shared \
                    ${lib.optionalString stdenv.hostPlatform.isDarwin "-undefined dynamic_lookup"} \
                    -o $out/lib/${name}${stdenv.hostPlatform.extensions.library} ${src}
                '';
              b = compile "libb" ''
                #include <stdio.h>

                void hello();

                void hello_world() {
                  hello();
                  printf(" world!\n");
                }
              '';
              a = compile "liba" ''
                #include <stdio.h>

                void hello() {
                  printf("hello");
                }
              '';
            in
            [
              a
              b
            ];
        };
        rustCargoTomlInSubDir = {
          # The "workspace_member" can be set to the sub directory with the crate to build.
          # By default ".", meaning the top level directory is assumed.
          # Using null will trigger a search.
          workspace_member = null;
          src = symlinkJoin {
            name = "find-cargo-toml";
            paths = [
              (mkCargoToml { name = "ignoreMe"; })
              (mkTestFileWithMain "src/main.rs" "ignore_main")

              (mkCargoToml {
                name = "rustCargoTomlInSubDir";
                path = "subdir/Cargo.toml";
              })
              (mkTestFileWithMain "subdir/src/main.rs" "src_main")
              (mkTestFile "subdir/tests/foo/main.rs" "tests_foo")
              (mkTestFile "subdir/tests/bar/main.rs" "tests_bar")
            ];
          };
          buildTests = true;
          expectedTestOutputs = [
            "test src_main ... ok"
            "test tests_foo ... ok"
            "test tests_bar ... ok"
          ];
        };

        rustCargoTomlInTopDir =
          let
            withoutCargoTomlSearch = removeAttrs rustCargoTomlInSubDir [ "workspace_member" ];
          in
          withoutCargoTomlSearch
          // {
            expectedTestOutputs = [
              "test ignore_main ... ok"
            ];
          };
        procMacroInPrelude = {
          procMacro = true;
          edition = "2018";
          src = symlinkJoin {
            name = "proc-macro-in-prelude";
            paths = [
              (mkFile "src/lib.rs" ''
                use proc_macro::TokenTree;
              '')
            ];
          };
        };
        # Default (null) inherits extraRustcOpts for proc-macros.
        procMacroExtraOptsInherit = {
          procMacro = true;
          edition = "2018";
          extraRustcOpts = [ "--cfg=target_only" ];
          src = mkFile "src/lib.rs" ''
            #[cfg(not(target_only))]
            compile_error!("extraRustcOpts not inherited by proc-macro");
            use proc_macro as _;
          '';
        };
        # When set, extraRustcOptsForProcMacro replaces extraRustcOpts
        # for proc-macro crates.
        procMacroExtraOptsOverride = {
          procMacro = true;
          edition = "2018";
          extraRustcOpts = [ "--cfg=target_only" ];
          extraRustcOptsForProcMacro = [ "--cfg=host_only" ];
          src = mkFile "src/lib.rs" ''
            #[cfg(target_only)]
            compile_error!("extraRustcOpts leaked into proc-macro");
            #[cfg(not(host_only))]
            compile_error!("extraRustcOptsForProcMacro not applied");
            use proc_macro as _;
          '';
        };
        # The `lints` attr mirrors Cargo.toml's `[lints]` table and is
        # translated to rustc `-A`/`-W`/`-D`/`-F` flags. Lower-priority
        # entries are emitted first so that higher-priority specific lints
        # can override them. Here `-D unused` (priority -1) is followed by
        # `-A dead_code` (default priority 0); the build only succeeds if
        # both flags reach rustc in that order.
        lintsPriority = {
          lints.rust = {
            unused = {
              level = "deny";
              priority = -1;
            };
            dead_code = "allow";
          };
          src = mkFile "src/lib.rs" ''
            #![allow(nonstandard_style)]
            fn dead() {}
            pub fn alive() {}
          '';
        };
        # `lto` mirrors Cargo's `profile.<name>.lto`. One run test per
        # accepted value; the per-crate-type flag selection is asserted
        # in ltoFlagTable below.
        ltoFat = mkLtoCase "fat";
        ltoThin = mkLtoCase "thin";
        ltoTrue = mkLtoCase true;
        ltoFalse = mkLtoCase false;
        ltoOff = mkLtoCase "off";
        # A root with LTO enabled must be able to consume dependencies
        # built without any `lto` setting: rustc embeds bitcode in rlibs
        # by default, and the final `-C lto` link reads it.
        ltoRootOnly = {
          lto = "fat";
          crateBin = [ { name = "lto-root-only"; } ];
          src = mkBinExtern "src/main.rs" "plain_dep";
          dependencies = [
            (mkHostCrate {
              crateName = "plain-dep";
              src = mkLib "src/lib.rs";
            })
          ];
        };
        # Test harnesses are compiled as bin units, so `-C lto=thin` must
        # be accepted alongside `--test`. That the flag really reaches the
        # harness link is proven by ltoTestHarnessRunsLto below.
        ltoLibTests = {
          lto = "thin";
          src = mkTestFile "src/lib.rs" "lto_harness";
          buildTests = true;
          expectedTestOutputs = [ "test lto_harness ... ok" ];
        };
        # A proc-macro crate's own test harness stays a host unit (cargo
        # checks for_host before the test-mode bin mapping), so it must
        # NOT run LTO: with a dependency whose bitcode was stripped
        # (lto = false), bin-unit treatment would fail the fat-LTO link,
        # while host treatment links normally.
        ltoProcMacroTests =
          let
            dep = mkHostCrate {
              crateName = "lto-pm-dep";
              lto = false;
              src = mkLib "src/lib.rs";
            };
          in
          {
            procMacro = true;
            edition = "2018";
            lto = "fat";
            dependencies = [ dep ];
            src = mkFile "src/lib.rs" ''
              use proc_macro::TokenStream;

              #[proc_macro]
              pub fn shared_value(_input: TokenStream) -> TokenStream {
                  lto_pm_dep::test().to_string().parse().unwrap()
              }

              #[cfg(test)]
              #[test]
              fn harness_is_host_unit() {
                  assert_eq!(lto_pm_dep::test(), 23);
              }
            '';
            buildTests = true;
            expectedTestOutputs = [ "test harness_is_host_unit ... ok" ];
          };
        # The build script is a host unit: compiled with
        # `-C embed-bitcode=no`, never LTO'd, and it must still be able to
        # link a build dependency that was built with the LTO profile.
        ltoBuildScript = {
          lto = "thin";
          crateBin = [ { name = "lto-build-script"; } ];
          src = symlinkJoin {
            name = "lto-build-script-src";
            paths = [
              (mkFile "src/main.rs" ''
                fn main() { assert_eq!(env!("LTO_BS"), "ok"); }
              '')
              (mkFile "build.rs" ''
                extern crate bsdep;
                fn main() {
                  assert_eq!(bsdep::test(), 23);
                  println!("cargo:rustc-env=LTO_BS=ok");
                }
              '')
            ];
          };
          buildDependencies = [
            (mkCrate buildPackages.buildRustCrate {
              crateName = "bsdep";
              lto = "thin";
              src = mkLib "src/lib.rs";
            })
          ];
        };
        # Shared rlib consumed by both a proc-macro dylib (a host link that
        # needs the dependency's object code) and the fat-LTO final binary
        # (which reads its bitcode) — the same store path must serve both.
        ltoProcMacro =
          let
            sharedDep = mkHostCrate {
              crateName = "lto-shared";
              lto = "fat";
              src = mkLib "src/lib.rs";
            };
            macroCrate = mkHostCrate {
              crateName = "lto-macro";
              procMacro = true;
              edition = "2018";
              lto = "fat";
              dependencies = [ sharedDep ];
              src = mkFile "src/lib.rs" ''
                use proc_macro::TokenStream;
                #[proc_macro]
                pub fn shared_value(_input: TokenStream) -> TokenStream {
                    format!("fn shared_value() -> i32 {{ {} }}", lto_shared::test())
                        .parse()
                        .unwrap()
                }
              '';
            };
          in
          {
            lto = "fat";
            edition = "2018";
            crateBin = [ { name = "lto-macro-bin"; } ];
            dependencies = [
              macroCrate
              sharedDep
            ];
            src = mkFile "src/main.rs" ''
              lto_macro::shared_value!();
              fn main() {
                assert_eq!(shared_value(), 23);
                assert_eq!(lto_shared::test(), 23);
              }
            '';
          };
      };
      brotliCrates = (callPackage ./brotli-crates.nix { });
      rcgenCrates = callPackage ./rcgen-crates.nix {
        # Suppress deprecation warning
        buildRustCrate = null;
      };
      tests = lib.mapAttrs (
        key: value: mkTest (value // lib.optionalAttrs (!value ? crateName) { crateName = key; })
      ) cases;
    in
    tests
    // {

      crateBinWithPathOutputs = assertOutputs {
        name = "crateBinWithPath";
        crateArgs = {
          crateBin = [
            {
              name = "test_binary1";
              path = "src/foobar.rs";
            }
          ];
          src = mkBin "src/foobar.rs";
        };
        expectedFiles = [
          "./bin/test_binary1"
        ];
      };

      crateBinWithPathOutputsDebug = assertOutputs {
        name = "crateBinWithPath";
        crateArgs = {
          release = false;
          crateBin = [
            {
              name = "test_binary1";
              path = "src/foobar.rs";
            }
          ];
          src = mkBin "src/foobar.rs";
        };
        expectedFiles = [
          "./bin/test_binary1"
        ]
        ++ lib.optionals stdenv.hostPlatform.isDarwin [
          # On Darwin, the debug symbols are in a separate directory.
          "./bin/test_binary1.dSYM/Contents/Info.plist"
          "./bin/test_binary1.dSYM/Contents/Resources/DWARF/test_binary1"
          "./bin/test_binary1.dSYM/Contents/Resources/Relocations/${stdenv.hostPlatform.rust.platform.arch}/test_binary1.yml"
        ];
      };

      crateBinNoPath1Outputs = assertOutputs {
        name = "crateBinNoPath1";
        crateArgs = {
          crateBin = [ { name = "my-binary2"; } ];
          src = mkBin "src/my_binary2.rs";
        };
        expectedFiles = [
          "./bin/my-binary2"
        ];
      };

      crateLibOutputs = assertOutputs {
        name = "crateLib";
        output = "lib";
        crateArgs = {
          libName = "test_lib";
          type = [ "rlib" ];
          libPath = "src/lib.rs";
          src = mkLib "src/lib.rs";
        };
        expectedFiles = [
          "./nix-support/propagated-build-inputs"
          "./lib/libtest_lib.rlib"
          "./lib/link"
        ];
      };

      crateLibOutputsDebug = assertOutputs {
        name = "crateLib";
        output = "lib";
        crateArgs = {
          release = false;
          libName = "test_lib";
          type = [ "rlib" ];
          libPath = "src/lib.rs";
          src = mkLib "src/lib.rs";
        };
        expectedFiles = [
          "./nix-support/propagated-build-inputs"
          "./lib/libtest_lib.rlib"
          "./lib/link"
        ];
      };

      crateLibOutputsWasm32 = assertOutputs {
        name = "wasm32-crate-lib";
        output = "lib";
        mkCrate = mkCrate pkgsCross.wasm32-unknown-none.buildRustCrate;
        crateArgs = {
          libName = "test_lib";
          type = [ "cdylib" ];
          libPath = "src/lib.rs";
          src = mkLib "src/lib.rs";
        };
        expectedFiles = [
          "./nix-support/propagated-build-inputs"
          "./lib/test_lib.wasm"
          "./lib/link"
        ];
      };

      crateWasm32BinHyphens = assertOutputs {
        name = "wasm32-crate-bin-hyphens";
        mkCrate = mkCrate pkgsCross.wasm32-unknown-none.buildRustCrate;
        crateArgs = {
          crateName = "wasm32-crate-bin-hyphens";
          crateBin = [ { name = "wasm32-crate-bin-hyphens"; } ];
          src = mkBin "src/main.rs";
        };
        expectedFiles = [
          "./bin/wasm32-crate-bin-hyphens.wasm"
        ];
      };

      crateWasm32TargetEnv = assertOutputs {
        name = "gnu64-crate-target-env";
        mkCrate = mkCrate pkgsCross.wasm32-unknown-none.buildRustCrate;
        crateArgs = {
          crateName = "wasm32-crate-target-env";
          crateBin = [ { name = "wasm32-crate-target-env"; } ];
          src = symlinkJoin {
            name = "wasm32-crate-target-env-sources";
            paths = [
              (mkFile "build.rs" ''
                fn main() {
                  assert_eq!(std::env::var("CARGO_CFG_TARGET_ENV"), Ok("".to_string()));
                }
              '')
              (mkFile "src/main.rs" ''
                use std::env;
                #[cfg(target_env = "")]
                fn main() {
                  let name: String = env::args().nth(0).unwrap();
                  println!("executed {}", name);
                }
              '')
            ];
          };
        };
        expectedFiles = [
          "./bin/wasm32-crate-target-env.wasm"
        ];
      };

      crateGnu64TargetEnv = assertOutputs {
        name = "gnu64-crate-target-env";
        mkCrate = mkCrate pkgsCross.gnu64.buildRustCrate;
        crateArgs = {
          crateName = "gnu64-crate-target-env";
          crateBin = [ { name = "gnu64-crate-target-env"; } ];
          src = symlinkJoin {
            name = "gnu64-crate-target-env-sources";
            paths = [
              (mkFile "build.rs" ''
                fn main() {
                  assert_eq!(std::env::var("CARGO_CFG_TARGET_ENV"), Ok("gnu".to_string()));
                }
              '')
              (mkFile "src/main.rs" ''
                use std::env;
                #[cfg(target_env = "gnu")]
                fn main() {
                  let name: String = env::args().nth(0).unwrap();
                  println!("executed {}", name);
                }
              '')
            ];
          };
        };
        expectedFiles = [
          "./bin/gnu64-crate-target-env"
        ];
      };

      brotliTest =
        let
          pkg = brotliCrates.brotli_2_5_0 { };
        in
        runCommand "run-brotli-test-cmd"
          {
            nativeBuildInputs = [ pkg ];
          }
          (
            if stdenv.hostPlatform == stdenv.buildPlatform then
              ''
                ${pkg}/bin/brotli -c ${pkg}/bin/brotli > /dev/null && touch $out
              ''
            else
              ''
                test -x '${pkg}/bin/brotli' && touch $out
              ''
          );
      allocNoStdLibTest =
        let
          pkg = brotliCrates.alloc_no_stdlib_1_3_0 { };
        in
        runCommand "run-alloc-no-stdlib-test-cmd"
          {
            nativeBuildInputs = [ pkg ];
          }
          ''
            test -e ${pkg}/bin/example && touch $out
          '';
      brotliDecompressorTest =
        let
          pkg = brotliCrates.brotli_decompressor_1_3_1 { };
        in
        runCommand "run-brotli-decompressor-test-cmd"
          {
            nativeBuildInputs = [ pkg ];
          }
          ''
            test -e ${pkg}/bin/brotli-decompressor && touch $out
          '';

      # A `deny` lint from the lints table should actually fail the build.
      lintsDenyFails =
        let
          crate = mkHostCrate {
            crateName = "lintsDenyFails";
            lints.rust.dead_code = "deny";
            src = mkFile "src/lib.rs" ''
              fn dead() {}
              pub fn alive() {}
            '';
          };
          failed = testers.testBuildFailure crate;
        in
        runCommand "assert-lintsDenyFails" { inherit failed; } ''
          grep -q 'function .dead. is never used' "$failed/testBuildFailure.log"
          grep -q '\-D dead.code' "$failed/testBuildFailure.log"
          touch $out
        '';

      # `useClippy = true` plus a denied clippy lint should fail the build,
      # proving clippy-driver (not plain rustc) compiled the crate. The
      # `clippy::` prefix in the diagnostic is the fingerprint: rustc has no
      # such lint group.
      useClippyDenyFails =
        let
          crate = mkHostCrate {
            crateName = "useClippyDenyFails";
            useClippy = true;
            lints.clippy.eq_op = "deny";
            src = mkFile "src/lib.rs" ''
              pub fn check() -> bool {
                1 == 1
              }
            '';
          };
          failed = testers.testBuildFailure crate;
        in
        runCommand "assert-useClippyDenyFails" { inherit failed; } ''
          grep -q 'clippy::eq.op' "$failed/testBuildFailure.log"
          grep -q 'equal expressions' "$failed/testBuildFailure.log"
          touch $out
        '';

      # `useClippy = true` with the default `capLints` (which resolves to
      # `"allow"` when `lints` is empty) must still build: the cap silences
      # clippy lints just like rustc lints. Same source as the failing test
      # above — only the `lints` table differs.
      useClippyDefaultCapAllows = mkHostCrate {
        crateName = "useClippyDefaultCapAllows";
        useClippy = true;
        src = mkFile "src/lib.rs" ''
          pub fn check() -> bool {
            1 == 1
          }
        '';
      };

      # A library compiled by clippy-driver must produce an `.rlib` that a
      # plain-rustc dependent can link against and run. This is the property
      # that makes `useClippy` safe to flip per-crate.
      useClippyRlibLinkCompat =
        let
          libCrate = mkHostCrate {
            crateName = "clippylib";
            useClippy = true;
            src = mkFile "src/lib.rs" ''
              pub fn test() -> i32 {
                23
              }
            '';
          };
          binCrate = mkHostCrate {
            crateName = "clippybin";
            dependencies = [ libCrate ];
            src = mkBinExtern "src/main.rs" "clippylib";
          };
        in
        runCommand "run-useClippyRlibLinkCompat" { nativeBuildInputs = [ binCrate ]; } (
          if stdenv.hostPlatform == stdenv.buildPlatform then
            ''
              ${binCrate}/bin/clippybin && touch $out
            ''
          else
            ''
              test -x '${binCrate}/bin/clippybin' && touch $out
            ''
        );

      rcgenTest =
        let
          pkg = rcgenCrates.rootCrate.build;
        in
        runCommand "run-rcgen-test-cmd"
          {
            nativeBuildInputs = [ pkg ];
          }
          (
            if stdenv.hostPlatform == stdenv.buildPlatform then
              ''
                ${pkg}/bin/rcgen && touch $out
              ''
            else
              ''
                test -x '${pkg}/bin/rcgen' && touch $out
              ''
          );

      # Test that propagatedBuildInputs declared in a crate override are
      # collected by completePropagatedBuildInputs and propagate transitively
      # to all crates that depend on it.
      propagatedBuildInputsTest =
        let
          fakeNativeLib = runCommand "fake-native-lib" { } "mkdir -p $out/lib && touch $out/lib/libfoo.a";

          # Library crate that declares a native dep via propagatedBuildInputs
          libCrate = mkHostCrate {
            crateName = "mylib";
            src = mkLib "src/lib.rs";
            propagatedBuildInputs = [ fakeNativeLib ];
          };

          # Binary crate with a direct dependency on libCrate
          binCrate = mkHostCrate {
            crateName = "mybin";
            src = mkFile "src/main.rs" "fn main() {}";
            dependencies = [ libCrate ];
          };

          # Intermediate library that depends on libCrate
          transitiveLib = mkHostCrate {
            crateName = "transitivelib";
            src = mkLib "src/lib.rs";
            dependencies = [ libCrate ];
          };

          # Binary crate that only depends on transitiveLib (not libCrate directly)
          transitiveBin = mkHostCrate {
            crateName = "transitivebin";
            src = mkFile "src/main.rs" "fn main() {}";
            dependencies = [ transitiveLib ];
          };
        in
        runCommand "propagated-build-inputs-test"
          {
            libCrateInputs = libCrate.completePropagatedBuildInputs;
            binCrateInputs = binCrate.completePropagatedBuildInputs;
            transitiveBinInputs = transitiveBin.completePropagatedBuildInputs;
          }
          ''
            # libCrate itself should have fakeNativeLib in completePropagatedBuildInputs
            echo "$libCrateInputs" | grep -q "${fakeNativeLib}" || {
              echo "ERROR: fakeNativeLib not in libCrate.completePropagatedBuildInputs"
              exit 1
            }

            # binCrate depends on libCrate, so fakeNativeLib should propagate
            echo "$binCrateInputs" | grep -q "${fakeNativeLib}" || {
              echo "ERROR: fakeNativeLib not propagated to binCrate.completePropagatedBuildInputs"
              exit 1
            }

            # transitiveBin → transitiveLib → libCrate: fakeNativeLib should propagate transitively
            echo "$transitiveBinInputs" | grep -q "${fakeNativeLib}" || {
              echo "ERROR: fakeNativeLib not transitively propagated to transitiveBin.completePropagatedBuildInputs"
              exit 1
            }

            touch $out
          '';

      # Eval-time check that cargo's per-unit flag table
      # (src/cargo/core/compiler/lto.rs) lands in the generated build
      # scripts for every crate type. The run tests above prove rustc
      # accepts the combinations end-to-end.
      ltoFlagTable =
        let
          crateWith =
            args:
            mkHostCrate (
              {
                crateName = "flagcheck";
                src = mkLib "src/lib.rs";
              }
              // args
            );
          crateWithDefaultLto =
            args:
            mkCrate (buildRustCrate.override { defaultLto = "thin"; }) (
              {
                crateName = "flagcheck";
                src = mkLib "src/lib.rs";
              }
              // args
            );
          libOpts = args: expected: lib.hasInfix ''LIB_LTO_OPTS="${expected}"'' (crateWith args).buildPhase;
          binOpts = args: expected: lib.hasInfix ''BIN_LTO_OPTS="${expected}"'' (crateWith args).buildPhase;
          testOpts =
            args: expected: lib.hasInfix ''LIB_TEST_LTO_OPTS="${expected}"'' (crateWith args).buildPhase;
          buildRsHasNoBitcode = args: lib.hasInfix "-C embed-bitcode=no" (crateWith args).configurePhase;
          checks = {
            binNull = binOpts { } "";
            binFalse = binOpts { lto = false; } "-C embed-bitcode=no";
            binTrue = binOpts { lto = true; } "-C lto";
            binFat = binOpts { lto = "fat"; } "-C lto=fat";
            binThin = binOpts { lto = "thin"; } "-C lto=thin";
            binOff = binOpts { lto = "off"; } "-C lto=off -C embed-bitcode=no";
            rlibNull = libOpts { } "";
            # rlib dependencies keep object code and embedded bitcode (see
            # build-crate.nix for why this diverges from cargo's
            # bitcode-only rlibs).
            rlibThin = libOpts { lto = "thin"; } "";
            rlibFalse = libOpts { lto = false; } "-C embed-bitcode=no";
            rlibOff = libOpts { lto = "off"; } "-C lto=off -C embed-bitcode=no";
            staticlibFat = libOpts {
              lto = "fat";
              type = [ "staticlib" ];
            } "-C lto=fat";
            cdylibThin = libOpts {
              lto = "thin";
              type = [ "cdylib" ];
            } "-C lto=thin";
            dylibThin = libOpts {
              lto = "thin";
              type = [ "dylib" ];
            } "-C embed-bitcode=no";
            mixedThin = libOpts {
              lto = "thin";
              type = [
                "rlib"
                "cdylib"
              ];
            } "";
            procMacroFat = libOpts {
              lto = "fat";
              procMacro = true;
            } "-C embed-bitcode=no";
            # "off" must not override the host treatment of proc macros:
            # the proc-macro branch in ltoFlags is ordered before the
            # off/false branches, like cargo's for_host check.
            procMacroOff = libOpts {
              lto = "off";
              procMacro = true;
            } "-C embed-bitcode=no";
            # Lib test harnesses are bin units, except for proc-macro
            # crates whose harness stays a host unit.
            harnessThin = testOpts { lto = "thin"; } "-C lto=thin";
            harnessProcMacroFat = testOpts {
              lto = "fat";
              procMacro = true;
            } "-C embed-bitcode=no";
            buildScriptThin = buildRsHasNoBitcode { lto = "thin"; };
            buildScriptNull = !(buildRsHasNoBitcode { });
            # defaultLto applies graph-wide via buildRustCrate.override,
            # and an explicit per-crate `lto` takes precedence over it.
            defaultLtoApplied =
              lib.hasInfix ''BIN_LTO_OPTS="-C lto=thin"''
                (crateWithDefaultLto { }).buildPhase;
            defaultLtoPerCrateWins =
              lib.hasInfix ''BIN_LTO_OPTS="-C lto=off -C embed-bitcode=no"''
                (crateWithDefaultLto { lto = "off"; }).buildPhase;
          };
          failed = lib.attrNames (lib.filterAttrs (_: ok: !ok) checks);
        in
        assert lib.assertMsg (failed == [ ]) "buildRustCrate LTO flag table mismatch: ${toString failed}";
        runCommand "buildRustCrate-lto-flag-table" { } "touch $out";

      # rustc runs the requested LTO while producing these artifacts.
      ltoStaticlibOutputs = assertOutputs {
        name = "lto-staticlib";
        output = "lib";
        crateArgs = {
          lto = "fat";
          libName = "lto_static";
          type = [ "staticlib" ];
          libPath = "src/lib.rs";
          src = mkLib "src/lib.rs";
        };
        expectedFiles = [
          "./nix-support/propagated-build-inputs"
          "./lib/liblto_static.a"
          "./lib/link"
        ];
      };

      ltoCdylibOutputs = assertOutputs {
        name = "lto-cdylib";
        output = "lib";
        crateArgs = {
          lto = "thin";
          libName = "lto_cdylib";
          type = [ "cdylib" ];
          libPath = "src/lib.rs";
          src = mkLib "src/lib.rs";
        };
        expectedFiles = [
          "./nix-support/propagated-build-inputs"
          "./lib/liblto_cdylib${stdenv.hostPlatform.extensions.sharedLibrary}"
          "./lib/link"
        ];
      };

      # Unsupported values must be rejected at eval time.
      ltoInvalidValueRejected =
        let
          result =
            builtins.tryEval
              (mkHostCrate {
                crateName = "lto-invalid";
                lto = "bogus";
                src = mkLib "src/lib.rs";
              }).drvPath;
        in
        assert lib.assertMsg (!result.success) "buildRustCrate accepted lto = \"bogus\"";
        runCommand "buildRustCrate-lto-invalid-rejected" { } "touch $out";

      # Prove the build_lib_test override really applies LTO flags to the
      # test harness: fat LTO over a dependency whose bitcode was stripped
      # (lto = false) must fail the harness link with a bitcode error. If
      # the override were lost, the harness would link without LTO and the
      # inner build would succeed, failing this test.
      ltoTestHarnessRunsLto =
        let
          dep = mkHostCrate {
            crateName = "stripped-dep";
            lto = false;
            src = mkLib "src/lib.rs";
          };
          crate = mkHostCrate {
            crateName = "lto-harness-canary";
            lto = "fat";
            dependencies = [ dep ];
            buildTests = true;
            src = mkFile "src/lib.rs" ''
              #[cfg(test)]
              #[test]
              fn uses_dep() {
                  assert_eq!(stripped_dep::test(), 23);
              }
            '';
          };
          failed = testers.testBuildFailure crate;
        in
        runCommand "assert-ltoTestHarnessRunsLto" { inherit failed; } ''
          grep -qi "bitcode" "$failed/testBuildFailure.log"
          touch $out
        '';
    }
    // lib.optionalAttrs (stdenv.hostPlatform.isElf && stdenv.hostPlatform == stdenv.buildPlatform) {
      # The implementation relies on rustc's default of embedding bitcode
      # in rlibs (cargo's ObjectAndBitcode state): inspect the section
      # headers to pin that down, and prove `-C embed-bitcode=no` actually
      # reaches rustc for the profiles that skip bitcode.
      ltoBitcodeSections =
        let
          rlibWith =
            name: args:
            mkHostCrate (
              {
                crateName = name;
                src = mkLib "src/lib.rs";
              }
              // args
            );
          rlibDefault = rlibWith "bitcode-default" { };
          rlibThin = rlibWith "bitcode-thin" { lto = "thin"; };
          rlibFalse = rlibWith "bitcode-false" { lto = false; };
          rlibOff = rlibWith "bitcode-off" { lto = "off"; };
        in
        runCommand "buildRustCrate-lto-bitcode-sections"
          {
            nativeBuildInputs = [ buildPackages.binutils ];
          }
          ''
            has_bitcode() {
              local dir=$(mktemp -d)
              (cd "$dir" && ar x "$1") || { echo "failed to extract $1" >&2; exit 1; }
              local o found_obj=no
              for o in "$dir"/*.o; do
                found_obj=yes
                if objdump -h "$o" 2>/dev/null | grep -qi llvmbc; then
                  return 0
                fi
              done
              # Guard against vacuously negative results: an rlib always
              # contains at least one object member.
              if [ "$found_obj" = no ]; then
                echo "no object members extracted from $1" >&2
                exit 1
              fi
              return 1
            }

            has_bitcode ${rlibDefault.lib}/lib/*.rlib || { echo "no bitcode in default rlib"; exit 1; }
            has_bitcode ${rlibThin.lib}/lib/*.rlib || { echo "no bitcode in lto=thin rlib"; exit 1; }
            ! has_bitcode ${rlibFalse.lib}/lib/*.rlib || { echo "unexpected bitcode in lto=false rlib"; exit 1; }
            ! has_bitcode ${rlibOff.lib}/lib/*.rlib || { echo "unexpected bitcode in lto=off rlib"; exit 1; }
            touch $out
          '';
    }
  );
  test = releaseTools.aggregate {
    name = "buildRustCrate-tests";
    meta = {
      description = "Test cases for buildRustCrate";
      maintainers = [ ];
    };
    constituents = builtins.attrValues (lib.filterAttrs (_: v: lib.isDerivation v) tests);
  };
}
