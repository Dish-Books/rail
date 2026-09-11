defmodule Rail.Pipeline.Utils.PrepareScratch do
  @moduledoc """
  Materializes the inputs a stage's agent reads out of the task's scratch directory.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports
  import Rail.Pipeline.Utils.IssueIdentifier

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @subdirs ["tickets", "plans", "design", "qa", "demo"]

  @doc """
  Prepares the scratch tree for `task` and writes its stage's inputs.
  """
  def prepare_scratch(%Task{scratch_path: scratch_dir} = task) when is_binary(scratch_dir) do
    ensure_directories(scratch_dir)

    identifier = issue_identifier(task)
    scope = Scope.for_system()

    case task.stage do
      :product ->
        maybe_write_ticket(task, identifier, scratch_dir)

      :architect ->
        maybe_write_ticket(task, identifier, scratch_dir)
        materialize_design(scope, task, scratch_dir, :architect)

      :design ->
        materialize_design(scope, task, scratch_dir, :design)

      :engineer ->
        write_engineer_plan(task, identifier, scratch_dir)
        maybe_write_outstanding_reports(task, scratch_dir)

      :qa_lead ->
        materialize_qa(scope, task, scratch_dir)

      _other_stage ->
        :ok
    end

    {:ok, scratch_dir}
  end

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

  defp materialize_design(scope, task, scratch_dir, :architect) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :design, only_picked: true, stage: :architect)
    :ok
  end

  defp materialize_design(scope, task, scratch_dir, :design) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :design)
    :ok
  end

  defp write_engineer_plan(task, identifier, scratch_dir) do
    case Repo.one(from p in Plan, where: p.task_id == ^task.id, order_by: [desc: p.captured_at], limit: 1) do
      %Plan{content: content} when is_binary(content) and content != "" ->
        File.write!(Path.join(scratch_dir, "plan.md"), content)

        if is_binary(identifier) and identifier != "" do
          File.write!(Path.join([scratch_dir, "plans", "#{identifier}.md"]), content)
        end

      _none ->
        :ok
    end

    :ok
  end

  defp maybe_write_outstanding_reports(%Task{outstanding_reports: reports} = task, scratch_dir)
       when is_list(reports) and reports != [] do
    case carried_reports(task) do
      "" ->
        :ok

      block ->
        content = "# Outstanding Gate Reports" <> block <> "\n"
        File.write!(Path.join(scratch_dir, "outstanding_reports.md"), content)
    end

    :ok
  end

  defp maybe_write_outstanding_reports(_task, _scratch_dir), do: :ok

  defp materialize_qa(scope, task, scratch_dir) do
    _result = Artifacts.materialize(scope, task, scratch_dir, kind: :qa)
    :ok
  end
end
