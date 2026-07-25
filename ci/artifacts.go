package main

// Artifacts is the firmware plumbing step, as a function rather than as
// workflow text: build a project and hand back the two files the gates
// downstream consume -- the linked ELF (ImageCheck reads its segments and
// vectors) and the raw binary a flasher writes to the chip (the bossac
// toolchain's `sam-ba`).
//
// It exists because the composition used to live in ci.yaml, where the ELF was
// exported to the host purely so a second `dagger call` could pass it back in
// to `zig obj-copy`. That round trip was sequencing expressed in YAML: it could
// not be run as one command anywhere else, and nothing versioned it with the
// code it built. As a function the whole chain is one `dagger call`, identical
// on a developer's machine and in CI, and the ELF never leaves the engine
// except as an output someone asked for.
//
// It is deliberately NOT a gate -- it asserts nothing. It is the seam between
// the build and the gates that do assert, kept separate so a failure there
// reads as "the firmware did not build" rather than as a violated invariant.

import (
	"fmt"
	"path"
	"strings"

	"dagger/ci/internal/dagger"
)

// Artifacts builds a firmware project and returns a directory holding its
// linked ELF and the raw binary image rendered from it.
//
// The build is the same `zig build` the project's own build gate runs, through
// the same pinned toolchain, so this composition adds no second way to build
// the firmware -- it reuses the cached one and only renders what the ELF does
// not already contain.
func (m *Ci) Artifacts(
	// The firmware project to build: the directory holding its build.zig.
	// Build outputs are ignored to keep the uploaded context small; the sources
	// themselves are read in full because the zig toolchain needs them.
	// +ignore=[".git", "**/zig-out", "**/.zig-cache"]
	source *dagger.Directory,
	// The linked ELF's path inside the build output, e.g. "bin/blinky.elf".
	// Which artifact is the firmware is the project's business (its build.zig
	// names it), not this function's to guess.
	elf string,
) (*dagger.Directory, error) {
	if source == nil {
		return nil, fmt.Errorf("source is required (the firmware project to build)")
	}
	if elf == "" {
		return nil, fmt.Errorf(
			"elf is required: the linked ELF's path inside the build output," +
				" e.g. --elf=bin/blinky.elf",
		)
	}

	elfName := path.Base(elf)
	binName := strings.TrimSuffix(elfName, path.Ext(elfName)) + ".bin"
	if binName == elfName {
		return nil, fmt.Errorf(
			"elf %q and the raw image rendered from it would have the same name;"+
				" give the ELF an extension (e.g. blinky.elf)", elf,
		)
	}

	elfFile := dag.Zig().Build(source).File(elf)
	binFile := dag.Zig().ObjCopy(elfFile, dagger.ZigObjCopyOpts{
		Format:     "binary",
		OutputName: binName,
	})
	return dag.Directory().
		WithFile(elfName, elfFile).
		WithFile(binName, binFile), nil
}
