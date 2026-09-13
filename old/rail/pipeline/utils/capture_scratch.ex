defmodule Rail.Pipeline.Utils.CaptureScratch do
  @moduledoc """
  Captures what a stage's agent left in its scratch directory back into Postgres and Linear.
  """

  import Rail.Pipeline.Utils.IssueIdentifier

  alias Rail.Artifacts
  alias Rail.Domain.TicketBody
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Captures the outputs `stage` wrote into the task's scratch directory.
  """
  def capture_scratch(stage, %Task{scratch_path: scratch_dir} = task) when is_binary(scratch_dir) do
    identifier = issue_identifier(task)
    scope = Scope.for_system()

    updated_task =
      case stage do
        s when s in [:product, :architect] ->
          task_after_ticket = capture_ticket(task, identifier, scratch_dir)
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

  # The ticket the agent rewrote replaces the issue's title and body. Linear hears
  # about it from the sync the write enqueues, not from here.
  defp capture_ticket(task, identifier, scratch_dir) when is_binary(identifier) and identifier != "" do
    ticket_file = Path.join([scratch_dir, "tickets", "#{identifier}.md"])

    if File.exists?(ticket_file) do
      parsed = ticket_file |> File.read!() |> TicketBody.parse()
      _adopted = task.issue_id && Issue |> Repo.get(task.issue_id) |> adopt_ticket(parsed)
    end

    task
  end

  defp capture_ticket(task, _no_identifier, _scratch_dir), do: task

  defp adopt_ticket(%Issue{} = issue, %TicketBody{} = parsed) do
    Issues.update_issue(issue, %{title: parsed.title, description: parsed.description})
  end

  defp adopt_ticket(nil, _parsed), do: :ok

  defp capture_plan(task, identifier, scratch_dir) do
    candidates = [
      Path.join(scratch_dir, "plan.md"),
      if(is_binary(identifier) and identifier != "", do: Path.join([scratch_dir, "plans", "#{identifier}.md"]))
    ]

    plan_path = Enum.find(candidates, &(&1 && File.exists?(&1)))

    if plan_path do
      content = File.read!(plan_path)

      if String.trim(content) != "" do
        # One plan per task: a second architect pass replaces what the first said.
        existing = Repo.get_by(ImplementationPlan, task_id: task.id) || %ImplementationPlan{}

        existing
        |> ImplementationPlan.changeset(%{content: content, captured_at: DateTime.utc_now()}, task.id)
        |> Repo.insert_or_update!()
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
