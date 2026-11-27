package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// When rail-runner is a container's entrypoint it is PID 1, which inherits
// every orphaned process (an agent's backgrounded server, say) and must reap
// them, or they stay zombies. The daemon can't reap with wait4(-1) without
// stealing its own commands' exit statuses from os/exec, so PID 1 runs as a
// minimal init instead: it starts the daemon as its child, forwards signals
// to it, reaps everything, and restarts the daemon if it dies after running
// a while (the commands keep running, and the new daemon takes them back from
// procs/).
const childEnv = "RAIL_RUNNER_CHILD"

func shouldRunInit() bool {
	return os.Getpid() == 1 && os.Getenv(childEnv) == ""
}

func initMain(args []string) int {
	exe, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "rail-runner init:", err)
		return 1
	}
	sigs := make(chan os.Signal, 16)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP, syscall.SIGQUIT, syscall.SIGUSR1, syscall.SIGUSR2)

	var mu sync.Mutex
	daemonPID := 0
	stopping := false
	var started time.Time

	start := func() error {
		cmd := exec.Command(exe, args[1:]...)
		cmd.Args[0] = args[0]
		cmd.Env = append(os.Environ(), childEnv+"=1")
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err := cmd.Start(); err != nil {
			return err
		}
		mu.Lock()
		daemonPID = cmd.Process.Pid
		mu.Unlock()
		started = time.Now()
		return nil
	}
	if err := start(); err != nil {
		fmt.Fprintln(os.Stderr, "rail-runner init:", err)
		return 1
	}

	go func() {
		for s := range sigs {
			mu.Lock()
			if s == syscall.SIGTERM || s == syscall.SIGINT {
				stopping = true
			}
			pid := daemonPID
			mu.Unlock()
			if pid > 0 {
				_ = syscall.Kill(pid, s.(syscall.Signal))
			}
		}
	}()

	for {
		var ws syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &ws, 0, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			// No children at all: nothing left to look after.
			return 1
		}
		mu.Lock()
		isDaemon, stop := pid == daemonPID, stopping
		mu.Unlock()
		if !isDaemon {
			continue
		}
		// Stopping, or failing at once (bad configuration): give up.
		if stop || time.Since(started) < 10*time.Second {
			if ws.Signaled() {
				return 128 + int(ws.Signal())
			}
			return ws.ExitStatus()
		}
		fmt.Fprintf(os.Stderr, "rail-runner init: daemon exited (%v); restarting\n", ws)
		time.Sleep(time.Second)
		if err := start(); err != nil {
			fmt.Fprintln(os.Stderr, "rail-runner init:", err)
			return 1
		}
	}
}
