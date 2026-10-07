defmodule Rail.Pipeline.Actions.ApplyPlanRevision do
  @moduledoc """
  Passes on what a Plan turn after approval revised, once the turn has ended: the ticket goes to the issue, and
  Engineer, while the task is there, is sent the new plan or ticket in one note. A turn's drafts never go out.

  Each step compares before it writes, under the task's lock, so a second call for the same turn does nothing.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.FormatTicket

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @stages [:engineer, :review, :qa, :demo]
  @design_heading "\n\n## Design: "

  @doc """
  Applies what the Plan `run` saved after approval. Returns `{:ok, plan}`, the recorded plan as stamped now, `{:ok, nil}`
  when the task is not at a stage a revision reaches, or `{:error, reason}` when the issue could not be written.
  """
  def apply_plan_revision(%Run{} = run) do
    result =
      Repo.transaction(fn ->
        task = Repo.one!(from t in Task, where: t.id == ^run.task_id, lock: "FOR UPDATE")
        task = Repo.preload(task, :issue)

        with true <- task.stage in @stages || :not_revisable,
             %ImplementationPlan{} = plan <- Repo.get_by(ImplementationPlan, task_id: task.id) || :not_revisable,
             {:ok, ticket} <- publish_ticket(task, plan.announced_at || plan.captured_at),
             plan? = plan.plan_revised_at != nil and later?(plan.plan_revised_at, plan.announced_at),
             true <- (ticket != nil or plan?) || {:unchanged, plan} do
          now = DateTime.utc_now()
          stamps = if ticket, do: %{announced_at: now, ticket_revised_at: now}, else: %{announced_at: now}
          plan = plan |> ImplementationPlan.changeset(stamps) |> Repo.update!()

          {task, plan, %{ticket: ticket, plan: if(plan?, do: plan.content)}}
        else
          :not_revisable -> nil
          {:unchanged, plan} -> plan
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {%Task{} = task, plan, revised}} ->
        announce(task, run, revised)
        {:ok, plan}

      {:ok, plan} ->
        {:ok, plan}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only a ticket saved since the issue last took one, since Linear rewrites a description's markdown as it reads it.
  # The design section Approve published is the issue's, so it is carried over rather than uploaded again.
  defp publish_ticket(%Task{issue: %Issue{} = issue} = task, since) do
    with %{} = ticket <- Pipeline.read_ticket(task),
         true <- DateTime.compare(ticket.saved_at, DateTime.truncate(since, :second)) != :lt,
         attrs = ticket_attrs(ticket, issue),
         true <- Enum.any?(attrs, fn {field, value} -> Map.fetch!(issue, field) != value end),
         {:ok, issue} <- Issues.update_issue(issue, attrs) do
      {:ok, issue}
    else
      {:error, reason} -> {:error, reason}
      _no_ticket_or_unchanged -> {:ok, nil}
    end
  end

  defp ticket_attrs(ticket, %Issue{description: published}) do
    description =
      case String.split(published || "", @design_heading) do
        [_no_design] -> ticket.description
        parts -> String.trim(ticket.description) <> @design_heading <> List.last(parts)
      end

    Map.reject(
      %{title: ticket.title, description: description, priority: ticket.priority, estimate: ticket.estimate},
      fn {_field, value} -> is_nil(value) end
    )
  end

  defp later?(_revised_at, nil), do: true
  defp later?(revised_at, announced_at), do: DateTime.after?(revised_at, announced_at)

  # After the commit, so Engineer reads the stamped plan and a failed note cannot undo what reached the issue.
  defp announce(%Task{} = task, %Run{} = run, revised) do
    told? = task.stage == :engineer and tell_engineer(task, revised)
    revised_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Pipeline.append_run_events(run.id, nil, ["[plan revision #{revised_at}] #{sentence(revised, told?)}"])
    Pipeline.broadcast_output_saved(task)
  end

  defp tell_engineer(%Task{} = task, revised) do
    {:ok, role} = Roles.get_role(project_id: task.project_id, stage: :engineer)

    engineer =
      Repo.one(
        from r in Run,
          where: r.task_id == ^task.id and r.role_id == ^role.id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1
      )

    Run.can_chat?(engineer) and
      match?(
        {:ok, _delivery, _run},
        Pipeline.send_message(Scope.for_system(), engineer, note(revised), from: :plan_revision)
      )
  end

  defp note(revised) do
    sections =
      Enum.reject(
        [
          revised.plan && "The plan, in full:\n\n#{revised.plan}",
          revised.ticket && "The ticket, in full:\n\n#{format_ticket(revised.ticket)}"
        ],
        &is_nil/1
      )

    Enum.join(["#{changed(revised)} after approval. Build from this from now on." | sections], "\n\n")
  end

  defp changed(%{plan: plan, ticket: nil}) when is_binary(plan), do: "The plan changed"
  defp changed(%{plan: nil}), do: "The ticket changed"
  defp changed(_both), do: "The plan and the ticket changed"

  defp sentence(revised, told?) do
    what =
      case revised do
        %{plan: plan, ticket: nil} when is_binary(plan) -> "Plan"
        %{plan: nil} -> "Ticket"
        _both -> "Plan and ticket"
      end

    went = if told?, do: "#{what} to Engineer", else: "#{what} revised"
    if revised.ticket, do: "#{went}, ticket to Linear", else: went
  end
end
