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
  alias Rail.Scope

  @doc """
  Checks demo freshness against the current worktree fingerprint:
  - If task is merged or has no demo: returns `{:ok, task}`.
  - If demo is not already stale and worktree exists:
    - Compares current fingerprint against demo's `head_sha` and `dirty_digest`.
    - If drifted: marks demo `stale: true`.
    - If task is sitting at `ready_to_merge` awaiting approval and not busy:
      re-queues to `demo` queued, broadcasts, and pumps dispatcher.
  """
  def refresh_demo_freshness(scope_or_task, task_or_opts \\ [], opts \\ [])

  def refresh_demo_freshness(%Scope{} = scope, task_or_id, _opts) do
    if authorized?(scope) do
      case resolve_task(task_or_id) do
        %Task{} = task -> do_refresh_demo_freshness(task)
        nil -> {:error, :not_found}
      end
    else
      {:error, :not_authorized}
    end
  end

  def refresh_demo_freshness(task_or_id, opts, _extra) do
    refresh_demo_freshness(Scope.for_system(), task_or_id, opts)
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_refresh_demo_freshness(%Task{stage: :merged} = task), do: {:ok, task}

  defp do_refresh_demo_freshness(%Task{merged_at: %DateTime{}} = task), do: {:ok, task}

  defp do_refresh_demo_freshness(%Task{} = task) do
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

    if task.stage == :ready_to_merge and task.stage_state == :awaiting_approval and not Task.busy?(task) do
      {:ok, updated_task} =
        task
        |> Task.changeset(%{
          stage: :demo,
          stage_state: :queued,
          error: nil,
          retry_after: nil
        })
        |> Repo.update()

      Rail.Pipeline.broadcast_pipeline_changed(%{
        task_id: updated_task.id,
        event: :demo_stale_requeued
      })

      Rail.Pipeline.pump_dispatcher()

      {:ok, updated_task}
    else
      Rail.Pipeline.broadcast_pipeline_changed(%{
        task_id: task.id,
        event: :demo_marked_stale
      })

      {:ok, task}
    end
  end

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil
end
