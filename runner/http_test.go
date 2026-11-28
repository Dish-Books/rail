package main

import (
	"bufio"
	"io"
	"net/http"
	"strings"
	"testing"
)

// claudeEnv starts a Claude process and returns the address and token the runner gave it.
func claudeEnv(t *testing.T, fc *fakeConn) (url, token, mcp string) {
	t.Helper()
	fc.send(msg{
		"t": "exec", "id": "agent-1", "ch": 1, "claude": true, "cwd": t.TempDir(),
		"argv": []string{"sh", "-c", `printf '%s\n%s\n%s\n' "$ANTHROPIC_BASE_URL" "$CLAUDE_CODE_OAUTH_TOKEN" "$RAIL_MCP_URL"`},
	})
	res := fc.collect(t, 1, collectOpts{})
	lines := strings.Split(strings.TrimSpace(string(res.out)), "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "http://127.0.0.1:") || !strings.HasPrefix(lines[1], "rail-sandbox-") {
		t.Fatalf("env %q", res.out)
	}
	if lines[2] != lines[0]+"/mcp" {
		t.Fatalf("RAIL_MCP_URL %q", lines[2])
	}
	return lines[0], lines[1], lines[2]
}

// request reads a request's open, body and eof as Rail would, acking the body.
func request(t *testing.T, fc *fakeConn) (open msg, body string) {
	t.Helper()
	open = fc.waitMsg(t, "open")
	ch := uint32(open.num("ch"))
	var b strings.Builder
	for {
		e := fc.next(t)
		if e.frame != nil && e.frame.ch == ch {
			b.Write(e.frame.data)
			fc.send(msg{"t": "ack", "ch": ch, "stream": 0, "offset": int(e.frame.off) + len(e.frame.data)})
			continue
		}
		if e.msg != nil && e.msg.str("t") == "eof" && uint32(e.msg.num("ch")) == ch {
			return open, b.String()
		}
	}
}

func TestClaudeRequestGoesOverTheSocketAndStreamsBack(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	url, token, _ := claudeEnv(t, fc)

	req, _ := http.NewRequest("POST", url+"/v1/messages?beta=true", strings.NewReader(`{"stream":true}`))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Anthropic-Beta", "oauth-2025-04-20")
	req.Header.Set("Cookie", "kept=here")
	got := make(chan *http.Response, 1)
	go func() {
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Errorf("request: %v", err)
			close(got)
			return
		}
		got <- resp
	}()

	open, body := request(t, fc)
	if open.str("kind") != "claude" || open.str("proc") != "agent-1" || open.str("method") != "POST" ||
		open.str("path") != "/v1/messages?beta=true" || body != `{"stream":true}` {
		t.Fatalf("open %v body %q", open, body)
	}
	headers, _ := open["headers"].(map[string]any)
	if headers["cookie"] != nil || headers["authorization"] == nil || headers["anthropic-beta"] == nil {
		t.Fatalf("headers %v", headers)
	}

	ch := uint32(open.num("ch"))
	fc.send(msg{"t": "head", "ch": ch, "status": 200, "headers": map[string][]string{"content-type": {"text/event-stream"}}})
	fc.sendFrame(ch, 0, 0, []byte("event: one\n\n"))
	resp := <-got
	if resp == nil {
		t.FailNow()
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("response %d %v", resp.StatusCode, resp.Header)
	}
	// The first part arrives before the rest is sent: the answer streams.
	br := bufio.NewReader(resp.Body)
	line, err := br.ReadString('\n')
	if err != nil || line != "event: one\n" {
		t.Fatalf("first part %q %v", line, err)
	}
	ack := fc.waitMsg(t, "ack")
	if uint32(ack.num("ch")) != ch || ack.num("offset") != 12 {
		t.Fatalf("ack %v", ack)
	}
	fc.sendFrame(ch, 0, 12, []byte("event: two\n\n"))
	fc.send(msg{"t": "close", "ch": ch})
	rest, _ := io.ReadAll(br)
	if string(rest) != "\nevent: two\n\n" {
		t.Fatalf("rest %q", rest)
	}
}

func TestOnlyAProcessGivenATokenReachesClaude(t *testing.T) {
	r := newFakeRail(t)
	td := startDaemon(t, r, "")
	fc := r.next(t)
	url, _, _ := claudeEnv(t, fc)

	for path, want := range map[string]int{"/v1/messages": 401, "/other": 404} {
		req, _ := http.NewRequest("POST", url+path, strings.NewReader("{}"))
		req.Header.Set("X-Api-Key", "rail-sandbox-guessed")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != want {
			t.Errorf("%s: %d, want %d", path, resp.StatusCode, want)
		}
	}

	// Once Rail settles the process, its token is worth nothing.
	fc.send(msg{"t": "done", "id": "agent-1"})
	waitFor(t, func() bool {
		td.mu.Lock()
		defer td.mu.Unlock()
		return len(td.tokens) == 0
	}, "the token to go")
}

func TestMCPRequestRailClosesUnansweredIsABadGateway(t *testing.T) {
	r := newFakeRail(t)
	startDaemon(t, r, "")
	fc := r.next(t)
	_, _, mcp := claudeEnv(t, fc)

	got := make(chan *http.Response, 1)
	go func() {
		resp, err := http.Post(mcp, "application/json", strings.NewReader(`{"jsonrpc":"2.0"}`))
		if err != nil {
			t.Errorf("request: %v", err)
			close(got)
			return
		}
		got <- resp
	}()
	open, body := request(t, fc)
	if open.str("kind") != "mcp" || open["proc"] != nil || body != `{"jsonrpc":"2.0"}` {
		t.Fatalf("open %v body %q", open, body)
	}
	fc.send(msg{"t": "close", "ch": open.num("ch"), "error": "refused"})
	resp := <-got
	if resp == nil {
		t.FailNow()
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 502 || !strings.Contains(string(b), "refused") {
		t.Fatalf("%d %s", resp.StatusCode, b)
	}
}

func TestARequestWithoutRailIsABadGateway(t *testing.T) {
	r := newFakeRail(t)
	td := startDaemon(t, r, "")
	fc := r.next(t)
	_, _, mcp := claudeEnv(t, fc)

	got := make(chan *http.Response, 1)
	go func() {
		resp, err := http.Post(mcp, "application/json", strings.NewReader("{}"))
		if err != nil {
			t.Errorf("request: %v", err)
			close(got)
			return
		}
		got <- resp
	}()
	request(t, fc)
	fc.drop()
	resp := <-got
	if resp == nil {
		t.FailNow()
	}
	resp.Body.Close()
	if resp.StatusCode != 502 {
		t.Fatalf("%d", resp.StatusCode)
	}
	td.stop()
}
