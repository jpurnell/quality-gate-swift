# Homebrew formula for quality-gate.
#
# Lives here so it is versioned with the code it installs; the copy Homebrew reads belongs in
# the tap repository (`jpurnell/homebrew-tap`), as `Formula/quality-gate.rb`. Keep this one
# authoritative and copy it on release, rather than editing the tap by hand — a formula that
# drifts from the project it installs is the same class of problem as a README nobody runs.
#
# Install:  brew tap jpurnell/tap && brew install quality-gate
#
# ## Why a pre-built binary rather than build-from-source
#
# Homebrew's `install` runs sandboxed without network access. This package resolves ~20 SwiftPM
# dependencies at build time, so a from-source formula would need every one restated as a
# `resource` block and kept in step with Package.resolved by hand. The build is also 2,000+
# tasks across 120 targets: minutes of wall time and gigabytes of intermediates for someone who
# is evaluating a linter, not adopting one.
#
# A from-source variant is sketched at the bottom for the record, including what it costs.
#
# ## Why `write_exec_script` and not `install_symlink`
#
# SwiftPM resolves a resource bundle relative to the running executable: `Bundle.module` looks
# for `<executable dir>/quality-gate-swift_<Target>.bundle`. A symlink in `bin` would leave the
# executable path in `bin`, where the bundles are not, and the failure is the one the project's
# own README names — "couldn't find bundle named quality-gate-swift_ControlMapping".
#
# `write_exec_script` writes a wrapper that execs the real binary in `libexec`, so the
# executable path is the directory the bundles are in. `libexec.install Dir["*"]` then copies
# every bundle by construction, which is the right default: the hand-written glob in the README
# copied 40 of 44 and the shortfall passed as success until CI executed it.
class QualityGate < Formula
  desc "Static analysis for Swift 6 on SwiftSyntax and the index store"
  homepage "https://github.com/jpurnell/quality-gate-swift"
  license "MIT"
  version "3.5.0"

  # The package declares `.macOS(.v15)`. On macOS 14 it builds and then dies at launch with a
  # dyld error, so the floor is stated here rather than discovered by a user.
  depends_on macos: :sequoia

  # arm64 only, stated rather than implied.
  #
  # The package's floor is macOS 15, so an Intel bottle needs an Intel machine *running* 15 to
  # build on: GitHub's `macos-15` runner is arm64, and building on `macos-13` fails outright
  # because SwiftPM refuses the platform. Rather than ship an Intel artifact nothing verifies,
  # this says arm64 and sends everyone else to the source build, which does work there.
  depends_on arch: :arm64

  # The tag carries a `v`; `version` does not. Both appear here on purpose, and getting it
  # wrong gives a 404 on install rather than an error anyone can read.
  url "https://github.com/jpurnell/quality-gate-swift/releases/download/v3.5.0/quality-gate-3.5.0-macos-arm64.tar.gz"
  sha256 "REPLACE_WITH_ARM64_SHA256"

  def install
    # Everything, not a glob: the binary and every `*.bundle` beside it.
    libexec.install Dir["*"]
    bin.write_exec_script libexec/"quality-gate"
  end

  def caveats
    <<~EOS
      quality-gate reads `.quality-gate.yml` from the project root and writes nothing outside
      the project unless a corpus path is configured.

      To gate commits in a repository:
        quality-gate --check all --exclude test --strict --continue-on-failure
    EOS
  end

  test do
    # `--version` prints the bare version and nothing else — checked, because the first draft of
    # this block asserted the word "quality-gate" appeared in it and would have failed.
    #
    # Comparing it to the formula's own version is the useful assertion, not a formality. The
    # CLI carries its version as a hand-written literal in `QualityGateCLI.swift`, and
    # `release-readiness` checks CHANGELOG-against-tag parity without ever reading it — so the
    # binary reported 3.4.0 through a day of deploys past that tag. A formula is versioned by
    # the tag it downloads, so this test fails when the literal and the tag disagree, which is
    # the only place that currently would.
    assert_equal version.to_s, shell_output("#{bin}/quality-gate --version").strip
    assert_match "OVERVIEW", shell_output("#{bin}/quality-gate --help")

    # A trivial package, checked end to end. `safety` is static and needs no build.
    (testpath/"Package.swift").write <<~SWIFT
      // swift-tools-version: 6.0
      import PackageDescription
      let package = Package(name: "Demo", targets: [.target(name: "Demo")])
    SWIFT
    (testpath/"Sources/Demo").mkpath
    (testpath/"Sources/Demo/Demo.swift").write "public struct Demo { public init() {} }\n"
    assert_match "safety", shell_output("#{bin}/quality-gate --check safety 2>&1")
  end
end

# ## From-source variant, for the record
#
# Workable in a tap, not in homebrew-core, and only with the sandbox disabled:
#
#     depends_on xcode: ["16.0", :build]
#
#     def install
#       system "swift", "build", "--disable-sandbox", "-c", "release"
#       libexec.install Dir[".build/release/quality-gate", ".build/release/*.bundle"]
#       bin.write_exec_script libexec/"quality-gate"
#     end
#
# `--disable-sandbox` is what lets SwiftPM reach the network to resolve dependencies, and it is
# also why homebrew-core would reject this. Every dependency is public as of this writing —
# verified by a cold clone — so the resolution does work; it is the sandbox, not the
# credentials, that makes it unsuitable.
