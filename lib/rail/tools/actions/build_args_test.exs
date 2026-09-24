defmodule Rail.Tools.Actions.BuildArgsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  setup do
    config =
      Jason.encode!(%{
        "mcpServers" => %{
          "rail" => %{
            "type" => "http",
            "url" => "http://localhost:#{RailWeb.Endpoint.config(:http)[:port]}/mcp",
            "headers" => %{"Authorization" => "Bearer ${RAIL_MCP_TOKEN}"}
          }
        }
      })

    %{rail_mcp_config: config}
  end

  test "builds standard Claude args in exact flag order", %{rail_mcp_config: rail_mcp_config} do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Fix the bug",
      model: "claude-opus-5-5-20250219",
      effort: "high"
    ]

    args = Tools.build_args(opts)

    assert args == [
             "-p",
             "Fix the bug",
             "--model",
             "claude-opus-5-5-20250219",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--mcp-config",
             rail_mcp_config,
             "--strict-mcp-config",
             "--allowedTools",
             "mcp__rail",
             "--output-format",
             "stream-json",
             "--verbose"
           ]
  end

  test "builds read-only Claude args with tools empty string", %{rail_mcp_config: rail_mcp_config} do
    opts = %{
      backend: %Backend{name: :claude},
      prompt: "Review the code",
      model: "claude-3-5-sonnet-20241022",
      effort: "medium",
      read_only: true
    }

    args = Tools.build_args(opts)

    assert args == [
             "-p",
             "Review the code",
             "--model",
             "claude-3-5-sonnet-20241022",
             "--effort",
             "medium",
             "--tools",
             "",
             "--mcp-config",
             rail_mcp_config,
             "--strict-mcp-config",
             "--allowedTools",
             "mcp__rail",
             "--output-format",
             "stream-json",
             "--verbose"
           ]

    refute "--dangerously-skip-permissions" in args
  end

  # Every run is pointed at Rail and given a token for it; what it may call is
  # decided on Rail's side. So there is no flag to get wrong, and no way for a
  # run to be told to connect without the token to do it.
  test "points every Claude run at Rail's MCP proxy, with the token left to its environment", %{
    rail_mcp_config: rail_mcp_config
  } do
    for opts <- [[], [read_only: true], [mcp: false]] do
      args = Tools.build_args([backend: %Backend{name: :claude}, prompt: "Go", model: "m"] ++ opts)

      assert ["--mcp-config", rail_mcp_config, "--strict-mcp-config", "--allowedTools", "mcp__rail"] ==
               Enum.slice(args, Enum.find_index(args, &(&1 == "--mcp-config")), 5)

      refute Enum.any?(args, &(&1 =~ "RAIL_MCP_TOKEN=")), "the token must never reach argv"
    end
  end

  test "appends the role prompt to Claude's own and attaches --resume when present" do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Do work",
      model: "claude-opus-5-5",
      system_prompt: "Act as QA engineer.",
      conversation_id: "sess-abc-123"
    ]

    args = Tools.build_args(opts)

    refute "--system-prompt" in args

    assert Enum.take(args, -4) == [
             "--append-system-prompt",
             "Act as QA engineer.",
             "--resume",
             "sess-abc-123"
           ]
  end

  test "omits empty system-prompt and resume from Claude args" do
    opts = [
      backend: %Backend{name: :claude},
      prompt: "Run",
      model: "claude-opus-5-5",
      system_prompt: "   ",
      conversation_id: nil
    ]

    args = Tools.build_args(opts)

    refute "--append-system-prompt" in args
    refute "--resume" in args
  end

  test "builds standard Agy args in exact flag order" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Refactor auth",
      model: "gemini-2.5-pro",
      effort: "high",
      work_dir: "/var/rail/worktrees/task-1",
      log_file: "/tmp/rail/agy-logs/task-1.log"
    ]

    args = Tools.build_args(opts)

    assert args == [
             "-p",
             "Refactor auth",
             "--model",
             "gemini-2.5-pro",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--mode",
             "accept-edits",
             "--output-format",
             "stream-json",
             "--add-dir",
             "/var/rail/worktrees/task-1",
             "--log-file",
             "/tmp/rail/agy-logs/task-1.log"
           ]
  end

  test "builds read-only Agy args with mode plan and no skip-permissions" do
    opts = %{
      backend: %Backend{name: :agy},
      prompt: "Plan the feature",
      model: "gemini-2.5-flash",
      reasoning_effort: "low",
      read_only: true
    }

    args = Tools.build_args(opts)

    assert args == [
             "-p",
             "Plan the feature",
             "--model",
             "gemini-2.5-flash",
             "--effort",
             "low",
             "--mode",
             "plan",
             "--output-format",
             "stream-json"
           ]

    refute "--dangerously-skip-permissions" in args
    refute "--add-dir" in args
    refute "--log-file" in args
  end

  test "attaches --conversation for Agy resume turn" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Continue",
      model: "gemini-2.5-pro",
      conversation_id: "conv-xyz-789"
    ]

    args = Tools.build_args(opts)

    assert Enum.take(args, -2) == ["--conversation", "conv-xyz-789"]
    refute "--resume" in args
    refute "--append-system-prompt" in args
    refute "--verbose" in args
  end

  test "treats non-claude backend as Agy" do
    opts = [
      backend: "unknown-engine",
      prompt: "Fallback run",
      model: "default-model"
    ]

    args = Tools.build_args(opts)

    assert "--mode" in args
    refute "--print-timeout" in args

    nil_args = Tools.build_args(backend: nil, prompt: "Nil engine")
    assert "--mode" in nil_args

    int_args = Tools.build_args(backend: 123, prompt: "Int engine")
    assert "--mode" in int_args
  end

  test "ignores whitespace in agy add_dir, log_file, and conversation" do
    opts = [
      backend: %Backend{name: :agy},
      prompt: "Terse",
      model: "gemini",
      work_dir: "   ",
      log_file: "   ",
      conversation_id: "   "
    ]

    args = Tools.build_args(opts)
    refute "--add-dir" in args
    refute "--log-file" in args
    refute "--conversation" in args
  end
end
