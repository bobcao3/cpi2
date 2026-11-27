# Development and releases

Use this guide to build Ghostmux, check changes, or prepare release packages.
For terminal commands, start with the [README](README.md).

## Build and check changes

The [build manifest](build.zig.zon) records the Zig requirement and pins source
dependencies. Update a dependency with `zig fetch --save=<name> <url>` rather
than editing the pin by hand. Native changes need a rebuild. JavaScript changes
apply directly in a linked checkout.

From the package directory:

```sh
zig build --release=safe
zig build test --release=safe
```

From the repository root:

```sh
node --test packages/ghostmux/tests/integration.test.mjs
```

The rendering checks decode PNGs with `sharp`. The JavaScript daemon suites need
POSIX and Python. Set `GHOSTMUX_BIN` to check a relocated executable.
[build.zig](build.zig) defines native fixtures, including platform exclusions.
This checkout does not include a CI build workflow.

## Resolve a binary

JavaScript callers use `@bobcao3/cpi-ghostmux/resolve`. The `/source` and
`/signature` exports provide provenance and verification. The private workspace
alias is `@cpi/ghostmux`.

The [resolver](bin/ghostmux-resolve.mjs) defines selection order and
source-build opt-in. `GHOSTMUX_BIN` must name an absolute executable path.
Overrides and local builds bypass signature verification, so use only binaries
you trust. Packaged binaries must pass version, platform, signature, and
source-digest checks. Verification failure is an error, not permission to fall
back.

Check [platforms.json](platforms.json) for CPU requirements. Package managers
match OS and architecture without checking instruction support. The
[services package](../services/README.md) integrates ghostmux with the agent
worker.

## Prepare a release

The workspace package is private. The [packaging script](scripts/package.mjs)
accepts a signed-artifact directory and a new output directory. Local staging
helpers emit the public `@bobcao3/cpi-ghostmux*` names and versioned npm aliases
under private `@cpi/*` dependency keys; there is no dependency on an absent CLI
package. When publishing staged packages, follow their `packages.json` order,
with native packages before the wrapper.

The original cpi release workflow is not included here. In that workflow,
disabling npm publication still publishes a GitHub release. It is not a dry run.

From this package directory, `GHOSTMUX_BIN=/absolute/path/to/ghostmux npm test`
runs the Node protocol, daemon, PTY, pipe, and rendering cases. Install the
declared `sharp` development dependency first; the daemon cases also require
Linux/POSIX and Python. This package-level command is separate from root
`zig build test`. The unloadable installation driver was retired: its repository
helpers are absent. The local packaging check exercises command loading and
saved wrapper names/aliases; it does not stage signed native artifacts, install
a package, or test signature tampering. There is still no retained
isolated-install or signature-tampering check. Before redistribution, read
[the supplemental notices](licenses/NOTICE.md) and check the files in the actual
bundle.
