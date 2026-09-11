defmodule Rail.Pipeline.Utils.Scratch do
  @moduledoc """
  Utilities for preparing and capturing `$RAIL_SCRATCH` directory artifacts for agent tasks.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports, only: [collect_report_entries: 1]

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @subdirs ["tickets", "plans", "design", "qa", "demo"]

  @doc """
  Prepares `$RAIL_SCRATCH` directory tree and materializes stage-specific inputs.
  """
  def prepare(%Task{} = task, scratch_dir) when is_binary(scratch_dir) do
    ensure_directories(scratch_dir)

    identifier = resolve_identifier(task)
    scope = Scope.for_system()

    case normalize_stage(task.stage) do
      stage when stage in [:product, :architect] ->
        maybe_write_ticket(task, identifier, scratch_dir)
        maybe_materialize_design(scope, task, scratch_dir, stage)

      :design ->
        maybe_materialize_design(scope, task, scratch_dir, :design)

      :engineer ->
        write_engineer_plan(task, identifier, scratch_dir)
        maybe_write_outstanding_reports(task, scratch_dir)

      :qa_lead ->
        maybe_materialize_qa(scope, task, scratch_dir)

      _other_stage ->
        :ok
    end

    {:ok, scratch_dir}
  end

  @doc """
  Captures stage outputs from `$RAIL_SCRATCH` back into Postgres and Linear.
  """
  def capture(stage, %Task{} = task, scratch_dir) when is_binary(scratch_dir) do
    stage_atom = normalize_stage(stage)
    identifier = resolve_identifier(task)
    scope = Scope.for_system()

    updated_task =
      case stage_atom do
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

  @doc """
  Computes the default scratch directory path for a task.
  """
  def default_scratch_path(project_or_id, task_or_id) do
    project_id = extract_id(project_or_id)
    task_id = extract_id(task_or_id)

    workspace_root =
      System.get_env("RAIL_WORKSPACE_ROOT") ||
        Path.join(System.tmp_dir!(), "rail")

    Path.join([workspace_root, project_id, "scratch", task_id])
  end

  @doc """
  Resolves the Linear issue identifier for a task.
  """
  def resolve_identifier(%Task{issue: %Issue{identifier: id}}) when is_binary(id) and id != "", do: id

  def resolve_identifier(%Task{issue_id: issue_id}) when is_binary(issue_id) do
    case Repo.get(Issue, issue_id) do
      %Issue{identifier: id} -> id
      nil -> nil
    end
  end

  def resolve_identifier(_other), do: nil

  defp ensure_directories(scratch_dir) do
    File.mkdir_p!(scratch_dir)

    Enum.each(@subdirs, fn sub ->
      scratch_dir |> Path.join(sub) |> File.mkdir_p!()
    end)
  end

  defp maybe_write_ticket(%Task{} = task, identifier, scratch_dir) when is_binary(identifier) and identifier != "" do
    issue = task.issue_id && Repo.get(Issue, task.issue_id)

    content =
      TicketBody.format(%TicketBody{
        title: (issue && issue.title) || "",
        description: (issue && issue.description) || "",
        priority: issue && issue.priority,
        estimate: issue && issue.estimate
      })

    dest_path = Path.join([scratch_dir, "tickets", "#{identifier}.md"])
    File.write!(dest_path, content)
  end

  defp maybe_write_ticket(_task, _identifier, _scratch_dir), do: :ok

  defp maybe_materialize_design(scope, task, scratch_dir, :architect) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :design, only_picked: true, stage: :architect)
    :ok
  end

  defp maybe_materialize_design(scope, task, scratch_dir, :design) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :design)
    :ok
  end

  defp maybe_materialize_design(_scope, _task, _scratch_dir, _other), do: :ok

  defp write_engineer_plan(task, identifier, scratch_dir) do
    plan_content =
      case Repo.one(from p in Plan, where: p.task_id == ^task.id, order_by: [desc: p.captured_at], limit: 1) do
        %Plan{content: content} when is_binary(content) and content != "" ->
          content

        _none ->
          TicketBody.split(issue_description(task) || "").plan
      end

    if is_binary(plan_content) and plan_content != "" do
      File.write!(Path.join(scratch_dir, "plan.md"), plan_content)

      if is_binary(identifier) and identifier != "" do
        File.write!(Path.join([scratch_dir, "plans", "#{identifier}.md"]), plan_content)
      end
    end

    :ok
  end

  defp maybe_write_outstanding_reports(%Task{outstanding_reports: reports} = task, scratch_dir)
       when is_list(reports) and reports != [] do
    entries = collect_report_entries(task)

    if entries != [] do
      sections =
        Enum.map(entries, fn {_role_id, role_name, output} ->
          "### #{role_name}\n\n#{output}"
        end)

      content = "# Outstanding Gate Reports\n\n" <> Enum.join(sections, "\n\n") <> "\n"
      File.write!(Path.join(scratch_dir, "outstanding_reports.md"), content)
    end

    :ok
  end

  defp maybe_write_outstanding_reports(_task, _scratch_dir), do: :ok

  defp maybe_materialize_qa(scope, task, scratch_dir) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :qa)
    :ok
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

  defp issue_description(%Task{issue_id: issue_id}) when is_binary(issue_id) do
    case Repo.get(Issue, issue_id) do
      %Issue{description: description} -> description
      nil -> nil
    end
  end

  defp issue_description(%Task{}), do: nil

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

  defp extract_id(%{id: id}), do: to_string(id)
  defp extract_id(id) when is_binary(id), do: id
  defp extract_id(other), do: to_string(other)

  defp normalize_stage(stage) when is_atom(stage), do: stage

  defp normalize_stage(stage) when is_binary(stage) do
    case Task.cast_stage(stage) do
      {:ok, atom_val} -> atom_val
      _error -> nil
    end
  end

  defp normalize_stage(_other), do: nil
end
