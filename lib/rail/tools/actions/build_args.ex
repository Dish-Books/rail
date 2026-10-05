defmodule Rail.Tools.Actions.BuildArgs do
  @moduledoc false

  @default_effort "high"

  @doc """
  Builds the command-line arguments list for a Claude Code run.

  Enforces exact flag order, read-only mode permissions, and resume flags per spec 03 §2.

  Options:
  - `:prompt`: string prompt
  - `:model`: model name string
  - `:reasoning_effort` or `:effort`: `"high" | "medium" | "low"` (default `"high"`)
  - `:read_only`: boolean (default `false`)
  - `:system_prompt`: string (included when non-empty) — appended to
    Claude Code's own system prompt rather than replacing it, which is what teaches
    the agent its tools (deferred MCP tools included)
  - `:conversation_id` or `:resume`: session id for resumption
  - `:agents`: subagents as `%{name:, description:, prompt:, model:}` maps, passed as one `--agents` flag
  """
  def build_args(opts) when is_list(opts) do
    build_args(Map.new(opts))
  end

  def build_args(opts) when is_map(opts) do
    prompt = opts[:prompt] || ""
    model = opts[:model] || ""
    effort = opts[:reasoning_effort] || opts[:effort] || @default_effort
    read_only = Map.get(opts, :read_only, false)
    system_prompt = opts[:system_prompt]
    conversation_id = opts[:conversation_id] || opts[:resume]

    permission_flags =
      if read_only do
        ["--tools", ""]
      else
        ["--dangerously-skip-permissions"]
      end

    system_prompt_flags =
      if is_binary(system_prompt) and String.trim(system_prompt) != "" do
        ["--append-system-prompt", system_prompt]
      else
        []
      end

    resume_flags =
      if is_binary(conversation_id) and String.trim(conversation_id) != "" do
        ["--resume", conversation_id]
      else
        []
      end

    ["-p", prompt, "--model", model, "--effort", effort] ++
      permission_flags ++
      claude_mcp_flags() ++
      ["--output-format", "stream-json", "--verbose"] ++
      system_prompt_flags ++
      agents_flags(opts[:agents]) ++
      resume_flags
  end

  # No tool list, so each subagent inherits every tool the run has, Rail's included.
  defp agents_flags([_first | _rest] = agents) do
    definitions =
      Map.new(agents, fn agent ->
        {agent.name, %{"description" => agent.description, "prompt" => agent.prompt, "model" => agent.model}}
      end)

    ["--agents", Jason.encode!(definitions)]
  end

  defp agents_flags(_none), do: []

  # Every run is pointed at Rail and given a token for it. What it may actually
  # call is decided on Rail's side, per run, so there is nothing for the spawn to
  # work out and no way for the flag and the token to disagree - a run told to
  # connect without one gets a 401 on its first call.
  #
  # The token stays out of argv, where `ps` would show it: Claude expands
  # `${RAIL_MCP_TOKEN}` from its own environment when it reads the config.
  # `--strict-mcp-config` keeps the user's own MCP servers out of the run.
  # Agents share Rail's host, so they dial its port: the public URL sits behind Cloudflare Access.
  defp claude_mcp_flags do
    config = %{
      "mcpServers" => %{
        "rail" => %{
          "type" => "http",
          "url" => "http://localhost:#{RailWeb.Endpoint.config(:http)[:port]}/mcp",
          "headers" => %{"Authorization" => "Bearer ${RAIL_MCP_TOKEN}"}
        }
      }
    }

    ["--mcp-config", Jason.encode!(config), "--strict-mcp-config", "--allowedTools", "mcp__rail"]
  end
end
