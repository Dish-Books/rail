defmodule Rail.Pipeline.Actions.CountAttention do
  @moduledoc false

  import Rail.Pipeline.Utils.ListWaitingStageRuns

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Counts the tasks waiting on a human, across every project unless `:project_id` narrows it, the same way
  the Overview lists them: a task whose stage run waits, and a child of a split with no run
  that a canceled or deleted sibling keeps from starting. `:owner_user_id` keeps those on issues that user owns.
  """
  def count_attention(opts \\ []) do
    waiting =
      [project_id: opts[:project_id], owner_user_id: opts[:owner_user_id]]
      |> list_waiting_stage_runs()
      |> length()

    blocked =
      [
        project_id: opts[:project_id],
        owner_user_id: opts[:owner_user_id],
        split_child: true,
        preload: [:issue, :runs, parent_task: [children: :issue]]
      ]
      |> Pipeline.list_tasks()
      |> Enum.count(&blocked?/1)

    waiting + blocked
  end

  # Only its owner canceling it too lets its split finish, so it waits on them as a run would.
  defp blocked?(%Task{runs: [], issue: %Issue{completed_at: nil, state: state}} = child) when state != :canceled do
    Task.split_blockers(child, child.parent_task.children) != {[], []}
  end

  defp blocked?(%Task{}), do: false
end
