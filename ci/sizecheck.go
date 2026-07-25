package main

// SizeCheck is the shared on-target size gate: the claim "this abstraction is
// free" (or "costs no more than N bytes"), measured on real machine code rather
// than asserted in a README.
//
// It replaces two bash entry points -- lib/assert/bench/measure.sh and
// lib/hal/bench/measure.sh -- that each built a package's bench images through
// the pinned zig toolchain and did the arithmetic and the thresholding in
// shell. Everything package-specific that lived in those scripts (which images
// to compare, over how many instances, against what budget) now comes from a
// per-package budget description (see lib/hal/bench/size-budget.json), so the
// same function serves every package and a new size gate is a JSON file, never
// an edit to this checker -- exactly as a new board is a target.json to
// ImageCheck.
//
// WHY ONE FUNCTION AND NOT TWO
//
//	The two gates read as different claims -- lib/assert measures the flash cost
//	of one assertion, lib/hal measures a seam against hand-written registers on
//	two architectures -- but they are the same measurement: the .text delta
//	between a pair of images that differ only in the thing being priced,
//	amortized over however many instances of that thing the image contains, and
//	held under a budget. lib/hal is the degenerate case of one instance. Writing
//	that shape once is what makes the third size gate free.
//
// WHAT IT CANNOT PROVE
//
//	Bytes of a section, and nothing else. Two images of identical size can hold
//	different instructions, so "byte-identical instruction stream" (which
//	lib/hal's README claims of its seam) is a stronger statement than this gate
//	makes; it is checked by disassembling, by hand, when the claim is written.
//	Nor does a size gate say anything about cycles.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"dagger/ci/internal/dagger"
)

// defaultBudgetPath is where a package keeps its budget description, relative
// to the package root, when --budget is not passed. Convention over
// configuration: it puts the budget next to the bench sources it prices.
const defaultBudgetPath = "bench/size-budget.json"

// imageDir is where `zig build` installs executables inside its output
// directory. The budget names images, not paths, and they are resolved here.
const imageDir = "bin"

// sizeBudget is one package's size gate: how to build its bench images, which
// section to weigh them by, and the costs to hold under budget. It is the
// config that parameterizes this checker.
type sizeBudget struct {
	// Human labels, echoed into the report so a failure names the package and
	// the claim it just falsified.
	Name  string `json:"name"`
	Claim string `json:"claim"`

	// Step is the Zig build step that produces the bench images (`bench` by
	// convention in this repo). Optimize is the mode to build them in --
	// ReleaseSmall is what firmware ships in and the mode where an abstraction
	// has to earn its keep. Section is which of the zig module's section totals
	// to weigh: text, data, bss, flash (text+data) or ram (data+bss).
	Step     string `json:"step"`
	Optimize string `json:"optimize"`
	Section  string `json:"section"`

	Costs []sizeCost `json:"costs"`
}

// sizeCost is one measurement: the price of whatever distinguishes subject from
// baseline, per instance, and the budget it must stay under.
type sizeCost struct {
	// Name labels this measurement in the report (e.g. "cortex-m3").
	Name string `json:"name"`
	// Baseline and Subject name two images from the build's bin/ directory that
	// are identical BUT FOR the thing being priced -- that is what makes the
	// delta between them attributable to it and to nothing else.
	Baseline string `json:"baseline"`
	Subject  string `json:"subject"`
	// Instances is how many of the priced thing the subject contains, so a
	// budget is per-instance: 8 assertions in an image, one seam per
	// architecture. Defaults to 1.
	Instances int `json:"instances"`
	// Unit names what an instance is, for the report ("assertion").
	Unit string `json:"unit"`
	// MaxBytes is the per-instance budget. A pointer because 0 is a real and
	// deliberate budget (lib/hal's seam), so "absent" must be distinguishable
	// from "zero" rather than silently defaulting to the strictest gate.
	MaxBytes *int `json:"max_bytes"`
}

// SizeCheck builds a package's size benchmark through the pinned zig toolchain
// and fails, listing every measurement over budget at once, when any cost
// exceeds what the package declared. Otherwise it returns the measurement
// table as a report -- the same table the package's README quotes.
//
// WHAT IT DOES
//
//  1. Reads the package's budget description (--budget, or bench/size-budget.json
//     inside --source).
//  2. Builds the named build step once, at the named optimize mode, through the
//     zig toolchain pinned in dagger.json -- so the toolchain is the same one
//     every other gate uses, and there is no second copy of that pin anywhere.
//  3. Weighs each named image's section total and prices every cost as
//     (subject - baseline) / instances.
//  4. Fails if any cost exceeds its budget. The comparison is exact --
//     delta > max*instances -- so a fractional cost cannot round its way under
//     a threshold.
func (m *Ci) SizeCheck(
	ctx context.Context,
	// The package to measure: the directory holding its build.zig. Build
	// outputs are ignored to keep the uploaded context small; the sources
	// themselves are read in full because the zig toolchain needs them.
	// +ignore=[".git", "**/zig-out", "**/.zig-cache"]
	source *dagger.Directory,
	// The budget description (JSON). Defaults to bench/size-budget.json inside
	// source; pass it explicitly only to price a package against a different
	// budget than the one it ships.
	// +optional
	budget *dagger.File,
) (string, error) {
	if source == nil {
		return "", fmt.Errorf("source is required (the package to measure)")
	}
	if budget == nil {
		// Checked rather than left to fail on read: the message a package sees
		// when it has not written a budget yet is the whole of its onboarding
		// instructions, and "no such file" alone does not say what to write.
		ok, err := source.Exists(ctx, defaultBudgetPath)
		if err != nil {
			return "", fmt.Errorf("looking for %s: %w", defaultBudgetPath, err)
		}
		if !ok {
			return "", fmt.Errorf(
				"no %s in this package: a package opts into the size gate by"+
					" writing one, naming the image pairs its bench step builds,"+
					" how many instances of the priced thing each holds, and the"+
					" per-instance budget. See lib/hal/bench/size-budget.json."+
					" Pass --budget to point somewhere else.",
				defaultBudgetPath,
			)
		}
		budget = source.File(defaultBudgetPath)
	}

	b, err := loadSizeBudget(ctx, budget)
	if err != nil {
		return "", err
	}

	out := dag.Zig().Build(source, dagger.ZigBuildOpts{
		Optimize: b.Optimize,
		Steps:    []string{b.Step},
	})
	images, err := out.Entries(ctx, dagger.DirectoryEntriesOpts{Path: imageDir})
	if err != nil {
		return "", fmt.Errorf(
			"the %q step built no %s/ directory, so there are no images to weigh: %w",
			b.Step, imageDir, err,
		)
	}

	// Weigh each distinct image once: an image is usually a baseline or a
	// subject in more than one cost, and each weighing is a round trip.
	sizes := make(map[string]int)
	weigh := func(name string) (int, error) {
		if size, ok := sizes[name]; ok {
			return size, nil
		}
		if !contains(images, name) {
			return 0, fmt.Errorf(
				"no image %q in the %q step's output; it built: %s",
				name, b.Step, strings.Join(images, ", "),
			)
		}
		file := out.File(imageDir + "/" + name)
		size, err := sectionBytes(ctx, dag.Zig().Size(file), b.Section)
		if err != nil {
			return 0, fmt.Errorf("weighing %s: %w", name, err)
		}
		sizes[name] = size
		return size, nil
	}

	var (
		rows       []string
		violations []string
	)
	widths := columnWidths(b.Costs)
	for _, cost := range b.Costs {
		baseline, err := weigh(cost.Baseline)
		if err != nil {
			return "", err
		}
		subject, err := weigh(cost.Subject)
		if err != nil {
			return "", err
		}

		delta := subject - baseline
		rows = append(rows, cost.row(widths, baseline, subject, delta))
		// Exact: no division, so no rounding can hide a cost under its budget.
		if delta > *cost.MaxBytes*cost.Instances {
			violations = append(violations, fmt.Sprintf(
				"  %s: %s costs %+d B of .%s over %s = %s, above the %d B/%s budget",
				cost.Name, cost.Subject, delta, b.Section, cost.Baseline,
				cost.perUnit(delta), *cost.MaxBytes, cost.unit(),
			))
		}
	}

	table := fmt.Sprintf(
		"%s -- %s\n  step=%s  optimize=%s  section=.%s\n\n%s\n",
		b.Name, b.Claim, b.Step, b.Optimize, b.Section, strings.Join(rows, "\n"),
	)
	if len(violations) > 0 {
		return "", fmt.Errorf(
			"%s\n%d of %d measurement(s) over budget -- %q no longer holds:\n%s",
			table, len(violations), len(b.Costs), b.Claim,
			strings.Join(violations, "\n"),
		)
	}
	return fmt.Sprintf(
		"%s\nOK: %d measurement(s) within budget; %s.",
		table, len(b.Costs), b.Claim,
	), nil
}

// row renders one measurement, padded to the table's column widths.
func (c sizeCost) row(w columns, baseline, subject, delta int) string {
	return fmt.Sprintf(
		"  %-*s  %-*s %5d B  ->  %-*s %5d B   delta %+5d B = %s  (max %d)",
		w.name, c.Name,
		w.baseline, c.Baseline, baseline,
		w.subject, c.Subject, subject,
		delta, c.perUnit(delta), *c.MaxBytes,
	)
}

// perUnit renders the per-instance cost. One decimal place because the honest
// figure often is fractional -- 68 bytes over 8 assertions is 8.5, and printing
// 8 would understate what the gate actually measured.
func (c sizeCost) perUnit(delta int) string {
	return fmt.Sprintf("%.1f B/%s", float64(delta)/float64(c.Instances), c.unit())
}

func (c sizeCost) unit() string {
	if c.Unit == "" {
		return "instance"
	}
	return c.Unit
}

// columns holds the padding widths of the report's name columns, computed from
// the data so the table lines up whatever a package calls its images.
type columns struct{ name, baseline, subject int }

func columnWidths(costs []sizeCost) columns {
	var w columns
	for _, c := range costs {
		w.name = max(w.name, len(c.Name))
		w.baseline = max(w.baseline, len(c.Baseline))
		w.subject = max(w.subject, len(c.Subject))
	}
	return w
}

// sectionBytes reads one of the zig module's section totals by name. The names
// are the module's own (`dagger call zig size --input=<f> text`), so the budget
// description and the toolchain agree on what a section is.
func sectionBytes(
	ctx context.Context, sizes *dagger.ZigSectionSizes, section string,
) (int, error) {
	switch section {
	case "text":
		return sizes.Text(ctx)
	case "data":
		return sizes.Data(ctx)
	case "bss":
		return sizes.Bss(ctx)
	case "flash":
		return sizes.Flash(ctx)
	case "ram":
		return sizes.RAM(ctx)
	}
	return 0, fmt.Errorf(
		"unknown section %q (known: text, data, bss, flash, ram)", section,
	)
}

// loadSizeBudget reads, parses and validates a budget description. Every
// default is applied here, so the checker above reads a fully-specified budget.
func loadSizeBudget(ctx context.Context, file *dagger.File) (sizeBudget, error) {
	raw, err := file.Contents(ctx)
	if err != nil {
		return sizeBudget{}, fmt.Errorf(
			"reading the size budget (expected at %s inside --source, or passed"+
				" as --budget): %w", defaultBudgetPath, err,
		)
	}
	var b sizeBudget
	dec := json.NewDecoder(strings.NewReader(raw))
	dec.DisallowUnknownFields() // a typo in the config should fail loudly.
	if err := dec.Decode(&b); err != nil {
		return sizeBudget{}, fmt.Errorf("parsing the size budget: %w", err)
	}

	if b.Name == "" {
		return sizeBudget{}, fmt.Errorf("size budget has no \"name\"")
	}
	if b.Claim == "" {
		return sizeBudget{}, fmt.Errorf(
			"size budget %q has no \"claim\": a size gate exists to hold a claim,"+
				" and a failure has to be able to name the one it just falsified",
			b.Name,
		)
	}
	if b.Step == "" {
		b.Step = "bench"
	}
	if b.Optimize == "" {
		b.Optimize = "ReleaseSmall"
	}
	if b.Section == "" {
		b.Section = "text"
	}
	if len(b.Costs) == 0 {
		return sizeBudget{}, fmt.Errorf(
			"size budget %q declares no \"costs\", so it gates nothing", b.Name,
		)
	}

	for i := range b.Costs {
		c := &b.Costs[i]
		where := fmt.Sprintf("size budget %q, cost %d", b.Name, i+1)
		if c.Name != "" {
			where = fmt.Sprintf("size budget %q, cost %q", b.Name, c.Name)
		}
		switch {
		case c.Name == "":
			return sizeBudget{}, fmt.Errorf("%s: has no \"name\"", where)
		case c.Baseline == "":
			return sizeBudget{}, fmt.Errorf("%s: has no \"baseline\" image", where)
		case c.Subject == "":
			return sizeBudget{}, fmt.Errorf("%s: has no \"subject\" image", where)
		case c.Baseline == c.Subject:
			return sizeBudget{}, fmt.Errorf(
				"%s: baseline and subject are the same image (%q), so the delta"+
					" is zero by construction and gates nothing", where, c.Subject,
			)
		case c.MaxBytes == nil:
			return sizeBudget{}, fmt.Errorf(
				"%s: has no \"max_bytes\" budget (0 is a valid budget; absent is not)",
				where,
			)
		case c.Instances < 0:
			return sizeBudget{}, fmt.Errorf(
				"%s: \"instances\" is negative (%d)", where, c.Instances,
			)
		}
		if c.Instances == 0 {
			c.Instances = 1
		}
	}
	return b, nil
}

// contains reports whether names holds name. The entry lists this is called
// with are a handful of build outputs, so a linear scan is the whole of it.
func contains(names []string, name string) bool {
	for _, n := range names {
		if n == name {
			return true
		}
	}
	return false
}
