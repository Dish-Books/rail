defmodule Rail.Pipeline.Workers.AdvanceSplit do
  @moduledoc """
  Starts each child with no run once every child it builds on has merged, and moves the parent to Merged
  once every child has merged or been canceled. One job per parent, retried if it dies, run again on a merge.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:parent_task_id], states: :incomplete, period: :infinity]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"parent_task_id" => parent_task_id}}) do
    case Repo.get(Task, parent_task_id) do
      %Task{} = parent -> advance(parent)
      nil -> :ok
    end
  end

  defp advance(%Task{} = parent) do
    children = children(parent)
    merged = merged(children)
    settled = settled(children)

    for %Task{runs: [], cleaned_up_at: nil, builds_on: builds_on} = child <- children,
        not MapSet.member?(settled, child.split_position),
        Enum.all?(builds_on, &MapSet.member?(merged, &1)) do
      {:ok, _started} = Pipeline.enter_stage(child, :engineer)
    end

    if parent.stage == :split and MapSet.size(settled) == length(children) do
      {:ok, _parent} = Pipeline.enter_stage(parent, :merged, start: false)
    end

    if settled(children(parent)) == settled, do: :ok, else: {:snooze, 1}
  end

  defp children(%Task{id: id}) do
    Pipeline.list_tasks(parent_task_id: id, include_cleaned_up: true, preload: [:issue, :runs])
  end

  # A child has merged once Linear completed its issue, as every other task in Rail has.
  defp merged(children) do
    for %Task{issue: issue, split_position: position} <- children, issue.completed_at != nil, into: MapSet.new() do
      position
    end
  end

  defp settled(children), do: MapSet.union(merged(children), canceled(children))

  # A child canceled in Linear will never merge, so it is no reason for its parent to stay open.
  defp canceled(children) do
    for %Task{issue: issue, split_position: position} <- children,
        issue.completed_at == nil and issue.state in [:canceled, :duplicate],
        into: MapSet.new(),
        do: position
  end
end
