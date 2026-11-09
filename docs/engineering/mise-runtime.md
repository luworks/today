# Pinned mise runtimes

Researched and checked on 2026-10-18 (America/Los_Angeles), from baseline
`760322e4476ace5feaf4f83f8bae5b09013f6396`. This lane owns only `.mise.toml`,
`mise.lock`, this document and `tests/devtools/test_mise_contract.py`.

## Ownership and upstream basis

- Bootstrap owns mise **2026.10.14**, XcodeGen, SwiftLint, Ruff and actionlint.
  Their exact versions, release URLs and archive SHA-256 values remain authoritative
  in [tool-pins.json](tool-pins.json). `.mise.toml` exposes the same worktree-local
  `bin` directories through `env._.path`; a PATH entry does not install, verify or
  activate a mise backend. There are no duplicate managed CLI entries or runners.
- mise's explicit `core:ruby` backend selects **3.3.12**, matching `Gemfile`,
  `Gemfile.lock` and `scripts/release/tool-lock.json`. The
  [Ruby release](https://www.ruby-lang.org/en/news/2026/07/16/ruby-3-3-12-released/)
  confirms this version. The lock selects the
  [jdx/ruby 3.3.12-2 binary build](https://github.com/jdx/ruby/releases/tag/3.3.12-2),
  rather than borrowing the unrelated upstream Ruby source-tarball checksum.
- `core:python` selects **3.14.8**, a mature bugfix branch rather than the newly
  released 3.15 series. The [official release](https://www.python.org/downloads/release/python-3148/)
  and [maintenance table](https://www.python.org/downloads/) establish availability
  and maintenance. The host's default `/usr/bin/python3` actually reports **3.9.6**;
  existing engineering lint targets `py39`. This runtime pin does not raise the
  scripts' supported syntax floor. 3.14 also provides standard-library `tomllib`.
  mise uses [python-build-standalone 20261013](https://github.com/astral-sh/python-build-standalone/releases/tag/20261013)
  for the locked arm64 binary.
- Bundler **4.0.16** and fastlane **2.241.2** stay owned by the existing release
  lock and checksummed `Gemfile.lock`, including its transitive gems. Do not add
  `gem:bundler` or `gem:fastlane`: that would create another install/dependency
  authority. See [Bundler metadata](https://rubygems.org/gems/bundler/versions/4.0.16),
  [fastlane metadata](https://rubygems.org/gems/fastlane/versions/2.241.2) and
  [fastlane's Bundler setup](https://docs.fastlane.tools/getting-started/ios/setup/).
- Xcode still supplies Swift and swift-format; the existing bootstrap/doctor owns
  their exact Xcode identity. Xcode's Python is not the managed Python pin.

## Generated lock and checksum boundary

The receipt-verified parent executable used read-only in this child was:

```text
/Users/yuanlu/.t3/worktrees/one-app/t3-6ff3ffcb/.dev-tools/mise/2026.10.14/bin/mise
```

`bootstrap(parent, tools=['mise'], plan=True)` returned `ready`, verifying its
receipt/files before execution. `mise --version` returned
`2026.10.14 macos-arm64 (2026-10-18)`. With `MISE_TRUSTED_CONFIG_PATHS` scoped to
this worktree, `mise lock --platform macos-arm64` generated format-3 `mise.lock`
without installing tools. See the [lock command](https://mise.jdx.dev/cli/lock.html)
and [lockfile reference](https://mise.jdx.dev/dev-tools/mise-lock-reference.html).

The committed lock contains exact release-build URLs and these payload digests:

- Ruby macOS archive: `753675928abff748a2061bd5a02fd827837d259ecdc45eead4d209a4179b2162`.
- CPython arm64 stripped install archive: `994adadc202c5df0b4570192cc9a70e3f2c131e512f4a125c56efa8562f44b28`.

Both equal the corresponding release asset `digest` fetched through GitHub's
primary API (`repos/jdx/ruby/releases/tags/3.3.12-2` and
`repos/astral-sh/python-build-standalone/releases/tags/20261013`). These are
publisher metadata cross-checks, not locally hashed runtime payloads. The lock's
`provenance = "github-attestations"` records mise's verification mechanism;
this lane has not performed runtime-install attestation verification.

Only macOS arm64 is locked and supported by this handoff. `ruby.compile = false`
and `python.compile = false` forbid compilation fallback; see the upstream
[Ruby](https://mise.jdx.dev/lang/ruby.html) and
[Python](https://mise.jdx.dev/lang/python.html) backend documentation.

## Host configuration acceptance and next gate

`mise config ls --json` listed only this project's `.mise.toml`, `override: false`.
`mise ls --current --json` selected exactly Ruby 3.3.12 and Python 3.14.8 from
that file, both `installed: false`. `mise config explain --json` recognized every
key. Host contract tests also use an isolated temporary `config.override.toml`
to prove a global Ruby override is detected. They do not edit user configuration.
Repeat the effective-config check on each integration host; project pins cannot
prevent an intentional user/global/environment override.

Run the focused check using a receipt-verified bootstrap binary:

```sh
MISE_BIN="$PWD/.dev-tools/mise/2026.10.14/bin/mise" \
  python3 -m unittest discover -s tests/devtools -p test_mise_contract.py -v
```

On Python 3.9/3.10 this check requires `tomli` (already available on this host);
Python 3.11+ uses `tomllib`. It runs no build, install or simulator.

**Missing acceptance gate:** the parent must wire runtime installation into its
existing bootstrap flow and actually run `mise install --locked ruby python` on
macOS arm64, retaining checksum/attestation results. Then verify `mise exec --
ruby --version` and `mise exec -- python3 --version`, provision Bundler 4.0.16 in
that Ruby, use frozen `Gemfile.lock` with `bundle _4.0.16_ install`, and run
`mise exec -- bundle _4.0.16_ exec fastlane --version`. No runtime, Bundler or
fastlane installation/execution is claimed here. No source build, Xcode/Swift
invocation, simulator, signing or release operation ran.

Raw command output and upstream release API responses are retained in the
primary checkout at `tests/results/mise-runtime-20261018-fedb8e94/`, indexed with
SHA-256 in `tests/results/activity.sqlite`, session
`mise-runtime-20261018-fedb8e94`. This is the QA journal, separate from app data.
