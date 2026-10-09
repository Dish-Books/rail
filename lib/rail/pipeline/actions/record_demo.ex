defmodule Rail.Pipeline.Actions.RecordDemo do
  @moduledoc """
  Re-record on a demo the branch has moved past: asks the Review lead, idle at Review, to have its demo
  recorder record the shot list again on HEAD. Refused while the lead works, so two clicks ask once.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @ask """
  Record the demo again: the branch has moved on since it was recorded. Have the demo recorder record the same shot list on HEAD, in the browser named `demo`, and save it with `save_demo`. Nothing else in the review changes.
  """

  @doc """
  Messages `task`'s Review lead to record the demo again, as the scope's user. Returns what
  `Rail.Pipeline.send_message/4` does, or `{:error, reason}` when the task is not at Review or the lead works.
  """
  def record_demo(%Scope{} = scope, %Task{} = task) do
    task = Repo.preload(task, [runs: :role], force: true)

    with :ok <- at_review(task),
         {:ok, run} <- lead_run(task),
         :ok <- idle(run) do
      Pipeline.send_message(scope, run, String.trim(@ask))
    end
  end

  defp at_review(%Task{stage: :review}), do: :ok
  defp at_review(%Task{stage: stage}), do: {:error, {:invalid_stage, stage}}

  defp lead_run(%Task{runs: runs}) do
    case Enum.filter(runs, &match?(%Run{role: %Role{stage: :review_lead}}, &1)) do
      [] -> {:error, :no_stage_run}
      leads -> {:ok, Enum.max_by(leads, &(&1.started_at || &1.inserted_at), DateTime)}
    end
  end

  defp idle(%Run{} = run), do: if(Run.running?(run), do: {:error, :stage_running}, else: :ok)
end
