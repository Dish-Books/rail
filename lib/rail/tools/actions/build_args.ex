defmodule Rail.Tools.Actions.BuildArgs do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @default_effort "high"

  @doc """
  Builds the command-line arguments list for the specified backend.

  Enforces exact flag order, read-only mode permissions, and resume flags per spec 03 §2.

  Options:
  - `:backend`: the `%Backend{}` the runs on
  - `:prompt`: string prompt
  - `:model`: model name string
  - `:reasoning_effort` or `:effort`: `"high" | "medium" | "low"` (default `"high"`)
  - `:read_only`: boolean (default `false`)
  - `:system_prompt`: string (Claude only, included when non-empty) — appended to
    Claude Code's own system prompt rather than replacing it, which is what teaches
    the agent its tools (deferred MCP tools included)
  - `:conversation_id`, `:conversation`, or `:resume`: session id for resumption
  - `:work_dir` or `:working_directory`: directory for `--add-dir` (Agy only)
  - `:log_file`, `:log_path`, or `:agy_log_path`: path for `--log-file` (Agy only)
  """
  def build_args(opts) when is_list(opts) do
    build_args(Map.new(opts))
  end

  def build_args(opts) when is_map(opts) do
    if claude?(opts[:backend]) do
      build_claude_args(opts)
    else
      build_agy_args(opts)
    end
  end

  defp build_claude_args(opts) do
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
      resume_flags
  end

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

  defp build_agy_args(opts) do
    prompt = opts[:prompt] || ""
    model = opts[:model] || ""
    effort = opts[:reasoning_effort] || opts[:effort] || @default_effort
    read_only = Map.get(opts, :read_only, false)
    mode = if read_only, do: "plan", else: "accept-edits"
    work_dir = opts[:work_dir] || opts[:working_directory]
    log_file = opts[:log_file] || opts[:log_path] || opts[:agy_log_path]
    conversation_id = opts[:conversation_id] || opts[:conversation] || opts[:resume]

    ["-p", prompt, "--model", model, "--effort", effort] ++
      agy_permission_flags(read_only) ++
      ["--mode", mode, "--output-format", "stream-json"] ++
      agy_add_dir_flags(work_dir) ++
      agy_log_file_flags(log_file) ++
      agy_conversation_flags(conversation_id)
  end

  defp agy_permission_flags(true), do: []
  defp agy_permission_flags(false), do: ["--dangerously-skip-permissions"]

  defp agy_add_dir_flags(work_dir) when is_binary(work_dir) do
    if String.trim(work_dir) == "" do
      []
    else
      ["--add-dir", work_dir]
    end
  end

  defp agy_add_dir_flags(_other), do: []

  defp agy_log_file_flags(log_file) when is_binary(log_file) do
    if String.trim(log_file) == "" do
      []
    else
      ["--log-file", log_file]
    end
  end

  defp agy_log_file_flags(_other), do: []

  defp agy_conversation_flags(conversation_id) when is_binary(conversation_id) do
    if String.trim(conversation_id) == "" do
      []
    else
      ["--conversation", conversation_id]
    end
  end

  defp agy_conversation_flags(_other), do: []

  defp claude?(%Backend{name: name}), do: name == :claude
  defp claude?(_other_backend), do: false
end
