defmodule Rail.Tools.Actions.BuildArgsTest do
  use Rail.DataCase, async: true

  alias Rail.Tools

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
      args = Tools.build_args([prompt: "Go", model: "m"] ++ opts)

      assert ["--mcp-config", rail_mcp_config, "--strict-mcp-config", "--allowedTools", "mcp__rail"] ==
               Enum.slice(args, Enum.find_index(args, &(&1 == "--mcp-config")), 5)

      refute Enum.any?(args, &(&1 =~ "RAIL_MCP_TOKEN=")), "the token must never reach argv"
    end
  end

  test "appends the role prompt to Claude's own and attaches --resume when present" do
    opts = [
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
      prompt: "Run",
      model: "claude-opus-5-5",
      system_prompt: "   ",
      conversation_id: nil
    ]

    args = Tools.build_args(opts)

    refute "--append-system-prompt" in args
    refute "--resume" in args
  end

  test "falls back to an empty prompt and model at high effort" do
    assert ["-p", "", "--model", "", "--effort", "high", "--dangerously-skip-permissions" | _rest] =
             Tools.build_args(%{})
  end

  test "an agents list is one --agents flag, before any resume, and carries no tool list" do
    agents = [
      %{name: "product", description: "Writes the ticket", prompt: "You are product.", model: "claude-opus-5-5"},
      %{name: "architect", description: "Writes the plan", prompt: "You are architect.", model: "claude-sonnet-5-5"}
    ]

    args = Tools.build_args(prompt: "Plan it", agents: agents, conversation_id: "c-1")

    assert ["--agents", json, "--resume", "c-1"] = Enum.take(args, -4)

    assert %{
             "product" => %{
               "description" => "Writes the ticket",
               "prompt" => "You are product.",
               "model" => "claude-opus-5-5"
             },
             "architect" => %{
               "description" => "Writes the plan",
               "prompt" => "You are architect.",
               "model" => "claude-sonnet-5-5"
             }
           } = Jason.decode!(json)

    refute json =~ "tools"
  end

  test "no agents adds no flag" do
    refute "--agents" in Tools.build_args(prompt: "Plan it", agents: [])
  end
end
