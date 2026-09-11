defmodule Rail.Pipeline.Actions.ApproveProductTask do
  @moduledoc """
  Approves the ticket a product run wrote and hands the task to design.

  The product run writes its ticket into scratch and nothing else. Everything that
  makes the ticket real happens here: Linear gets the ticket body, tickets the run
  split out are opened as new issues, the task adopts the approved title and
  description, and the design stage starts.
  """

  import Rail.Pipeline.Utils.ScratchPath

  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Approves the product stage of `task_or_id` and starts its design stage.

  Requires the task to be at `:product` and `:awaiting_approval`. Returns whatever
  `start_design_task/2` returns, or `{:ok, %{task: task}}` with the task queued for the
  architect stage when the project has no design role. Returns `{:error, reason}`, with
  the reason recorded on the task, when the ticket cannot be published.
  """
  def approve_product_task(task_or_id, opts \\ []) when is_list(opts) do
    with %Task{} = task <- resolve_task(task_or_id),
         :ok <- approvable(task),
         {:ok, %Issue{} = issue} <- issue_for(task),
         {:ok, task} <- publish(task, issue, opts) do
      Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :product_approved})
      hand_off(task, opts)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # A project with no design role has nothing to design with, so the task queues for the
  # architect stage the dispatcher already knows how to run.
  defp hand_off(%Task{} = task, opts) do
    case Roles.get_role(project_id: task.project_id, stage: :design) do
      {:ok, %Role{}} ->
        Pipeline.start_design_task(task, opts)

      _no_designer ->
        {:ok, task} =
          task
          |> Task.changeset(%{stage: :architect, stage_state: :queued, retry_after: nil, error: nil})
          |> Repo.update()

        Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :stage_approved})
        Dispatcher.pump()

        {:ok, %{task: task}}
    end
  end

  defp approvable(%Task{stage: stage}) when stage != :product, do: {:error, {:invalid_stage, stage}}
  defp approvable(%Task{stage_state: :awaiting_approval}), do: :ok
  defp approvable(%Task{stage_state: state}), do: {:error, {:invalid_stage_state, state}}

  defp issue_for(%Task{issue: %Issue{} = issue}), do: {:ok, issue}

  defp issue_for(%Task{} = task) do
    fail(task, "This task has no Linear issue, so there is nowhere to publish the ticket.", :no_issue)
  end

  # Linear

  defp publish(%Task{project: %Project{} = project} = task, %Issue{} = issue, opts) do
    scratch_path = resolve_scratch_path(project, task, opts)
    ticket_file = Path.join([scratch_path, "tickets", "#{issue.identifier}.md"])

    if File.exists?(ticket_file) do
      content = File.read!(ticket_file)

      case Issues.push_ticket(Scope.for_system(), project, issue.identifier, content, owner_user(issue)) do
        {:ok, _issue} ->
          create_splits(project, task, scratch_path)
          adopt_ticket(task, issue, content)

        {:error, reason} ->
          reason_text = if is_binary(reason), do: reason, else: inspect(reason)
          fail(task, "Failed to publish the ticket: #{reason_text}", {:push_failed, reason})
      end
    else
      fail(task, "The product run left no ticket at #{ticket_file}.", :no_ticket)
    end
  end

  defp create_splits(%Project{} = project, %Task{} = task, scratch_path) do
    case Path.wildcard(Path.join([scratch_path, "tickets", "split-*.md"])) do
      [] ->
        :ok

      files ->
        contents = Enum.map(files, &File.read!/1)
        _created = Issues.create_split_issues(Scope.for_system(), project, contents, owner_user(task.issue))
        :ok
    end
  end

  # The ticket the product agent wrote replaces the issue's title and body; the
  # task only clears its own error.
  defp adopt_ticket(%Task{project: %Project{} = project} = task, %Issue{} = issue, content) do
    ticket = TicketBody.parse(content)

    {:ok, _issue} =
      issue
      |> Issue.changeset(%{title: ticket.title, description: ticket.description}, project.id)
      |> Repo.update()

    task |> Task.changeset(%{error: nil}) |> Repo.update()
  end

  defp fail(%Task{} = task, message, reason) do
    {:ok, _task} = task |> Task.changeset(%{error: message}) |> Repo.update()
    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :product_approval_failed})
    {:error, reason}
  end

  defp resolve_scratch_path(%Project{} = project, %Task{} = task, opts) do
    Keyword.get(opts, :scratch_dir) ||
      Keyword.get(opts, :scratch_path) ||
      scratch_path(project.id, task.id)
  end

  defp owner_user(%Issue{owner_user_id: user_id}) when is_binary(user_id), do: %{id: user_id}
  defp owner_user(_issue), do: nil

  # The project and the issue are carried on the task from here on: every step below
  # needs them, and none of them should be refetching either.
  defp resolve_task(%Task{} = task), do: Repo.preload(task, [:project, :issue])
  defp resolve_task(id) when is_binary(id), do: Task |> Repo.get(id) |> resolve_task()
  defp resolve_task(_other), do: nil
end
