defmodule Rail.Tools.Actions.StartAfterUsageReset do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.PlaceOnAccount

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Places a turn that waited for usage again, from the arguments it kept, once
  the reset it waited for has passed.

  The row is claimed only while it still waits, so a Stop that landed first wins
  and it never starts. Returns `{:ok, os_process}` once it runs or joins the
  sandbox line, `{:waiting_for_usage, resets_at}` when it waits again,
  `{:error, :not_waiting}`, or `{:error, reason}` with its run failed.
  """
  def start_after_usage_reset(os_process_id) do
    {claimed, _rows} =
      Repo.update_all(
        from(p in OsProcess, where: p.id == ^os_process_id and p.status == :waiting_for_usage),
        set: [status: :starting, updated_at: DateTime.utc_now()]
      )

    if claimed == 1, do: place(Repo.get!(OsProcess, os_process_id)), else: {:error, :not_waiting}
  end

  defp place(%OsProcess{} = os_process) do
    %{"argv" => argv, "token" => token} = OsProcess.launch_spec(os_process)
    run = Run |> Repo.get!(os_process.run_id) |> Repo.preload([:role, task: :project])

    case place_on_account(os_process, run, argv, token) do
      {:ok, started} ->
        {:ok, _running} = Pipeline.update_run(Repo.reload!(run), %{status: :running})
        Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
        {:ok, started}

      {:waiting, in_line} ->
        {:ok, in_line}

      {:waiting_for_usage, _parked, resets_at} ->
        {:waiting_for_usage, resets_at}

      {:error, reason} ->
        settle(Repo.get!(OsProcess, os_process.id), reason)
        {:error, reason}
    end
  end

  # A missing binary has already settled its run; a row that failed to start has not.
  defp settle(%OsProcess{status: :failed, run_id: run_id} = os_process, reason) do
    error = if is_binary(reason), do: reason, else: "Could not start its sandbox: #{inspect(reason)}"
    {:ok, _settled} = Pipeline.run_finished(os_process, %{exit_code: -1, error: error})
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
  end

  defp settle(%OsProcess{run_id: run_id}, _missing_binary) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
  end
end
