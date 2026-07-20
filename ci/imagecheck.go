package main

// ImageCheck is the host-side artifact checker: given a linked firmware ELF and
// a target description, it asserts invariants that a compiler cannot and that a
// board would only reveal by hard-faulting on reset. It is the cheapest end of
// the host-side checking the simulation story (#8) builds on.
//
// It replaces an inline, board-specific reset-vector script that lived in the
// GitHub Actions workflow. Everything that was hardcoded there -- the SAM3X8E's
// flash and SRAM addresses -- now comes from a per-project target description
// (see arduino-due/blinky/target.json), so the same function serves every
// project and a future board is onboarded by supplying config, never by editing
// this checker.

import (
	"context"
	"debug/elf"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"dagger/ci/internal/dagger"
)

// busyboxRef is a byte-reading utility image, pinned by digest for the same
// reason dagger.json pins the toolchains: a floating tag would let an upstream
// change alter a gate with no commit here to point at. It is used only to read a
// file's raw bytes (see readArtifact); the checking is all Go.
const busyboxRef = "busybox:1.37@sha256:" +
	"9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"

// region is one span of the target's address map: a base address and a length,
// both written as hex (or decimal) strings in the target description so the
// numbers read the way a datasheet or linker script writes them.
type region struct {
	Origin string `json:"origin"`
	Length string `json:"length"`
}

// target describes one board's memory map and boot convention. It is the config
// that parameterizes this checker; onboarding a new project means writing one of
// these, not touching the code below.
type target struct {
	// Human labels, echoed into the report so a failure names the board.
	Name        string `json:"name"`
	Description string `json:"description"`
	// Which boot-vector convention to enforce. Only "cortex-m" is implemented;
	// the region checks below are architecture-neutral and always run.
	Vectors string `json:"vectors"`
	// The regions the invariants are checked against.
	Regions struct {
		// code is the programmable non-volatile region the image is stored in
		// and executes from (e.g. flash bank 0). The whole loaded image must
		// fit here, and the boot vectors must live at its origin.
		Code region `json:"code"`
		// ram is the writable region initialised data and zero-init statics run
		// in, and where the initial stack pointer must point.
		RAM region `json:"ram"`
	} `json:"regions"`
}

// span is a parsed [start, end) address range with a label for messages.
type span struct {
	name        string
	start, size uint64
}

func (s span) end() uint64 { return s.start + s.size }

// contains reports whether addr lies within [start, end). Boot addresses use
// this; the stack pointer is checked separately because a full-descending stack
// legitimately points one past the region's end.
func (s span) contains(addr uint64) bool {
	return addr >= s.start && addr < s.end()
}

// containsRange reports whether [start, start+size) lies wholly within s. A
// zero-size range is vacuously contained, which is what we want for an empty
// .data or .bss.
func (s span) containsRange(start, size uint64) bool {
	if size == 0 {
		return true
	}
	return start >= s.start && start+size <= s.end()
}

// parse turns a region's hex/decimal strings into a span. base 0 accepts the
// 0x prefix the descriptions use as well as plain decimal.
func (r region) parse(name string) (span, error) {
	origin, err := strconv.ParseUint(strings.TrimSpace(r.Origin), 0, 64)
	if err != nil {
		return span{}, fmt.Errorf("region %s: bad origin %q: %w", name, r.Origin, err)
	}
	length, err := strconv.ParseUint(strings.TrimSpace(r.Length), 0, 64)
	if err != nil {
		return span{}, fmt.Errorf("region %s: bad length %q: %w", name, r.Length, err)
	}
	if length == 0 {
		return span{}, fmt.Errorf("region %s: length is zero", name)
	}
	return span{name: name, start: origin, size: length}, nil
}

// ImageCheck asserts a linked firmware image is well-formed for its target,
// entirely on the host with no board attached. It fails, listing every
// violation at once, when any invariant is broken; otherwise it returns a report
// of what it verified.
//
// WHAT IT CHECKS (all parameterized by the target description)
//
//  1. Boot vectors are well-formed. On a Cortex-M the core reads two words from
//     the start of the image on reset -- the initial stack pointer and the
//     reset vector. The stack pointer must point into RAM, the reset vector
//     must point into the code region with its Thumb bit set (a clear bit
//     hard-faults instantly), and it must agree with the ELF entry point.
//  2. The image lies within the code region. Every loadable segment's load
//     address (where it is stored in flash) must fall inside the code region,
//     so the whole image fits the programmable NVM.
//  3. Section layout is as expected. Every loadable segment's run address must
//     fall inside either the code region (execute-in-place text/rodata) or RAM
//     (initialised .data). This is what catches an image linked against the
//     wrong memory map.
func (m *Ci) ImageCheck(
	ctx context.Context,
	// The linked firmware ELF to check (the build's *.elf output).
	image *dagger.File,
	// The target description (JSON): memory map and boot-vector convention.
	// See arduino-due/blinky/target.json for the schema.
	target *dagger.File,
) (string, error) {
	if image == nil {
		return "", fmt.Errorf("image is required (the linked firmware ELF)")
	}
	if target == nil {
		return "", fmt.Errorf("target is required (the target-description JSON)")
	}

	tgt, code, ram, err := loadTarget(ctx, target)
	if err != nil {
		return "", err
	}

	raw, err := readArtifact(ctx, image)
	if err != nil {
		return "", fmt.Errorf("reading image: %w", err)
	}
	f, err := elf.NewFile(strings.NewReader(raw))
	if err != nil {
		return "", fmt.Errorf("parsing image as ELF: %w", err)
	}
	defer f.Close()

	var (
		violations []string
		notes      []string
	)
	fail := func(format string, a ...any) {
		violations = append(violations, "  "+fmt.Sprintf(format, a...))
	}

	// (2) and (3): every loadable segment inside the declared regions.
	loads := 0
	var imageLow, imageHigh uint64
	for _, p := range f.Progs {
		if p.Type != elf.PT_LOAD {
			continue
		}
		loads++
		// Load address (LMA): where the segment is stored. It must fit flash.
		if !code.containsRange(p.Paddr, p.Filesz) {
			fail("segment loaded at [0x%08x,0x%08x) is outside the %s region [0x%08x,0x%08x)",
				p.Paddr, p.Paddr+p.Filesz, code.name, code.start, code.end())
		}
		// Run address (VMA): where it executes/lives. Text runs from flash;
		// initialised data runs from RAM. Anything else is a bad memory map.
		switch {
		case code.containsRange(p.Vaddr, p.Memsz), ram.containsRange(p.Vaddr, p.Memsz):
		default:
			fail("segment run at [0x%08x,0x%08x) is in neither the %s nor %s region",
				p.Vaddr, p.Vaddr+p.Memsz, code.name, ram.name)
		}
		if p.Filesz > 0 {
			if imageHigh == 0 || p.Paddr < imageLow {
				imageLow = p.Paddr
			}
			if p.Paddr+p.Filesz > imageHigh {
				imageHigh = p.Paddr + p.Filesz
			}
		}
	}
	if loads == 0 {
		fail("ELF has no loadable (PT_LOAD) segments")
	}

	// (1): boot vectors. The convention is target-selected; the region checks
	// above are architecture-neutral, this part is not.
	switch tgt.Vectors {
	case "cortex-m":
		checkCortexMVectors(f, code, ram, fail, &notes)
	case "":
		fail("target %q declares no vector convention (set \"vectors\")", tgt.Name)
	default:
		fail("target %q: unsupported vector convention %q (implemented: \"cortex-m\")",
			tgt.Name, tgt.Vectors)
	}

	if len(violations) > 0 {
		return "", fmt.Errorf(
			"%s (%s): %d image invariant(s) violated:\n%s",
			tgt.Name, tgt.Description, len(violations), strings.Join(violations, "\n"),
		)
	}

	report := []string{
		fmt.Sprintf("OK: %s (%s) image is well-formed.", tgt.Name, tgt.Description),
		fmt.Sprintf("  %d loadable segment(s), image spans [0x%08x,0x%08x) = %d B in %s (%d B).",
			loads, imageLow, imageHigh, imageHigh-imageLow, code.name, code.size),
	}
	report = append(report, notes...)
	return strings.Join(report, "\n"), nil
}

// readArtifact returns a file's raw bytes. It cannot use File.Contents: that
// crosses the GraphQL boundary as a string, which mangles the non-UTF-8 bytes
// of a binary ELF. Instead it mounts the file into a container and base64-
// encodes it, so only ASCII crosses the wire, then decodes it back here.
func readArtifact(ctx context.Context, file *dagger.File) (string, error) {
	b64, err := dag.Container().
		From(busyboxRef).
		WithMountedFile("/artifact", file).
		WithExec([]string{"base64", "/artifact"}).
		Stdout(ctx)
	if err != nil {
		return "", err
	}
	// base64 wraps its output; strip the newlines before decoding.
	raw, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(b64), ""))
	if err != nil {
		return "", fmt.Errorf("decoding artifact bytes: %w", err)
	}
	return string(raw), nil
}

// loadTarget reads and parses the target description, returning the raw target
// plus its two parsed regions.
func loadTarget(ctx context.Context, file *dagger.File) (target, span, span, error) {
	raw, err := file.Contents(ctx)
	if err != nil {
		return target{}, span{}, span{}, fmt.Errorf("reading target description: %w", err)
	}
	var tgt target
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields() // a typo in the config should fail loudly, not silently.
	if err := dec.Decode(&tgt); err != nil {
		return target{}, span{}, span{}, fmt.Errorf("parsing target description: %w", err)
	}
	if tgt.Name == "" {
		return target{}, span{}, span{}, fmt.Errorf("target description has no \"name\"")
	}
	code, err := tgt.Regions.Code.parse("code")
	if err != nil {
		return target{}, span{}, span{}, err
	}
	ram, err := tgt.Regions.RAM.parse("ram")
	if err != nil {
		return target{}, span{}, span{}, err
	}
	return tgt, code, ram, nil
}

// checkCortexMVectors verifies the ARMv7-M reset convention: two words at the
// start of the image are the initial stack pointer and the reset vector.
func checkCortexMVectors(
	f *elf.File, code, ram span, fail func(string, ...any), notes *[]string,
) {
	sp, ok := readWordAtLMA(f, code.start)
	if !ok {
		fail("no loadable data at the %s origin 0x%08x: vector table is missing",
			code.name, code.start)
		return
	}
	reset, ok := readWordAtLMA(f, code.start+4)
	if !ok {
		fail("image ends before the reset vector at 0x%08x", code.start+4)
		return
	}

	// Initial SP: must point into RAM. A full-descending stack pre-decrements,
	// so the top of RAM (one past the last word) is valid -- hence the inclusive
	// upper bound here rather than span.contains.
	spv := uint64(sp)
	if spv < ram.start || spv > ram.end() {
		fail("initial stack pointer 0x%08x is outside %s [0x%08x,0x%08x]",
			sp, ram.name, ram.start, ram.end())
	}

	// Reset vector: Thumb bit set (the core faults on a clear bit), and the
	// target instruction inside the code region.
	if reset&1 == 0 {
		fail("reset vector 0x%08x has no Thumb bit (bit 0 clear); the core will fault", reset)
	}
	entryAddr := uint64(reset) &^ 1
	if !code.contains(entryAddr) {
		fail("reset vector 0x%08x points outside the %s region [0x%08x,0x%08x)",
			reset, code.name, code.start, code.end())
	}

	// The reset vector and the ELF entry point are two records of the same
	// address; if they disagree the header is lying about where the image runs.
	if uint64(f.Entry) != uint64(reset) {
		fail("reset vector 0x%08x disagrees with the ELF entry point 0x%08x", reset, f.Entry)
	}

	*notes = append(*notes,
		fmt.Sprintf("  boot vectors: SP=0x%08x (in %s), reset=0x%08x (Thumb, in %s).",
			sp, ram.name, reset, code.name))
}

// readWordAtLMA reads the 32-bit word stored at load address lma, using the
// image's own byte order. It reads through program headers rather than section
// names so it works on a fully stripped image, and returns ok=false if no
// loaded segment holds that address.
func readWordAtLMA(f *elf.File, lma uint64) (uint32, bool) {
	for _, p := range f.Progs {
		if p.Type != elf.PT_LOAD {
			continue
		}
		if lma >= p.Paddr && lma+4 <= p.Paddr+p.Filesz {
			buf := make([]byte, 4)
			if _, err := p.ReadAt(buf, int64(lma-p.Paddr)); err != nil {
				return 0, false
			}
			return f.ByteOrder.Uint32(buf), true
		}
	}
	return 0, false
}
