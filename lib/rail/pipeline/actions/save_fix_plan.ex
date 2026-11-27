defmodule Rail.Pipeline.Actions.SaveFixPlan do
  @moduledoc """
  Saves the review agent's plan for the next round, in place of the one before it. A plan is due once a review is
  saved, until the task merges, or while one a Send asked for waits. A plan with nothing to fix, no comment to
  answer, no change to the ticket or the design and nothing a person asked the Review lead for in the conversation is
  no round at all, so it is refused rather than left waiting on an approval that would start an engineer on nothing,
  while it holds back Finish review.

  A change asked for in the conversation is one a person typed to the Review lead since the round's review was saved,
  or since the last plan was approved. No finding or comment carries it, so the plan says what it is under
  `#### Changes to the plan`.
  """

  import Ecto.Changeset
  import Ecto.Query
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @no_changes_item "covers no finding or comment, so the change asked for in the conversation goes under " <>
                     "`### What changes` as `#### Changes to the plan`, saying what was asked, by whom, and what changes"

  @doc """
  Saves `attrs["plan"]` as the next version of `task`'s fix plan. Returns `{:ok, fix_plan}`, `{:error, :no_fix_plan}`
  when none is due, `{:error, :nothing_to_fix}` for a plan that changes nothing, `{:error, {:step_off, :demo}}` for a
  demo asked of a task whose workflow turned it off, or `{:error, changeset}` naming what to fix.
  """
  def save_fix_plan(%Task{} = task, attrs) when is_map(attrs) do
    task = Repo.preload(task, :issue)

    with false <- Issue.skips_step?(task.issue, :demo) and attrs["record_demo"] == true,
         %FixPlan{} = fix_plan <- due(task),
         :ok <- something(fix_plan, task, attrs),
         {:ok, saved} <- fix_plan |> FixPlan.save_changeset(attrs) |> apply_action(:update) do
      saved = %{saved | base_conflicts: base_conflicts(task)}
      write_fix_plan(task, saved)
      Pipeline.broadcast_output_saved(task)
      {:ok, saved}
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, :nothing_to_fix} -> {:error, :nothing_to_fix}
      true -> {:error, {:step_off, :demo}}
      _none_due -> {:error, :no_fix_plan}
    end
  end

  # Whatever the review agent planned, a branch that conflicts with the default branch merges it first, so the plan
  # says so where the person reads it.
  defp base_conflicts(%Task{} = task) do
    {:ok, %Task{base_conflicts: conflicts}} = Pipeline.check_base(task)
    conflicts
  end

  defp something(%FixPlan{findings: [], comments: []} = fix_plan, %Task{} = task, attrs) do
    cond do
      Enum.any?(["title", "description", "design_changed"], &(attrs[&1] not in [nil, false, ""])) -> :ok
      not asked_in_chat?(task) -> {:error, :nothing_to_fix}
      is_binary(attrs["plan"]) and Regex.match?(~r/^#### Changes to the plan\s*$/mi, attrs["plan"]) -> :ok
      true -> {:error, fix_plan |> change() |> add_error(:plan, @no_changes_item)}
    end
  end

  defp something(%FixPlan{}, %Task{}, _attrs), do: :ok

  # Only what a person typed: Rail's own lines on their behalf, as Finish review's, are `[human]` with no one named.
  defp asked_in_chat?(%Task{id: task_id} = task) do
    since = since(task)

    since != nil and
      Repo.exists?(
        from e in RunEvent,
          join: r in Run,
          on: r.id == e.run_id,
          join: role in Role,
          on: role.id == r.role_id,
          where: r.task_id == ^task_id and role.stage == :review_lead and e.inserted_at > ^since,
          where: like(e.line, "[human:%") or like(e.line, "[human-image:%")
      )
  end

  # A message before the round's review was saved, or before the last plan was approved, is that round's.
  defp since(%Task{} = task) do
    saved = for %{saved_at: at} <- Enum.take(Pipeline.read_review(task), -1), do: at
    approved = for %FixPlan{approved_at: %DateTime{} = at} <- [Pipeline.read_fix_plan(task)], do: at
    Enum.max(saved ++ approved, DateTime, fn -> nil end)
  end

  # A plan a Send asked for waits to be saved. With none waiting, the review agent writes the next round's
  # unasked once a review is saved: it covers every finding to fix as they stand now, and a change to the ticket or
  # the design a person asked for, which can come with no finding at all.
  defp due(%Task{stage: stage} = task) do
    passes = Pipeline.read_review(task)

    case Pipeline.read_fix_plan(task) do
      %FixPlan{approved_at: nil} = waiting ->
        waiting

      _none_or_approved when stage in [:review, :finalize] and passes != [] ->
        fix = task |> Pipeline.list_findings() |> Enum.filter(&Finding.outstanding?/1)

        %FixPlan{
          round: length(passes),
          head: List.last(passes).head,
          findings: Enum.map(fix, &%FixPlan.Finding{key: &1.key, title: &1.title})
        }

      _none_due ->
        nil
    end
  end
end
