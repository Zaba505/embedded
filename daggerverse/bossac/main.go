// Flash Atmel SAM microcontrollers over SAM-BA with bossac, without installing
// a flashing tool on the host.
//
// This exists because probe-rs -- and therefore the z5labs/devex flash module --
// speaks SWD/JTAG and needs a physical debug probe. A SAM device with no probe
// attached can still be programmed through its ROM-resident SAM-BA monitor over
// a plain USB cable, which is what bossac does. It is the no-probe path.
//
// What it cannot do: SAM-BA is a flash programmer, not a debug interface. There
// are no breakpoints, no halting, no memory inspection and no GDB here. Those
// need a probe and the flash module.
//
// Scope: written for this repository's Arduino Due work and kept deliberately
// close in shape to daggerverse/flash -- same transport model, same
// factory-then-verb chaining, same result type -- so it can be lifted upstream
// later without redesign.
package main

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"dagger/bossac/internal/dagger"
)

const (
	defaultDebianTag = "bookworm-slim"

	// The bossac version is not an incidental detail -- it decides whether the
	// board boots afterwards.
	//
	// BOSSA issue #125, still open, reports that versions after 1.7 flash the
	// Arduino Due and verify the write successfully, yet leave the board unable
	// to run any code, with "LEDs etc in default state". Debian's bossa-cli is
	// 1.9.1 and does exactly this: it reports a clean write, a clean verify, and
	// sets the boot-from-flash bit, and the chip still never executes. Every one
	// of those success signals is true and none of them means the board works.
	//
	// Arduino's own SAM core pins 1.6.1-arduino for this board, but that build
	// dies with SIGFPE enumerating lock regions under --info. 1.7.0 is the
	// newest version confirmed working on real hardware here.
	//
	// If you bump this, prove it on a board before trusting a green verify.
	bossacVersion = "1.7.0"
	bossacURL     = "https://downloads.arduino.cc/tools/bossac-1.7.0-x86_64-linux-gnu.tar.gz"
	bossacSHA256  = "9475c0c8596c1ba12dcbce60e48fef7559087fa8eccbea7bab732113f3c181ee"

	// IANA-assigned USB/IP port, and the default usbipd listens on.
	defaultUsbipPort = "3240"

	// Where the image is mounted read-only inside the container.
	firmwarePath = "/fw/firmware.bin"

	// How long to wait for the USB/IP-attached device node to appear.
	deviceWaitTries  = 50
	deviceWaitPeriod = "0.2"
)

// Bossac is the module entrypoint. It carries no state; SamBa is the real
// constructor.
type Bossac struct{}

// Flasher is a prepared bossac invocation. Build one with SamBa, then call
// Plan, Info or Run on it.
type Flasher struct {
	// +private
	Ctr *dagger.Container
	// +private
	Attach []string
	// +private
	Argv []string
	// +private
	SerialPort string
	// +private
	Touch bool
}

// FlashResult is the outcome of a bossac invocation.
//
// A clean bossac failure -- no device, wrong port, verify mismatch -- comes
// back as a non-zero ExitCode with no Go error, exactly as daggerverse/flash
// behaves. Check ExitCode rather than assuming a successful `dagger call` means
// a successful flash. A timeout surfaces as 124.
type FlashResult struct {
	// Combined stdout and stderr from bossac.
	Output string
	// bossac's exit status. 0 on success, 124 if the timeout fired.
	ExitCode int
}

// SamBa prepares a bossac invocation against a SAM device attached over USB/IP.
//
// Transport is USB/IP because a container cannot otherwise reach a USB serial
// device: Dagger has no device passthrough, and a serial port is not a unix
// socket, so it cannot be forwarded like one. USB/IP is also what
// daggerverse/flash uses, so a host set up for this is already set up for a
// debug probe later.
func (b *Bossac) SamBa(
	ctx context.Context,
	// The firmware image to write. Raw binary, not ELF -- bossac has no ELF
	// parser. Produce one with the zig module's obj-copy --format=binary.
	firmware *dagger.File,
	// USB/IP server to attach from, as host or host:port. Must be an address the
	// Dagger engine can route to; 127.0.0.1 inside the container is the
	// container itself, never your machine.
	usbip string,
	// USB bus id to attach, e.g. "3-1". Find it with `usbip list -l` on the host.
	busid string,
	// Serial device name that appears once attached, without the /dev/ prefix.
	// +default="ttyACM0"
	port string,
	// True if the device's own USB controller runs SAM-BA (an Arduino Due's
	// Native port). False for a USB-to-serial bridge into the chip's UART,
	// which is what the Due's Programming port is. Maps to bossac --usb-port.
	// +default=false
	nativeUsb bool,
	// Open the port at 1200 baud and close it before programming, to drop the
	// board into SAM-BA. Required for Arduino boards, whose USB-serial chip
	// watches for 1200 baud and pulses ERASE and RESET in response. Turn it off
	// only if the board is already in its SAM-BA monitor, e.g. after pressing
	// ERASE and RESET by hand.
	// +default=true
	touch bool,
	// Erase flash before writing.
	// +default=true
	erase bool,
	// Read flash back and compare against the image after writing.
	// +default=true
	verify bool,
	// Set the boot-from-flash NVM bit, so the device runs the application
	// instead of returning to the SAM-BA monitor on reset.
	// +default=true
	bootFromFlash bool,
	// Reset the device once programming finishes.
	// +default=true
	reset bool,
	// Byte offset into flash to program at. Leave empty for the device default,
	// which is the start of its application flash.
	// +default=""
	offset string,
	// Registry to pull the debian base image from.
	// +default="docker.io"
	registry string,
) (*Flasher, error) {
	if firmware == nil {
		return nil, fmt.Errorf("firmware must not be nil; pass a *dagger.File containing a raw binary image")
	}
	if strings.TrimSpace(usbip) == "" {
		return nil, fmt.Errorf("usbip is required: a container cannot reach a USB serial device without it")
	}
	if strings.TrimSpace(busid) == "" {
		return nil, fmt.Errorf("busid is required with usbip (the USB bus id to attach, e.g. 3-1)")
	}
	if strings.TrimSpace(port) == "" {
		return nil, fmt.Errorf("port must not be empty (the serial device name, e.g. ttyACM0)")
	}
	if strings.ContainsRune(port, '/') {
		return nil, fmt.Errorf("port %q must be a bare device name without /dev/, e.g. ttyACM0", port)
	}

	host, tcpPort := splitHostPort(usbip, defaultUsbipPort)
	attach := []string{"usbip", "--tcp-port", tcpPort, "attach", "-r", host, "-b", busid}

	return &Flasher{
		Ctr:        b.container(registry).WithMountedFile(firmwarePath, firmware),
		Attach:     attach,
		Argv:       bossacArgv(port, nativeUsb, erase, verify, bootFromFlash, reset, offset),
		SerialPort: port,
		Touch:      touch,
	}, nil
}

// BridgeCommand prints the command to run on the machine physically holding the
// device, which exports it over USB/IP so the container can attach to it.
//
// It only prints; nothing is executed here. Run the output as root on that
// machine, having loaded the usbip-host and vhci-hcd kernel modules first.
func (b *Bossac) BridgeCommand(
	// USB bus id to export, e.g. "3-1".
	busid string,
	// TCP port for usbipd to listen on.
	// +default="3240"
	port string,
) string {
	return fmt.Sprintf("usbipd -D --tcp-port %s && usbip bind --busid %s", shQuote(port), shQuote(busid))
}

// ToolVersion reports the bossac build in the container. Needs no hardware.
func (b *Bossac) ToolVersion(ctx context.Context,
	// +default="docker.io"
	registry string,
) (string, error) {
	out, err := b.container(registry).
		WithExec([]string{"sh", "-c", "bossac --help 2>&1 | sed -n '2p'"}).
		Stdout(ctx)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// Plan renders the exact commands this Flasher will run, without touching
// hardware or the network.
//
// This is the one function that is safe in CI: it proves the arguments are
// assembled correctly without needing a board attached.
func (fl *Flasher) Plan(ctx context.Context) (string, error) {
	return strings.Join(fl.script(), "\n"), nil
}

// Run attaches the device and programs it.
//
// +cache="never"
func (fl *Flasher) Run(ctx context.Context,
	// +default=120
	timeoutSeconds int,
) (*FlashResult, error) {
	return fl.exec(ctx, strings.Join(fl.script(), " && "), timeoutSeconds)
}

// Info attaches the device and reports what bossac finds there, writing
// nothing. Use it to confirm the board is reachable before a real flash.
//
// +cache="never"
func (fl *Flasher) Info(ctx context.Context,
	// +default=120
	timeoutSeconds int,
) (*FlashResult, error) {
	steps := []string{
		shJoin(fl.Attach),
		waitForDevice(fl.SerialPort),
		shJoin([]string{"bossac", "--port=" + fl.SerialPort, "--info"}),
	}
	return fl.exec(ctx, strings.Join(steps, " && "), timeoutSeconds)
}

// script is the full attach-wait-touch-program sequence, one step per element.
func (fl *Flasher) script() []string {
	steps := []string{
		shJoin(fl.Attach),
		waitForDevice(fl.SerialPort),
	}
	if fl.Touch {
		steps = append(steps, touchCommand(fl.SerialPort))
	}
	return append(steps, shJoin(fl.Argv))
}

func (fl *Flasher) exec(ctx context.Context, script string, timeoutSeconds int) (*FlashResult, error) {
	if timeoutSeconds <= 0 {
		timeoutSeconds = 120
	}

	// SIGKILL after the deadline, and normalise the 137 that produces into
	// timeout(1)'s conventional 124 so callers have one number to check.
	const wrapper = `timeout -s KILL "$0" sh -c "$1"; ec=$?; [ "$ec" -eq 137 ] && ec=124; exit "$ec"`

	ctr := fl.Ctr.WithExec(
		[]string{"sh", "-c", wrapper, strconv.Itoa(timeoutSeconds), script + " 2>&1"},
		dagger.ContainerWithExecOpts{
			// bossac failures are data, not errors: surface them as ExitCode.
			Expect: dagger.ReturnTypeAny,
			// usbip attach drives the vhci_hcd driver through sysfs, which an
			// unprivileged exec cannot do. This is also why the engine itself
			// must be running privileged; without it the attach fails with EPERM.
			InsecureRootCapabilities: true,
		},
	)

	out, err := ctr.CombinedOutput(ctx)
	if err != nil {
		return nil, fmt.Errorf("running bossac: %w", err)
	}
	code, err := ctr.ExitCode(ctx)
	if err != nil {
		return nil, fmt.Errorf("reading bossac exit code: %w", err)
	}

	return &FlashResult{Output: out, ExitCode: code}, nil
}

func (b *Bossac) container(registry string) *dagger.Container {
	if strings.TrimSpace(registry) == "" {
		registry = "docker.io"
	}
	// Debian rather than Alpine: the pinned bossac build and the usbip tools are
	// both glibc-linked.
	ref := fmt.Sprintf("%s/library/debian:%s", registry, defaultDebianTag)

	// Deliberately NOT `apt-get install bossa-cli`. Debian ships 1.9.1, which
	// silently produces unbootable boards -- see the bossacVersion comment.
	install := fmt.Sprintf(
		"echo '%s  /tmp/bossac.tar.gz' | sha256sum -c - && "+
			"tar xzf /tmp/bossac.tar.gz -C /usr/local/bin --strip-components=1 && "+
			"chmod +x /usr/local/bin/bossac && rm -f /tmp/bossac.tar.gz",
		bossacSHA256,
	)

	return dag.Container().
		From(ref).
		WithExec([]string{"sh", "-c",
			"apt-get update -qq && " +
				"apt-get install -y -qq --no-install-recommends ca-certificates usbip && " +
				"rm -rf /var/lib/apt/lists/*"}).
		WithFile("/tmp/bossac.tar.gz", dag.HTTP(bossacURL)).
		WithExec([]string{"sh", "-c", install})
}

// bossacArgv assembles the bossac 1.7.0 command line.
//
// The flag spellings here are 1.7.0's, and they differ from 1.9.x in a way that
// matters. 1.7.0 has `-U, --force_usb_port=true/false` with a REQUIRED argument;
// 1.9.x renamed it to `--usb-port[=BOOL]` with an OPTIONAL one. That rename is
// why Arduino's platform.txt "-U false" is correct for the version it targets
// but ambiguous under 1.9.x, where getopt refuses to bind a space-separated
// value and leaves "false" as a positional -- which bossac then takes for the
// input FILE. Values are attached with = throughout so the point is moot.
//
// 1.7.0 also has no --arduino-erase, so the 1200-baud touch is done separately;
// see touchCommand.
func bossacArgv(port string, nativeUsb, erase, verify, bootFromFlash, reset bool, offset string) []string {
	argv := []string{"bossac", "--port=" + port}

	// true means SAM-BA is spoken to the chip's own USB controller (an Arduino
	// Due's Native port); false means it arrives on the chip's UART through an
	// external USB-serial bridge, which is the Due's Programming port.
	argv = append(argv, "--force_usb_port="+boolWord(nativeUsb))

	if strings.TrimSpace(offset) != "" {
		argv = append(argv, "--offset="+offset)
	}
	if erase {
		argv = append(argv, "--erase")
	}
	// --write is implied by having an image to program at all.
	argv = append(argv, "--write")
	if verify {
		argv = append(argv, "--verify")
	}
	if bootFromFlash {
		argv = append(argv, "--boot=1")
	}
	if reset {
		argv = append(argv, "--reset")
	}

	// FILE last, matching bossac's documented "bossac [OPTION...] [FILE]".
	return append(argv, firmwarePath)
}

// touchCommand opens the port at 1200 baud and closes it, which is what makes
// an Arduino board's USB-serial chip pulse ERASE and RESET and drop the MCU
// into its SAM-BA monitor.
//
// bossac gained a built-in --arduino-erase for this after 1.7.0, but the
// versions that have it are the ones that leave the Due unbootable, so the
// touch is done by hand here.
func touchCommand(port string) string {
	dev := "/dev/" + port
	return fmt.Sprintf(
		"stty -F %s raw ispeed 1200 ospeed 1200 cs8 -cstopb ignpar eol 255 eof 255 || true; sleep 2",
		shQuote(dev),
	)
}

// waitForDevice polls for the device node, which appears asynchronously after
// usbip attach returns -- the kernel still has to enumerate it and bind a tty.
func waitForDevice(port string) string {
	dev := "/dev/" + port
	return fmt.Sprintf(
		"for i in $(seq 1 %d); do [ -e %s ] && break; sleep %s; done; [ -e %s ] || { echo '%s did not appear after usbip attach' >&2; exit 1; }",
		deviceWaitTries, shQuote(dev), deviceWaitPeriod, shQuote(dev), dev,
	)
}

// boolWord renders a bool the way bossac 1.7.0's --force_usb_port expects it:
// the literal words true/false, not 1/0.
func boolWord(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

// splitHostPort accepts "host" or "host:port", defaulting the port. It does not
// handle bracketed IPv6 literals; USB/IP hosts are addressed by name or IPv4 in
// practice.
func splitHostPort(v, defPort string) (string, string) {
	v = strings.TrimSpace(v)
	if i := strings.LastIndex(v, ":"); i >= 0 {
		host, port := v[:i], v[i+1:]
		if host != "" && port != "" {
			return host, port
		}
	}
	return v, defPort
}

func shJoin(argv []string) string {
	quoted := make([]string, len(argv))
	for i, a := range argv {
		quoted[i] = shQuote(a)
	}
	return strings.Join(quoted, " ")
}

// shQuote single-quotes a value so it survives the extra `sh -c` layer the
// timeout wrapper introduces.
func shQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
