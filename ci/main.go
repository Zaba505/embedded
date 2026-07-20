// Continuous-integration gates for this repository, as Dagger functions.
//
// The GitHub Actions workflow is a thin shell: it installs the Dagger CLI and
// calls the functions here, plus the `zig` and `bossac` toolchains this module
// installs (see dagger.json). So every gate is defined once, runs identically
// on a developer's machine and in CI, and is versioned with the code it checks.
//
// The Zig toolchain is pinned by commit SHA in dagger.json: z5labs/devex
// publishes no git tags, and floating on its main branch would let an upstream
// change break the build with no commit here to point at. Bump it deliberately.
package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"unicode"

	"dagger/ci/internal/dagger"
)

// Ci is the module entrypoint; it carries no state.
type Ci struct{}

// LineLength gates the repo's 100-column line-length limit (zig-style-guide.md
// §2.2). It fails when any gated line is too long, so it can stand alone as a
// CI step.
//
// WHAT IT CHECKS
//
//	Every Zig source (*.zig) and Markdown prose (*.md) file, in one repo-wide
//	pass, so the limit applies to every project uniformly rather than one board.
//	The Go Dagger modules under daggerverse/ follow Go conventions and are out
//	of scope per the style guide, so they are skipped.
//
// HOW IT MEASURES
//
//	Columns are Unicode characters, NOT bytes. This matters: the prose here is
//	full of em-dashes and curly quotes, each one column but several UTF-8 bytes,
//	so a byte-based check would false-positive on every such line.
//
// EXEMPTIONS (each because the line genuinely cannot be wrapped shorter)
//
//  1. Markdown table rows -- a row's columns cannot be hard-wrapped.
//  2. Markdown fenced code blocks (``` / ~~~) -- a shell command or code
//     sample often has no safe break point.
//  3. An unbreakable tail: a line whose overflow past the limit contains no
//     whitespace, i.e. it ends in a single long token such as a URL. There is
//     nowhere after the limit to break it. This matches markdownlint MD013's
//     default lenience, so a line a column or two over that ends mid-word also
//     passes; authors should still target the limit.
func (m *Ci) LineLength(
	ctx context.Context,
	// The repository root to scan. Only Zig sources and Markdown prose are
	// gated; the rest is read but ignored, and the excluded paths below keep the
	// uploaded context small.
	// +ignore=[".git", "**/zig-out", "**/.zig-cache"]
	source *dagger.Directory,
	// Maximum columns (Unicode characters) per line.
	// +default=100
	limit int,
) (string, error) {
	if source == nil {
		return "", fmt.Errorf("source is required (the repository root to scan)")
	}
	if limit <= 0 {
		limit = 100
	}

	zig, err := source.Glob(ctx, "**/*.zig")
	if err != nil {
		return "", fmt.Errorf("globbing Zig sources: %w", err)
	}
	md, err := source.Glob(ctx, "**/*.md")
	if err != nil {
		return "", fmt.Errorf("globbing Markdown files: %w", err)
	}
	paths := append(zig, md...)
	sort.Strings(paths)

	var violations []string
	scanned := 0
	for _, path := range paths {
		if strings.HasPrefix(path, "daggerverse/") {
			continue
		}
		content, err := source.File(path).Contents(ctx)
		if err != nil {
			return "", fmt.Errorf("reading %s: %w", path, err)
		}
		scanned++
		violations = append(violations, overLimit(path, content, limit)...)
	}

	if len(violations) > 0 {
		return "", fmt.Errorf(
			"%d line(s) exceed %d columns (zig-style-guide.md §2.2); hard-wrap them.\n"+
				"Table rows, fenced code blocks, and unbreakable tails (URLs) are exempt.\n%s",
			len(violations), limit, strings.Join(violations, "\n"),
		)
	}
	return fmt.Sprintf(
		"OK: %d files scanned, every gated line within %d columns.", scanned, limit,
	), nil
}

// overLimit returns one message per over-limit line in content. See LineLength
// for the exemptions.
func overLimit(path, content string, limit int) []string {
	isMarkdown := strings.HasSuffix(path, ".md")
	inFence := false
	var out []string
	for i, line := range strings.Split(content, "\n") {
		line = strings.TrimRight(line, "\r")
		if isMarkdown {
			trimmed := strings.TrimLeft(line, " \t")
			if strings.HasPrefix(trimmed, "```") || strings.HasPrefix(trimmed, "~~~") {
				inFence = !inFence
				continue
			}
			if inFence {
				continue
			}
		}
		runes := []rune(line)
		if len(runes) <= limit {
			continue
		}
		if isMarkdown && strings.HasPrefix(strings.TrimLeft(line, " \t"), "|") {
			continue // table row: cannot wrap
		}
		if unbreakableTail(runes, limit) {
			continue // overflow is a single long token, e.g. a URL
		}
		out = append(out, fmt.Sprintf("  %s:%d: %d cols", path, i+1, len(runes)))
	}
	return out
}

// unbreakableTail reports whether nothing past the limit can be broken -- the
// overflow is a single token such as a URL, with no whitespace to wrap at.
func unbreakableTail(runes []rune, limit int) bool {
	for _, r := range runes[limit:] {
		if unicode.IsSpace(r) {
			return false
		}
	}
	return true
}
