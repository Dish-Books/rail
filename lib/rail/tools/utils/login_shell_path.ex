defmodule Rail.Tools.Utils.LoginShellPath do
  @moduledoc """
  Probes the user's login shell for the PATH an interactive terminal would see.

  The BEAM inherits the PATH of whatever launched it, which for a GUI app or a
  service omits Homebrew and version-manager shims.
  """

  @marker "__rail_path__"
  @timeout_ms 5_000

  @doc """
  Returns the login shell's PATH, or nil when it cannot answer within #{@timeout_ms}ms.
  """
  def login_shell_path(shell \\ System.get_env("SHELL"))

  def login_shell_path(shell) when is_binary(shell) and shell != "" do
    task = Task.async(fn -> probe(shell) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} ->
        parse(stdout)

      _other ->
        nil
    end
  end

  def login_shell_path(_other), do: nil

  defp probe(shell) do
    System.cmd(shell, ["-lic", ~s(printf "\n#{@marker}%s\n" "$PATH")],
      env: [],
      stderr_to_stdout: false
    )
  rescue
    _error -> nil
  end

  defp parse(stdout) when is_binary(stdout) do
    Enum.find_value(String.split(stdout, "\n"), fn line ->
      trimmed = String.trim(line)

      if String.starts_with?(trimmed, @marker) do
        String.replace_prefix(trimmed, @marker, "")
      end
    end)
  end

  defp parse(_other), do: nil
end
