defmodule Rail.Backends.ProcessRunner do
  @moduledoc """
  Timeout-aware process execution using Rail.Tools for environment and path parity.
  """

  alias Rail.Tools

  @doc """
  Runs an executable with arguments and options, enforcing a timeout.
  Returns `{:ok, stdout, exit_code}` on normal termination, or `{:error, reason}`.
  """
  def run(executable, args, opts \\ []) when is_binary(executable) and is_list(args) do
    timeout = Keyword.get(opts, :timeout, 20_000)

    task =
      Task.async(fn ->
        try do
          Tools.run(executable, args, opts)
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, error}} ->
        {:error, error}

      {:ok, {stdout, exit_code}} ->
        {:ok, stdout, exit_code}

      nil ->
        {:error, :timeout}
    end
  end

  @doc """
  Normalizes runner results into standard `{:ok, stdout, exit_code}` or `{:error, reason}`.
  """
  def normalize_result({:ok, stdout, exit_code}) when is_binary(stdout) and is_integer(exit_code) do
    {:ok, stdout, exit_code}
  end

  def normalize_result({stdout, exit_code}) when is_binary(stdout) and is_integer(exit_code) do
    {:ok, stdout, exit_code}
  end

  def normalize_result({:ok, %{stdout: stdout, exit_code: exit_code}}) when is_binary(stdout) and is_integer(exit_code) do
    {:ok, stdout, exit_code}
  end

  def normalize_result({:error, reason}), do: {:error, reason}
end
