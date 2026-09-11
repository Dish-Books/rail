defmodule Rail.Pipeline.Utils.CaptureScratch do
  @moduledoc """
  Captures what a stage's agent left in `$RAIL_SCRATCH` back into Postgres and Linear.
  """

  import Rail.Pipeline.Utils.IssueIdentifier

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Captures the outputs `stage` wrote into `scratch_dir` for `task`.
  """
  def capture_scratch(stage, %Task{} = task, scratch_dir) when is_binary(scratch_dir) do
    identifier = issue_identifier(task)
    scope = Scope.for_system()

    updated_task =
      case stage do
        s when s in [:product, :architect] ->
          task_after_ticket = capture_ticket_and_splits(scope, task, identifier, scratch_dir)
          if s == :architect, do: capture_plan(task_after_ticket, identifier, scratch_dir)
          task_after_ticket

        :design ->
          maybe_capture_design(scope, task, scratch_dir)
          task

        :qa ->
          maybe_capture_qa(scope, task, scratch_dir)
          task

        :demo ->
          maybe_capture_demo(scope, task, scratch_dir)
          task

        _other ->
          task
      end

    {:ok, updated_task}
  end

  defp capture_ticket_and_splits(scope, task, identifier, scratch_dir) do
    project = Repo.get!(Project, task.project_id)
    issue = task.issue_id && Repo.get(Issue, task.issue_id)
    owner_user = issue && issue.owner_user_id && %{id: issue.owner_user_id}

    task =
      if is_binary(identifier) and identifier != "" do
        ticket_file = Path.join([scratch_dir, "tickets", "#{identifier}.md"])

        if File.exists?(ticket_file) do
          content = File.read!(ticket_file)
          _push_res = Issues.push_ticket(scope, project, identifier, content, owner_user)
          parsed = TicketBody.parse(content)
          _adopted = adopt_ticket(issue, parsed, project)

          task
        else
          task
        end
      else
        task
      end

    split_files = Path.wildcard(Path.join([scratch_dir, "tickets", "split-*.md"]))

    if split_files != [] do
      split_contents = Enum.map(split_files, &File.read!/1)
      _create_splits_res = Issues.create_split_issues(scope, project, split_contents, owner_user)
    end

    task
  end

  # The ticket the agent wrote replaces the issue's own title and body: the task
  # keeps no copy of either.
  defp adopt_ticket(%Issue{} = issue, %TicketBody{} = parsed, %Project{} = project) do
    issue
    |> Issue.changeset(%{title: parsed.title, description: parsed.description}, project.id)
    |> Repo.update()
  end

  defp adopt_ticket(nil, _parsed, _project), do: :ok

  defp capture_plan(task, identifier, scratch_dir) do
    candidates = [
      Path.join(scratch_dir, "plan.md"),
      if(is_binary(identifier) and identifier != "", do: Path.join([scratch_dir, "plans", "#{identifier}.md"]))
    ]

    plan_path = Enum.find(candidates, &(&1 && File.exists?(&1)))

    if plan_path do
      content = File.read!(plan_path)

      if String.trim(content) != "" do
        %Plan{}
        |> Plan.changeset(%{content: content, captured_at: DateTime.utc_now()}, task.id)
        |> Repo.insert!()
      end
    end
  end

  defp maybe_capture_design(scope, task, scratch_dir) do
    manifest_path = Path.join([scratch_dir, "design", "manifest.json"])

    if File.exists?(manifest_path) do
      Artifacts.capture_design(scope, task, scratch_dir)
    end
  end

  defp maybe_capture_qa(scope, task, scratch_dir) do
    qa_path =
      cond do
        File.exists?(Path.join([scratch_dir, "qa", "manifest.json"])) ->
          Path.join(scratch_dir, "qa")

        File.exists?(Path.join(scratch_dir, "manifest.json")) ->
          scratch_dir

        true ->
          nil
      end

    if qa_path do
      Artifacts.capture_qa_report(scope, task, qa_path)
    end
  end

  defp maybe_capture_demo(scope, task, scratch_dir) do
    manifest_path = Path.join([scratch_dir, "demo", "manifest.json"])

    if File.exists?(manifest_path) do
      Artifacts.capture_demo(scope, task, scratch_dir)
    end
  end
end
