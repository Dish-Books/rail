defmodule Rail.ToolEnv do
  @moduledoc """
  Resolves the login shell's PATH and provides environment and process execution
  with complete PATH parity.
  """

  @path_term {__MODULE__, :path}
  @cache_term {__MODULE__, :cache}

  @fallback_dirs [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
  ]

  @doc """
  Initializes the ToolEnv PATH by probing the login shell once.
  Idempotent and never throws.
  """
  def init do
    case :persistent_term.get(@path_term, nil) do
      path when is_binary(path) ->
        :ok

      nil ->
        shell_path = login_shell_path()
        merged = calculate_path(shell_path)
        :persistent_term.put(@path_term, merged)
        :persistent_term.put(@cache_term, %{})
        :ok
    end
  end

  @doc """
  Alias for `init/0`.
  """
  def initialize, do: init()

  @doc """
  Returns the merged PATH, computing it lazily if `init/0` never ran.
  """
  def path do
    case :persistent_term.get(@path_term, nil) do
      path when is_binary(path) ->
        path

      nil ->
        merged = calculate_path(nil)
        :persistent_term.put(@path_term, merged)
        merged
    end
  end

  @doc """
  Overrides the PATH for testing and clears the resolution cache.
  """
  def debug_set_path(new_path) do
    :persistent_term.put(@path_term, new_path)
    :persistent_term.put(@cache_term, %{})
    :ok
  end

  @doc """
  Resets the stored PATH and cache.
  """
  def reset do
    :persistent_term.erase(@path_term)
    :persistent_term.put(@cache_term, %{})
    :ok
  end

  @doc """
  Resolves an executable to its absolute path on PATH.
  Falls back to the bare name if not found.
  """
  def resolve(executable) when is_binary(executable) do
    if String.contains?(executable, "/") or windows?() do
      executable
    else
      cache = :persistent_term.get(@cache_term, %{})

      case Map.fetch(cache, executable) do
        {:ok, resolved} ->
          resolved

        :error ->
          resolved = do_resolve(executable)
          :persistent_term.put(@cache_term, Map.put(cache, executable, resolved))
          resolved
      end
    end
  end

  @doc """
  Generates a merged environment map including PATH and any extra variables.
  """
  def env(extra \\ %{})

  def env(nil), do: env(%{})

  def env(extra) when is_map(extra) or is_list(extra) do
    base = Map.put(System.get_env(), "PATH", path())

    Enum.reduce(extra, base, fn {k, v}, acc ->
      Map.put(acc, to_string(k), to_string(v))
    end)
  end

  @doc """
  Executes a command with the resolved executable and merged environment.
  """
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    resolved = resolve(executable)
    extra_env = Keyword.get(opts, :env, %{})
    merged_env = env(extra_env)

    cd = Keyword.get(opts, :cd) || Keyword.get(opts, :working_directory)
    base_opts = [{:env, Map.to_list(merged_env)} | Keyword.take(opts, [:into, :stderr_to_stdout])]

    cmd_opts =
      if is_binary(cd) do
        [{:cd, cd} | base_opts]
      else
        base_opts
      end

    System.cmd(resolved, args, cmd_opts)
  end

  @doc """
  Calculates merged PATH according to spec ordering and deduplication rules.
  """
  def calculate_path(shell_path, sys_path \\ nil) do
    sep = separator()

    shell_segments =
      if is_binary(shell_path) and shell_path != "" do
        String.split(shell_path, sep)
      else
        []
      end

    effective_sys_path = sys_path || System.get_env("PATH") || ""

    sys_segments =
      if effective_sys_path == "" do
        []
      else
        String.split(effective_sys_path, sep)
      end

    # coveralls-ignore-start (Windows OS branches not applicable on macOS/Linux runners)
    {home_segments, fallback_segments} =
      if windows?() do
        {[], []}
      else
        # coveralls-ignore-stop
        home = System.get_env("HOME") || ""

        home_dirs =
          if home == "" do
            []
          else
            [Path.join(home, ".local/bin"), Path.join(home, "bin")]
          end

        {home_dirs, @fallback_dirs}
      end

    (shell_segments ++ sys_segments ++ home_segments ++ fallback_segments)
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
    |> Enum.join(sep)
  end

  @doc """
  Parses stdout from login shell probe looking for the __axis_path__ marker.
  """
  def parse_shell_path(stdout) when is_binary(stdout) do
    Enum.find_value(String.split(stdout, "\n"), fn line ->
      trimmed = String.trim(line)

      if String.starts_with?(trimmed, "__axis_path__") do
        String.replace_prefix(trimmed, "__axis_path__", "")
      end
    end)
  end

  def parse_shell_path(_other), do: nil

  @doc """
  Probes the login shell with a 5-second timeout.
  """
  def login_shell_path(shell \\ System.get_env("SHELL")) do
    # coveralls-ignore-start (Windows OS branches not applicable on macOS/Linux runners)
    if windows?() do
      nil
    else
      # coveralls-ignore-stop
      if is_nil(shell) or shell == "" do
        nil
      else
        task =
          Task.async(fn ->
            try do
              System.cmd(shell, ["-lic", ~s(printf "\n__axis_path__%s\n" "$PATH")],
                env: [],
                stderr_to_stdout: false
              )
            rescue
              _error -> nil
            end
          end)

        case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, {stdout, 0}} ->
            parse_shell_path(stdout)

          _other ->
            nil
        end
      end
    end
  end

  defp do_resolve(executable) do
    sep = separator()
    dirs = String.split(path(), sep)

    Enum.find_value(dirs, executable, fn dir ->
      candidate = Path.join(dir, executable)
      if executable?(candidate), do: candidate
    end)
  end

  defp executable?(candidate) do
    case File.stat(candidate) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Bitwise.band(mode, 0o111) != 0

      _other ->
        false
    end
  end

  # coveralls-ignore-start (Windows OS branches not applicable on macOS/Linux runners)
  defp separator do
    if windows?(), do: ";", else: ":"
  end

  defp windows? do
    match?({:win32, _}, :os.type())
  end

  # coveralls-ignore-stop
end
