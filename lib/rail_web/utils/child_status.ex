defmodule RailWeb.Utils.ChildStatus do
  @moduledoc """
  Where one child of a split stands among its siblings: merged or canceled as Linear has it, blocked by a
  sibling it builds on that was canceled or deleted, waiting while one has not merged, else as its run.
  """

  import RailWeb.Utils.FormatAge
  import RailWeb.Utils.RunStateStyle
  import RailWeb.Utils.StageLabel

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task

  @stages [:engineer, :review, :qa, :demo]

  @amber "bg-amber-100 dark:bg-amber-950 text-amber-900 dark:text-amber-200"
  @slate_text "text-slate-500 dark:text-slate-400"

  @doc """
  Says where `child` stands among `siblings`, every child of its split, each with its `issue` and its
  `runs` with their `role` and `questions` loaded. The board, switcher and overview read the same map.
  """
  def child_status(%Task{issue: %Issue{} = issue} = child, siblings) do
    by_position = Map.new(siblings, &{&1.split_position, &1})
    earlier = for position <- child.builds_on, sibling = by_position[position], do: sibling
    run = stage_run(child)

    unstarted? = issue.completed_at == nil and child.runs == []
    {canceled, open} = earlier |> Enum.filter(&is_nil(&1.issue.completed_at)) |> Enum.split_with(&canceled?/1)
    waiting_on = if unstarted?, do: Enum.map(open, & &1.issue.identifier), else: []
    # A sibling whose issue was deleted in Linear took its task with it, and will never merge either.
    removed = for position <- child.builds_on, not Map.has_key?(by_position, position), do: "child #{position}"
    blocked_by = if unstarted?, do: {Enum.map(canceled, & &1.issue.identifier), removed}, else: {[], []}

    base = %{
      task: child,
      identifier: issue.identifier,
      after: Enum.map(earlier, & &1.issue.identifier),
      waiting_on: waiting_on
    }

    cond do
      issue.completed_at != nil -> Map.merge(base, merged(child))
      issue.state in [:canceled, :duplicate] -> Map.merge(base, canceled(issue))
      blocked_by != {[], []} -> Map.merge(base, blocked(blocked_by))
      waiting_on != [] -> Map.merge(base, waiting(waiting_on))
      true -> Map.merge(base, working(child, run))
    end
  end

  defp merged(%Task{pr_number: pr_number}) do
    %{
      state: :merged,
      label: "Merged",
      icon: "pi-git-merge-fill",
      text_class: "text-emerald-600 dark:text-emerald-400",
      cells: Enum.map(@stages, &%{stage: &1, mark: :done, chip: nil}),
      merged: %{
        mark: :current,
        chip: %{
          label: "Merged",
          icon: "pi-git-merge-fill",
          class: "bg-emerald-100 dark:bg-emerald-950/60 text-emerald-800 dark:text-emerald-300"
        }
      },
      needs_attention: false,
      badge: nil,
      line: if(pr_number, do: "Merged · PR ##{pr_number}", else: "Merged"),
      line_class: "text-slate-600 dark:text-slate-300",
      action: nil
    }
  end

  # Nobody will work on it again, so it waits on nobody and is never in the way of the split finishing.
  defp canceled(%Issue{state: state}) do
    label = Issue.state_label(state)

    %{
      state: :canceled,
      label: label,
      icon: "pi-x-circle",
      text_class: @slate_text,
      cells: Enum.map(@stages, &%{stage: &1, mark: :pending, chip: nil}),
      merged: %{
        mark: :current,
        chip: %{
          label: label,
          icon: "pi-x-circle",
          class: "bg-slate-100 dark:bg-slate-700 text-slate-600 dark:text-slate-300"
        }
      },
      needs_attention: false,
      badge: nil,
      line: "#{label} in Linear",
      line_class: "text-slate-600 dark:text-slate-300",
      action: nil
    }
  end

  # It builds on work that will never merge, so only its owner canceling it too lets the split finish.
  defp blocked({canceled, removed}) do
    chip = %{label: "Blocked", icon: "pi-warning-circle", class: @amber}
    blocked_by = canceled ++ removed

    gone =
      [{canceled, "canceled"}, {removed, "removed in Linear"}]
      |> Enum.reject(&match?({[], _how}, &1))
      |> Enum.map_join(" and ", fn {names, how} ->
        "#{join_and(names)} #{if length(names) == 1, do: "was", else: "were"} #{how}"
      end)

    %{
      state: :blocked_by_canceled,
      label: "Blocked by #{Enum.join(blocked_by, ", ")}",
      icon: "pi-warning-circle",
      text_class: "text-amber-700 dark:text-amber-300",
      cells:
        Enum.map(
          @stages,
          &if(&1 == :engineer,
            do: %{stage: &1, mark: :current, chip: chip},
            else: %{stage: &1, mark: :pending, chip: nil}
          )
        ),
      merged: %{mark: :pending, chip: nil},
      needs_attention: true,
      badge: :dot,
      line: "#{gone}, so this will not start; cancel it in Linear to finish the split",
      line_class: "text-amber-700 dark:text-amber-300",
      action: nil
    }
  end

  defp waiting(waiting_on) do
    chip = %{
      label: "Waiting",
      icon: "pi-clock",
      class: "border border-dashed border-slate-400 dark:border-slate-500 text-slate-500 dark:text-slate-400"
    }

    %{
      state: :waiting_on,
      label: "Waiting on #{Enum.join(waiting_on, ", ")}",
      icon: "pi-clock",
      text_class: @slate_text,
      cells:
        Enum.map(
          @stages,
          &if(&1 == :engineer,
            do: %{stage: &1, mark: :current, chip: chip},
            else: %{stage: &1, mark: :pending, chip: nil}
          )
        ),
      merged: %{mark: :pending, chip: nil},
      needs_attention: false,
      badge: nil,
      line: "Starts when #{join_and(waiting_on)} #{if length(waiting_on) == 1, do: "merges", else: "merge"}",
      line_class: "text-slate-600 dark:text-slate-300",
      action: nil
    }
  end

  defp working(%Task{stage: stage} = child, run) do
    state = Run.state(run)
    style = run_state_style(run)
    needs = run != nil and Run.needs_attention?(%{run | task: child})
    pending = if run, do: Enum.count(run.questions, &(&1.status == :pending)), else: 0
    reached = Enum.find_index(@stages, &(&1 == stage)) || 0

    cells =
      for {cell, index} <- Enum.with_index(@stages) do
        cond do
          index < reached -> %{stage: cell, mark: :done, chip: nil}
          index == reached -> %{stage: cell, mark: :current, chip: chip(state, stage, style)}
          true -> %{stage: cell, mark: :pending, chip: nil}
        end
      end

    %{
      state: state,
      label: stage_label(child, run),
      icon: style.icon,
      text_class: style.text_class,
      cells: cells,
      merged: %{mark: :pending, chip: nil},
      needs_attention: needs,
      badge:
        cond do
          pending > 0 -> pending
          needs -> :dot
          true -> nil
        end,
      line: line(state, child, run),
      line_class:
        cond do
          state == :failed -> "text-red-600 dark:text-red-500"
          needs -> "text-amber-700 dark:text-amber-300"
          true -> "text-slate-600 dark:text-slate-300"
        end,
      action: if(needs, do: %{label: action(state, child), tab: run.role_id})
    }
  end

  defp chip(:running, _stage, _style), do: %{label: "Running", icon: "pi-play-circle", class: blue()}
  defp chip(:blocked, _stage, _style), do: %{label: "Questions", icon: "pi-question", class: @amber}
  defp chip(:done, :review, _style), do: %{label: "Findings", icon: "pi-chat-text", class: @amber}
  defp chip(:done, :engineer, _style), do: %{label: "Diff", icon: "pi-chat-text", class: @amber}
  defp chip(:done, :qa, _style), do: %{label: "Report", icon: "pi-chat-text", class: @amber}
  defp chip(:done, :demo, _style), do: %{label: "Demo", icon: "pi-chat-text", class: @amber}

  defp chip(:failed, _stage, _style),
    do: %{label: "Failed", icon: "pi-warning-circle", class: "bg-red-100 dark:bg-red-900 text-red-800 dark:text-red-200"}

  defp chip(_idle, _stage, style), do: %{label: style.pill_label, icon: style.icon, class: style.chip_class}

  defp blue, do: "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"

  defp line(:running, %Task{stage: stage}, %Run{} = run) do
    since = run.started_at || run.inserted_at
    "#{Task.stage_label(stage)} running · #{format_age(DateTime.diff(DateTime.utc_now(), since))}"
  end

  defp line(:blocked, %Task{}, %Run{} = run) do
    case Enum.count(run.questions, &is_nil(&1.delivered_at)) do
      1 -> "#{run.role.name} asked a question"
      count -> "#{run.role.name} asked #{count} questions"
    end
  end

  defp line(:failed, %Task{stage: stage}, %Run{error: error}), do: "#{Task.stage_label(stage)} failed: #{error}"
  defp line(:done, %Task{stage: :engineer}, _run), do: "Diff ready for review"
  defp line(:done, %Task{stage: :review}, _run), do: "Findings to rule"
  defp line(:done, %Task{stage: :qa}, _run), do: "QA report ready"
  defp line(:done, %Task{stage: :demo}, _run), do: "Demo recorded"
  defp line(:queued, %Task{stage: stage}, _run), do: "Queued for #{Task.stage_label(stage)}"
  defp line(:waiting, %Task{stage: stage}, _run), do: "#{Task.stage_label(stage)} waiting for resources"
  defp line(:stopped, %Task{stage: stage}, _run), do: "#{Task.stage_label(stage)} stopped"

  defp action(:blocked, _child), do: "Answer"
  defp action(:done, %Task{} = child), do: approval_label(child)
  defp action(_stalled, _child), do: "Fix"

  # A child is read through its stage's latest run, as the task page reads it.
  defp stage_run(%Task{runs: runs, stage: stage}) do
    runs
    |> Enum.filter(&(&1.role.stage == stage))
    |> Enum.max_by(&(&1.started_at || &1.inserted_at), DateTime, fn -> nil end)
  end

  defp canceled?(%Task{issue: %Issue{state: state}}), do: state in [:canceled, :duplicate]

  defp join_and([one]), do: one
  defp join_and(names), do: Enum.join(Enum.drop(names, -1), ", ") <> " and " <> List.last(names)
end
