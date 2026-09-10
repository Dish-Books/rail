defmodule Rail.Backends.ModelRegistry do
  @moduledoc """
  Discovers, normalizes, and caches available models across CLI backends.
  """

  use Nebulex.Caching, cache: Rail.Cache

  alias Rail.Backends.ModelOption
  alias Rail.Backends.ProcessRunner
  alias Rail.Cache
  alias Rail.ToolEnv

  @ttl to_timeout(hour: 12)

  @doc """
  Fetches available models for a backend, querying the CLI tool or grepping binaries.
  Results are cached unless `:force_refresh` is true.
  """
  def fetch_available_models(backend, opts \\ []) do
    key = normalize_backend(backend)

    if Keyword.get(opts, :force_refresh, false) do
      refresh_models(key, opts)
    else
      cached_models(key, opts)
    end
  end

  @doc """
  Returns hardcoded default fallback models for a backend.
  """
  def default_models(backend) do
    case normalize_backend(backend) do
      "agy" ->
        [
          %ModelOption{id: "gemini-3.8-flash-high", display_name: "Gemini 3.8 Flash (High) (gemini-3.8-flash-high)"},
          %ModelOption{id: "gemini-3.1-pro-high", display_name: "Gemini 3.1 Pro (High) (gemini-3.1-pro-high)"},
          %ModelOption{id: "claude-sonnet-4-6", display_name: "Claude Sonnet 4.6 (Thinking) (claude-sonnet-4-6)"},
          %ModelOption{id: "gemini-2.5-pro", display_name: "Gemini 2.5 Pro (gemini-2.5-pro)"},
          %ModelOption{id: "gemini-2.5-flash", display_name: "Gemini 2.5 Flash (gemini-2.5-flash)"}
        ]

      _claude ->
        [
          %ModelOption{id: "claude-fable-5-1", display_name: "claude-fable-5-1"},
          %ModelOption{id: "claude-opus-5", display_name: "claude-opus-5"},
          %ModelOption{id: "claude-sonnet-5", display_name: "claude-sonnet-5"},
          %ModelOption{id: "claude-haiku-4-5", display_name: "claude-haiku-4-5"},
          %ModelOption{id: "opus", display_name: "opus (latest Opus alias)"},
          %ModelOption{id: "sonnet", display_name: "sonnet (latest Sonnet alias)"},
          %ModelOption{id: "haiku", display_name: "haiku (latest Haiku alias)"}
        ]
    end
  end

  @doc """
  Retrieves cached models for a backend key.
  """
  def get_cached_models(backend) do
    Cache.get!(cache_key(backend), [])
  end

  @doc """
  Stores cached models for a backend key.
  """
  def put_cached_models(backend, models) when is_list(models) do
    Cache.put!(cache_key(backend), models, ttl: @ttl)
  end

  @doc """
  Clears cached models for a specific backend, or flushes the whole cache when
  no backend is given.
  """
  def clear_cache(backend \\ nil)

  def clear_cache(nil) do
    _deleted = Cache.delete_all!()
    :ok
  end

  def clear_cache(backend) do
    Cache.delete!(cache_key(backend))
  end

  @decorate cacheable(key: cache_key(backend), match: &(&1 != []), opts: [ttl: @ttl])
  defp cached_models(backend, opts), do: discover_models(backend, opts)

  @decorate cache_put(key: cache_key(backend), match: &(&1 != []), opts: [ttl: @ttl])
  defp refresh_models(backend, opts), do: discover_models(backend, opts)

  defp discover_models("agy", opts), do: fetch_agy_models(opts)
  defp discover_models(_claude, opts), do: fetch_claude_models(opts)

  defp cache_key(backend), do: {__MODULE__, normalize_backend(backend)}

  defp fetch_agy_models(opts) do
    executable =
      Keyword.get(opts, :executable_path) ||
        Keyword.get(opts, :executable) ||
        ToolEnv.find_executable("agy") ||
        "agy"

    runner = Keyword.get(opts, :runner, &ProcessRunner.run/3)

    discovered =
      try do
        case run_command(runner, executable, ["models"], 4_000) do
          {:ok, stdout, 0} ->
            parse_agy_models_output(stdout)

          _other ->
            []
        end
      rescue
        _error -> []
      end

    if discovered == [] do
      default_models("agy")
    else
      discovered
    end
  end

  defp parse_agy_models_output(stdout) when is_binary(stdout) do
    lines = String.split(stdout, ~r/\r?\n/)

    {reversed, _seen} =
      Enum.reduce(lines, {[], MapSet.new()}, fn line, {list, seen} ->
        trimmed = String.trim(line)

        if trimmed == "" or String.starts_with?(String.downcase(trimmed), "fetching") do
          {list, seen}
        else
          parts = Regex.split(~r/\t+|\s{2,}/, trimmed, parts: 2)
          id = parts |> Enum.at(0, "") |> String.trim()

          name =
            case Enum.at(parts, 1) do
              str when is_binary(str) and str != "" -> String.trim(str)
              _other -> id
            end

          if id != "" and not MapSet.member?(seen, id) do
            display = "#{name} (#{id})"
            model = %ModelOption{id: id, display_name: display}
            {[model | list], MapSet.put(seen, id)}
          else
            {list, seen}
          end
        end
      end)

    Enum.reverse(reversed)
  end

  defp fetch_claude_models(opts) do
    executable =
      Keyword.get(opts, :executable_path) ||
        Keyword.get(opts, :executable) ||
        ToolEnv.find_executable("claude") ||
        "claude"

    runner = Keyword.get(opts, :runner, &ProcessRunner.run/3)

    seeds = [
      %ModelOption{id: "opus", display_name: "opus (latest Opus alias)"},
      %ModelOption{id: "sonnet", display_name: "sonnet (latest Sonnet alias)"},
      %ModelOption{id: "haiku", display_name: "haiku (latest Haiku alias)"}
    ]

    resolved_path = resolve_executable_path(executable)

    grep_result =
      try do
        grep_binary = ToolEnv.find_executable("grep") || "grep"

        args = [
          "-oaE",
          "claude-(3|4|5|opus|sonnet|haiku|fable|mythos)-[0-9a-z-]+",
          resolved_path
        ]

        case run_command(runner, grep_binary, args, 4_000) do
          {:ok, stdout, 0} ->
            parse_claude_grep_output(stdout)

          _other ->
            []
        end
      rescue
        _error -> []
      end

    grep_options =
      grep_result
      |> Enum.reject(fn id -> Enum.any?(seeds, &(&1.id == id)) end)
      |> Enum.map(&%ModelOption{id: &1, display_name: &1})

    combined = seeds ++ grep_options

    if length(combined) <= 3 do
      append_missing_defaults(combined, default_models("claude"))
    else
      combined
    end
  end

  defp parse_claude_grep_output(stdout) when is_binary(stdout) do
    stdout
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn id ->
      id == "" or String.contains?(id, "latest") or Regex.match?(~r/-\d{8}/, id)
    end)
    |> Enum.uniq()
    |> Enum.sort(&(&1 >= &2))
  end

  defp append_missing_defaults(existing, defaults) do
    missing =
      Enum.reject(defaults, fn def_model ->
        Enum.any?(existing, &(&1.id == def_model.id))
      end)

    existing ++ missing
  end

  defp resolve_executable_path(executable) do
    if File.exists?(executable) do
      case File.read_link(executable) do
        {:ok, target} ->
          Path.expand(target, Path.dirname(executable))

        _other ->
          executable
      end
    else
      executable
    end
  end

  defp run_command(runner, executable, args, timeout) do
    executable |> runner.(args, timeout: timeout) |> ProcessRunner.normalize_result()
  end

  defp normalize_backend(backend) when is_atom(backend), do: backend |> Atom.to_string() |> String.downcase()
  defp normalize_backend(backend) when is_binary(backend), do: String.downcase(backend)
  defp normalize_backend(_other), do: "claude"
end
