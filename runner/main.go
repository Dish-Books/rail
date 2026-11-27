// Command rail-runner is the process inside every Rail sandbox. It holds one
// WebSocket to Rail (docs/sandbox-socket.md) and runs commands and git for it.
//
// One binary answers to several names, chosen by the basename of argv[0]:
//
//   - rail-runner: the daemon.
//   - git-remote-rail: git's remote helper for rail:: URLs.
//   - rail-sign: git's gpg.ssh.program, which has Rail sign commits.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

const (
	remoteHelperName = "git-remote-rail"
	signName         = "rail-sign"
)

func main() {
	os.Exit(run(os.Args))
}

func run(args []string) int {
	switch filepath.Base(args[0]) {
	case remoteHelperName:
		return remoteHelperMain(args[1:])
	case signName:
		return signMain(args[1:])
	}

	if len(args) > 1 {
		switch args[1] {
		case "version", "--version", "-version":
			fmt.Println(version)
			return 0
		case writeFilesCmd:
			return writeFilesMain()
		case readFileCmd:
			if len(args) != 3 {
				fmt.Fprintln(os.Stderr, "usage: rail-runner "+readFileCmd+" <path>")
				return 1
			}
			return readFileMain(args[2])
		}
	}

	if shouldRunInit() {
		return initMain(args)
	}
	cfg, err := configFromEnv()
	if err != nil {
		fmt.Fprintln(os.Stderr, "rail-runner:", err)
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if err := newDaemon(cfg).Run(ctx); err != nil && ctx.Err() == nil {
		fmt.Fprintln(os.Stderr, "rail-runner:", err)
		return 1
	}
	return 0
}
