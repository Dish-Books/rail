package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func socketPath() string {
	return filepath.Join(stateDir(), "runner.sock")
}

func dialDaemon(req localReq) (*net.UnixConn, error) {
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socketPath(), Net: "unix"})
	if err != nil {
		return nil, fmt.Errorf("reaching rail-runner: %w", err)
	}
	b, _ := json.Marshal(req)
	if _, err := c.Write(append(b, '\n')); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

// remoteHelperMain is git-remote-rail, git's remote helper for rail:: URLs
// (gitremote-helpers(7)). It offers only connect, and hands the connection to
// the daemon, which carries it to Rail on a git channel.
func remoteHelperMain(args []string) int {
	in := bufio.NewReader(os.Stdin)
	for {
		line, err := in.ReadString('\n')
		line = strings.TrimRight(line, "\n")
		if err != nil && line == "" {
			return 0
		}
		switch {
		case line == "":
			return 0
		case line == "capabilities":
			os.Stdout.WriteString("connect\n\n")
		case strings.HasPrefix(line, "option "):
			os.Stdout.WriteString("unsupported\n")
		case strings.HasPrefix(line, "connect "):
			return bridgeGit(in, strings.TrimPrefix(line, "connect "))
		default:
			fmt.Fprintf(os.Stderr, "git-remote-rail: unsupported command %q\n", line)
			return 1
		}
	}
}

func bridgeGit(in *bufio.Reader, service string) int {
	c, err := dialDaemon(localReq{Kind: "git", Service: service})
	if err != nil {
		fmt.Fprintln(os.Stderr, "git-remote-rail:", err)
		return 1
	}
	defer c.Close()
	// Connected: git now talks to the service through us.
	if _, err := os.Stdout.WriteString("\n"); err != nil {
		return 1
	}
	go func() {
		_, _ = io.Copy(c, in)
		_ = c.CloseWrite()
	}()
	if _, err := io.Copy(os.Stdout, c); err != nil {
		fmt.Fprintln(os.Stderr, "git-remote-rail:", err)
		return 1
	}
	return 0
}

// signMain is rail-sign, git's gpg.ssh.program. Git signs with
// "rail-sign -Y sign -n git -f <key> [-U] <file>"; Rail does the signing and
// rail-sign writes <file>.sig. Every other use (verifying, finding
// principals) goes to the real ssh-keygen.
func signMain(args []string) int {
	op := ""
	for i := 0; i+1 < len(args); i++ {
		if args[i] == "-Y" {
			op = args[i+1]
			break
		}
	}
	if op != "sign" {
		return execSSHKeygen(args)
	}
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "rail-sign: no file to sign")
		return 1
	}
	file := args[len(args)-1]
	data, err := os.ReadFile(file)
	if err != nil {
		fmt.Fprintln(os.Stderr, "rail-sign:", err)
		return 1
	}
	c, err := dialDaemon(localReq{Kind: "sign", Payload: base64.StdEncoding.EncodeToString(data)})
	if err != nil {
		fmt.Fprintln(os.Stderr, "rail-sign:", err)
		return 1
	}
	defer c.Close()
	line, err := bufio.NewReader(c).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		fmt.Fprintln(os.Stderr, "rail-sign: no answer from rail-runner:", err)
		return 1
	}
	var reply signReply
	if err := json.Unmarshal(line, &reply); err != nil {
		fmt.Fprintln(os.Stderr, "rail-sign: bad answer from rail-runner:", err)
		return 1
	}
	if reply.Error != "" {
		fmt.Fprintln(os.Stderr, "rail-sign:", reply.Error)
		return 1
	}
	if reply.Signature == "" {
		fmt.Fprintln(os.Stderr, "rail-sign: rail-runner sent no signature")
		return 1
	}
	sig := reply.Signature
	if !strings.HasSuffix(sig, "\n") {
		sig += "\n"
	}
	if err := os.WriteFile(file+".sig", []byte(sig), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "rail-sign:", err)
		return 1
	}
	return 0
}

func execSSHKeygen(args []string) int {
	self, _ := os.Executable()
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		p := filepath.Join(dir, "ssh-keygen")
		st, err := os.Stat(p)
		if err != nil || !st.Mode().IsRegular() || st.Mode()&0o111 == 0 {
			continue
		}
		if resolved, err := filepath.EvalSymlinks(p); err == nil && resolved == self {
			continue
		}
		err = syscall.Exec(p, append([]string{"ssh-keygen"}, args...), os.Environ())
		fmt.Fprintln(os.Stderr, "rail-sign: running ssh-keygen:", err)
		return 1
	}
	fmt.Fprintln(os.Stderr, "rail-sign:", errors.New("ssh-keygen not found on PATH"))
	return 1
}
