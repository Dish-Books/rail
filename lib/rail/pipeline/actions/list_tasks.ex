defmodule Rail.Pipeline.Actions.ListTasks do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  # A run in flight, as `Run.running?/1` reads one: executing, or waiting for a sandbox or an account.
  @running [:starting, :running, :waiting_for_resources, :waiting_for_usage]

  @doc """
  Lists tasks, filtered and preloaded as `opts` asks.

  `:project_id` takes one id or a list, where an empty list matches nothing.
  `:owner_user_id` keeps the tasks whose issue that user owns, so an unowned issue's tasks drop out.
  `:issue_id` keeps one issue's tasks.
  `:pr_url` keeps the tasks whose pull request is at that address.
  `:parent_task_id` keeps one split's children, in their order unless `:order_by` says otherwise, and
  `split_child: true` every child of every split.
  `ready: true` keeps the review queue: tasks at Finalize marked ready and not merged, whose issue has
  not closed and with no agent at work on them, oldest mark first.
  `plan_ready: true` keeps the tech leads' plans to approve: tasks whose first round's plan was sent and is not
  approved, started or not, and whose Plan agent is not at work on it, oldest sent first, with that round alone as
  `rounds`.
  Cleaned-up tasks are left out unless `include_cleaned_up: true`.
  """
  def list_tasks(opts \\ []) do
    Task
    |> from(as: :task)
    |> order_by(^Keyword.get(opts, :order_by, default_order(opts)))
    |> preload(^Keyword.get(opts, :preload, []))
    |> filter_project(opts[:project_id])
    |> filter_owner(opts[:owner_user_id])
    |> filter_issue(opts[:issue_id])
    |> filter_pr_url(opts[:pr_url])
    |> filter_parent(opts[:parent_task_id])
    |> filter_split_child(opts[:split_child])
    |> filter_stage(opts[:stage])
    |> filter_ready(opts[:ready])
    |> filter_plan_ready(opts[:plan_ready])
    |> filter_cleaned_up(opts[:include_cleaned_up])
    |> Repo.all()
  end

  defp default_order(opts) do
    cond do
      opts[:ready] -> [asc: :marked_ready_at, asc: :id]
      # Ordered by its round, which the filter joins.
      opts[:plan_ready] -> []
      opts[:parent_task_id] -> [asc: :split_position]
      true -> [asc: :inserted_at]
    end
  end

  defp filter_cleaned_up(query, true), do: query
  defp filter_cleaned_up(query, _live_only), do: where(query, [task: t], is_nil(t.cleaned_up_at))

  defp filter_project(query, project_id) when is_binary(project_id) do
    where(query, [task: t], t.project_id == ^project_id)
  end

  defp filter_project(query, project_ids) when is_list(project_ids) do
    where(query, [task: t], t.project_id in ^project_ids)
  end

  defp filter_project(query, _all_projects), do: query

  defp filter_owner(query, user_id) when is_binary(user_id) do
    query
    |> join(:inner, [task: t], i in assoc(t, :issue), as: :issue)
    |> where([issue: i], i.owner_user_id == ^user_id)
  end

  defp filter_owner(query, nil), do: query

  defp filter_issue(query, issue_id) when is_binary(issue_id), do: where(query, [task: t], t.issue_id == ^issue_id)
  defp filter_issue(query, nil), do: query

  defp filter_pr_url(query, pr_url) when is_binary(pr_url), do: where(query, [task: t], t.pr_url == ^pr_url)
  defp filter_pr_url(query, nil), do: query

  defp filter_parent(query, parent_task_id) when is_binary(parent_task_id),
    do: where(query, [task: t], t.parent_task_id == ^parent_task_id)

  defp filter_parent(query, nil), do: query

  defp filter_split_child(query, true), do: where(query, [task: t], not is_nil(t.parent_task_id))
  defp filter_split_child(query, nil), do: query

  defp filter_stage(query, nil), do: query

  defp filter_stage(query, stage) when is_atom(stage) do
    where(query, [task: t], t.stage == ^stage)
  end

  # A pull request merged on GitHub closes its issue without Rail hearing of the merge, so it leaves as on Overview.
  defp filter_ready(query, true) do
    query
    |> with_named_binding(:issue, &join(&1, :inner, [task: t], i in assoc(t, :issue), as: ^&2))
    |> where([task: t], t.stage == :finalize and not is_nil(t.marked_ready_at) and is_nil(t.merged_at))
    |> where([issue: i], is_nil(i.completed_at) and i.state not in ^Issue.finished_states())
    # Any agent at work, the curator too, holds back the task's Approve and Merge, so it waits until they stop.
    |> where([task: t], not exists(runs_in_flight()))
  end

  defp filter_ready(query, nil), do: query

  defp filter_plan_ready(query, true) do
    query
    |> join(:inner, [task: t], r in Round, as: :round, on: r.task_id == t.id and r.number == 1)
    |> where([round: r], not is_nil(r.ready_at) and is_nil(r.approved_at))
    # The plan is still changing while Plan works, and the task's header offers no Approve until it stops.
    |> where(
      [task: t],
      not exists(
        runs_in_flight()
        |> join(:inner, [run], role in Role, on: role.id == run.role_id)
        |> where([_run, role], role.stage == :plan)
      )
    )
    # From the join, so a plan saved again between two queries cannot hand back a round the filter never matched.
    |> preload([round: r], rounds: r)
    |> order_by([task: t, round: r], asc: r.ready_at, asc: t.id)
  end

  defp filter_plan_ready(query, nil), do: query

  # The runs in flight on the task the outer query names `:task`.
  defp runs_in_flight do
    from run in Run, where: run.task_id == parent_as(:task).id and run.status in ^@running
  end
end
