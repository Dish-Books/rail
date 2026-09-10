defmodule Rail.Runs.ArgvBuilder do
  @moduledoc """
  Builds CLI argument vectors (argv) for Claude and Agy agent runners.

  Enforces exact flag order, read-only mode permissions, and resume flags per spec 03 §2.
  """

  alias Rail.Backends.Probes

  @default_print_timeout "6h"
  @default_effort "high"

  @doc """
  Returns the CLI binary path for the given backend.
  """
  def executable_path(backend, opts \\ [])

  def executable_path(backend, opts) when is_list(opts) do
    executable_path(backend, Map.new(opts))
  end

  def executable_path(backend, opts) when is_map(opts) do
    if claude?(backend) do
      opts[:claude_path] || Probes.configured_path(:claude)
    else
      opts[:agy_path] || Probes.configured_path(:agy)
    end
  end

  @doc """
  Builds the command-line arguments list for the specified backend.

  Options:
  - `:backend` or `:cli_backend`: `:claude` | `:agy` (or string, case-insensitive)
  - `:prompt`: string prompt
  - `:model`: model name string
  - `:reasoning_effort` or `:effort`: `"high" | "medium" | "low"` (default `"high"`)
  - `:read_only`: boolean (default `false`)
  - `:system_prompt`: string (Claude only, included when non-empty)
  - `:conversation_id`, `:conversation`, or `:resume`: session id for resumption
  - `:print_timeout`: string timeout for Agy (default `"6h"`)
  - `:work_dir` or `:working_directory`: directory for `--add-dir` (Agy only)
  - `:log_file`, `:log_path`, or `:agy_log_path`: path for `--log-file` (Agy only)
  """
  def build_argv(opts) when is_list(opts) do
    build_argv(Map.new(opts))
  end

  def build_argv(opts) when is_map(opts) do
    backend = opts[:backend] || opts[:cli_backend]

    if claude?(backend) do
      build_claude_argv(opts)
    else
      build_agy_argv(opts)
    end
  end

  defp build_claude_argv(opts) do
    prompt = opts[:prompt] || ""
    model = opts[:model] || ""
    effort = opts[:reasoning_effort] || opts[:effort] || @default_effort
    read_only = Map.get(opts, :read_only, false)
    system_prompt = opts[:system_prompt]
    conversation_id = opts[:conversation_id] || opts[:resume]

    permission_flags =
      if read_only do
        ["--tools", "", "--strict-mcp-config"]
      else
        ["--dangerously-skip-permissions"]
      end

    system_prompt_flags =
      if is_binary(system_prompt) and String.trim(system_prompt) != "" do
        ["--system-prompt", system_prompt]
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
      ["--output-format", "stream-json", "--verbose"] ++
      system_prompt_flags ++
      resume_flags
  end

  defp build_agy_argv(opts) do
    prompt = opts[:prompt] || ""
    model = opts[:model] || ""
    effort = opts[:reasoning_effort] || opts[:effort] || @default_effort
    read_only = Map.get(opts, :read_only, false)
    mode = if read_only, do: "plan", else: "accept-edits"
    print_timeout = opts[:print_timeout] || @default_print_timeout
    work_dir = opts[:work_dir] || opts[:working_directory]
    log_file = opts[:log_file] || opts[:log_path] || opts[:agy_log_path]
    conversation_id = opts[:conversation_id] || opts[:conversation] || opts[:resume]

    ["-p", prompt, "--model", model, "--effort", effort] ++
      agy_permission_flags(read_only) ++
      ["--mode", mode, "--output-format", "stream-json", "--print-timeout", print_timeout] ++
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

  defp claude?(backend) when is_atom(backend), do: backend == :claude
  defp claude?(backend) when is_binary(backend), do: String.downcase(backend) == "claude"
  defp claude?(_other_backend), do: false
end
