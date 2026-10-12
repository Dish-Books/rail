defmodule Rail.Pipeline.Workers.StartApprovedFixPlan do
  @moduledoc """
  Resumes the Review lead on a fix plan just approved. The job is committed with the run's claim, so the lead starts
  even if the page that approved is gone, and is retried if it dies part way. A start it refuses puts the plan back
  to waiting.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:run_id], states: :incomplete, period: :infinity]

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.SendBack
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "version" => version} = args, inserted_at: queued_at}) do
    with %Run{} = run <- Run |> Repo.get(run_id) |> Repo.preload(task: [:issue, :project]),
         %FixPlan{version: ^version} = fix_plan <- Pipeline.read_fix_plan(run.task),
         false <- spawned?(run, queued_at) do
      # A run stopped before the spawn was taken back by the person, so the plan waits again.
      if Run.running?(run), do: start(run, fix_plan, args), else: refused(run, fix_plan)
    else
      _gone_replaced_or_spawned -> :ok
    end
  end

  defp start(%Run{} = run, %FixPlan{} = fix_plan, %{"approved_by" => name, "approved_at" => at, "before" => before}) do
    {:ok, approved_at, 0} = DateTime.from_iso8601(at)
    {:ok, role} = Roles.get_role(id: run.role_id)
    # Written again in case the approval died before writing it: a turn ending on an unapproved plan only planned.
    :ok = write_fix_plan(run.task, %{fix_plan | approved_by: name, approved_at: approved_at})

    case Pipeline.start_review_run(%{run | role: role}) do
      {:ok, _os_process} ->
        send_back(run.task, :review_lead, "#{name} approved the fix plan.")
        broadcast_pipeline_changed(run.task)
        :ok

      # The start settled the run, so only the plan goes back to waiting.
      {:error, {:spawn_failed, _reason, %Run{}}} ->
        refused(run, fix_plan)

      {:error, :dispatch_disabled} ->
        {:ok, _settled} =
          run
          |> Run.changeset(%{
            status: :finished,
            stage_outcome: before["stage_outcome"],
            completed_at: before["completed_at"],
            error: before["error"]
          })
          |> Repo.update()

        refused(run, fix_plan)
    end
  end

  defp refused(%Run{} = run, %FixPlan{} = fix_plan) do
    :ok = write_fix_plan(run.task, %{fix_plan | approved_by: nil, approved_at: nil})
    broadcast_pipeline_changed(run.task)
    :ok
  end

  # An attempt that died before its spawn left the run claimed with no process, which only this job recovers; one
  # that died after it left a process, and starting again would resume the lead twice.
  defp spawned?(%Run{id: run_id}, queued_at) do
    [run_id: run_id]
    |> Tools.list_os_processes()
    |> Enum.any?(&(DateTime.compare(&1.inserted_at, queued_at) != :lt))
  end
end
