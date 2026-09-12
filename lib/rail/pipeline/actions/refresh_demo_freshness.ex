defmodule Rail.Pipeline.Actions.RefreshDemoFreshness do
  @moduledoc """
  Action to check whether the recorded demo for a task matches current worktree state.
  If HEAD or working tree has changed, marks the demo stale. If the task is
  waiting for approval at `ready_to_merge`, automatically re-queues it to `demo`.
  """

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Checks demo freshness against the current worktree fingerprint:
  - If task is merged or has no demo: returns `{:ok, task}`.
  - If demo is not already stale and worktree exists:
    - Compares current fingerprint against demo's `head_sha` and `dirty_digest`.
    - If drifted: marks demo `stale: true`.
    - If the task is sitting at `ready_to_merge` with nothing running on it,
      enters the demo stage again.
  """

  def refresh_demo_freshness(task, opts \\ [])

  def refresh_demo_freshness(%Task{stage: :merged} = task, _opts), do: {:ok, task}

  def refresh_demo_freshness(%Task{merged_at: %DateTime{}} = task, _opts), do: {:ok, task}

  def refresh_demo_freshness(%Task{} = task, _opts) do
    case fetch_latest_demo(task.id) do
      %Demo{stale: false, head_sha: head_sha} = demo when is_binary(head_sha) and head_sha != "" ->
        check_freshness_against_worktree(task, demo)

      _no_active_demo ->
        {:ok, task}
    end
  end

  defp fetch_latest_demo(task_id) do
    query =
      from d in Demo,
        where: d.task_id == ^task_id,
        order_by: [desc: d.version],
        limit: 1

    Repo.one(query)
  end

  defp check_freshness_against_worktree(%Task{worktree_path: path} = task, %Demo{} = demo)
       when is_binary(path) and path != "" do
    if File.dir?(path) do
      case Git.branch_fingerprint(path) do
        %{head_sha: current_sha, dirty_digest: current_digest} ->
          if demo.head_sha != current_sha or demo.dirty_digest != current_digest do
            handle_demo_drift(task, demo)
          else
            {:ok, task}
          end

        _fingerprint_failed ->
          {:ok, task}
      end
    else
      {:ok, task}
    end
  end

  defp check_freshness_against_worktree(%Task{} = task, _demo), do: {:ok, task}

  defp handle_demo_drift(%Task{} = task, %Demo{} = demo) do
    {:ok, _updated_demo} =
      demo
      |> Demo.changeset(%{stale: true})
      |> Repo.update()

    # Re-recording writes into the worktree everything else is working in, so
    # nothing on the task may still be running — not only the demo.
    if task.stage == :ready_to_merge and not (task |> Repo.preload(:runs) |> Task.running?()) do
      {:ok, _run} = Rail.Pipeline.enter_stage(task, :demo)


      {:ok, Repo.reload!(task)}
    else

      {:ok, task}
    end
  end
end
