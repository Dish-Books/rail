defmodule Rail.Pipeline.Actions.DeclineDemo do
  @moduledoc """
  Action to proceed past the demo stage without recording a demo.
  Inserts a declined `Demo` artifact and advances the task to `ready_to_merge`.
  """

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Declines recording a demo for a task, recording a reason note and advancing
  the task to `ready_to_merge` awaiting approval.
  """
  def decline_demo(%Task{} = task, note \\ nil) do
    do_decline_demo(task, note)
  end

  defp do_decline_demo(%Task{} = task, note) do
    cleaned_note =
      if is_binary(note) and String.trim(note) != "" do
        String.trim(note)
      else
        "Declined by human"
      end

    version = next_demo_version(task.id)
    {head_sha, dirty_digest} = resolve_fingerprint(task)

    demo_attrs = %{
      task_id: task.id,
      version: version,
      recorded_at: DateTime.utc_now(),
      commit: head_sha,
      head_sha: head_sha,
      dirty_digest: dirty_digest,
      outcome: "declined",
      note: cleaned_note,
      stale: false,
      segments: []
    }

    with {:ok, _demo} <-
           %Demo{}
           |> Demo.changeset(demo_attrs)
           |> Repo.insert(),
         {:ok, updated_task} <-
           task
           |> Task.changeset(%{
             stage: :ready_to_merge,
             stage_state: :awaiting_approval,
             error: nil,
             retry_after: nil
           })
           |> Repo.update() do
      Rail.Pipeline.broadcast_pipeline_changed(%{
        task_id: updated_task.id,
        event: :demo_declined
      })

      {:ok, updated_task}
    end
  end

  defp next_demo_version(task_id) do
    query =
      from d in Demo,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1,
        select: d.version

    case Repo.one(query) do
      latest when is_integer(latest) -> latest + 1
      nil -> 1
    end
  end

  defp resolve_fingerprint(%Task{worktree_path: path}) when is_binary(path) do
    if File.dir?(path) do
      case Git.branch_fingerprint(path) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _other -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp resolve_fingerprint(_task), do: {nil, nil}
end
