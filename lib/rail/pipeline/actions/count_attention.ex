defmodule Rail.Pipeline.Actions.CountAttention do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Counts the tasks waiting on a human, across every project unless `:project_id` narrows it, the same way
  the Overview lists them: a task whose stage run waits, and a child of a split with no run
  that a canceled or deleted sibling keeps from starting.
  """
  def count_attention(opts \\ []) do
    waiting =
      [project_id: opts[:project_id], preload: [:role, :questions, task: :issue]]
      |> Pipeline.list_runs()
      |> Enum.group_by(& &1.task_id)
      |> Enum.count(fn {_task_id, [%Run{task: task} | _rest] = runs} ->
        case Task.stage_run(%{task | runs: runs}) do
          %Run{} = run -> Run.needs_attention?(run)
          nil -> false
        end
      end)

    blocked =
      [project_id: opts[:project_id], split_child: true, preload: [:issue, :runs, parent_task: [children: :issue]]]
      |> Pipeline.list_tasks()
      |> Enum.count(&blocked?/1)

    waiting + blocked
  end

  # Only its owner canceling it too lets its split finish, so it waits on them as a run would.
  defp blocked?(%Task{runs: [], issue: %Issue{completed_at: nil, state: state}} = child)
       when state not in [:canceled, :duplicate] do
    Task.split_blockers(child, child.parent_task.children) != {[], []}
  end

  defp blocked?(%Task{}), do: false
end
