package main

// HostTest is the shared host-test gate: it runs every project's
// target-independent tests natively, on the CI host, with no board attached.
// Zig cross-compiles trivially, so any logic that does not touch a specific
// peripheral can be compiled and exercised for the host regardless of the
// silicon the project eventually ships on -- which is why this is one shared
// gate rather than one per board.
//
// It is the seam the host-side simulation story (#8) plugs into: the place
// where "runs on the host" checks live, seeded here with the two free wins --
// compile-time invariant checks and pure-logic unit tests. Both ride the same
// `zig build test` invocation: compiling a test binary type-checks the code and
// fires every `comptime` assertion (a failed one is a build error), and running
// it exercises the `test { ... }` blocks.
//
// WHAT BELONGS HERE vs. ON HARDWARE
//
//	Host tests prove target-independent logic: a bit-mask predicate, a field
//	extraction, a `comptime` width check. They cannot prove anything that only
//	real silicon reveals -- a register's reset value, an interrupt actually
//	firing, a timing margin, an electrical level. Those need the board. See
//	docs/host-testing.md for the full division of labor.
//
// HOW A PROJECT CONTRIBUTES
//
//	Target-agnostic by construction: a project opts in by declaring a Zig build
//	step named `test` in its build.zig -- the same step `zig build test` runs.
//	No central registry and no edit to this gate; onboarding is a step in your
//	own build.zig, exactly as onboarding the image checker is a target.json.
//	A project with no such step (e.g. freestanding firmware with nothing yet
//	host-runnable, like arduino-due/blinky) is simply not picked up.

import (
	"context"
	"fmt"
	"path"
	"sort"
	"strings"

	"dagger/ci/internal/dagger"
)

// testStepMarker is how a build.zig announces it contributes host tests: a Zig
// build step registered under the name `test`. Detection is textual -- this is
// our own repo's uniform idiom (`b.step("test", ...)`), and reading the file is
// far cheaper than attempting `zig build test` everywhere just to tell a
// non-participating project apart from a genuine test failure by its error text.
const testStepMarker = `b.step("test"`

// HostTest runs the target-independent tests of every contributing package on
// the host and fails, listing every package that failed at once, if any test
// fails. Otherwise it returns a report of what ran.
//
// WHAT IT DOES
//
//  1. Discovers contributing packages: every build.zig in the repo that
//     declares a `test` step (see the file header for the contract). The Go
//     Dagger modules under daggerverse/ are out of scope.
//  2. Runs `zig build test` for each, natively for the host, through the same
//     pinned zig toolchain the rest of the pipeline uses -- so the compile-time
//     checks and unit tests run identically here and under `dagger call`.
func (m *Ci) HostTest(
	ctx context.Context,
	// The repository root to scan for contributing packages. Build outputs are
	// ignored to keep the uploaded context small; the packages themselves are
	// read in full because the zig toolchain needs their sources to build.
	// +ignore=[".git", "**/zig-out", "**/.zig-cache"]
	source *dagger.Directory,
) (string, error) {
	if source == nil {
		return "", fmt.Errorf("source is required (the repository root to scan)")
	}

	builds, err := source.Glob(ctx, "**/build.zig")
	if err != nil {
		return "", fmt.Errorf("globbing build.zig files: %w", err)
	}
	sort.Strings(builds)

	var packages []string
	for _, buildFile := range builds {
		if strings.HasPrefix(buildFile, "daggerverse/") {
			continue
		}
		content, err := source.File(buildFile).Contents(ctx)
		if err != nil {
			return "", fmt.Errorf("reading %s: %w", buildFile, err)
		}
		if strings.Contains(content, testStepMarker) {
			packages = append(packages, path.Dir(buildFile))
		}
	}

	if len(packages) == 0 {
		return "", fmt.Errorf(
			"no package declares a host `test` step, so there is nothing to run.\n" +
				"A project contributes host tests by registering a `test` step in its build.zig.",
		)
	}

	// Run every package even after one fails, so a single run reports every
	// failing package at once -- the same fail-listing-all idiom as the other
	// gates. The zig toolchain surfaces the failing package's own test output in
	// the error it returns, so that is what a failure carries.
	var (
		passed   []string
		failures []string
	)
	for _, pkg := range packages {
		if _, err := dag.Zig().Test(ctx, source.Directory(pkg)); err != nil {
			failures = append(failures, fmt.Sprintf("  %s: FAILED\n%s", pkg, indentLines(err.Error())))
			continue
		}
		passed = append(passed, "  "+pkg+": ok")
	}

	if len(failures) > 0 {
		return "", fmt.Errorf(
			"%d of %d host-test package(s) failed:\n%s",
			len(failures), len(packages), strings.Join(failures, "\n"),
		)
	}
	return fmt.Sprintf(
		"OK: %d package(s) host-tested, all passed.\n%s",
		len(packages), strings.Join(passed, "\n"),
	), nil
}

// indentLines indents every line of s by four spaces, so a nested test log
// reads as subordinate to the package line above it.
func indentLines(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, line := range lines {
		lines[i] = "    " + line
	}
	return strings.Join(lines, "\n")
}
