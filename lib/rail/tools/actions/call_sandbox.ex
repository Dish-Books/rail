defmodule Rail.Tools.Actions.CallSandbox do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.Sandbox

  @timeout_ms to_timeout(minute: 5)

  @doc """
  Calls `method` with `params` on the runner of `task`'s sandbox, as docs/sandbox-socket.md lists them, and waits for
  its reply. Takes `:timeout` in milliseconds, five minutes by default. Returns `{:ok, result}`, `{:error, error}` as the
  runner said it, `{:error, :not_running}` when the task's sandbox has no checked-out container connected, or
  `{:error, :timeout}`.
  """
  def call_sandbox(%Task{id: task_id}, method, params, opts \\ []) when is_binary(method) and is_map(params) do
    case Repo.one(from s in Sandbox, where: s.task_id == ^task_id and s.status == :running, select: s.id) do
      sandbox_id when is_binary(sandbox_id) ->
        RunnerSocket.call(sandbox_id, method, params, Keyword.get(opts, :timeout, @timeout_ms))

      nil ->
        {:error, :not_running}
    end
  end
end
