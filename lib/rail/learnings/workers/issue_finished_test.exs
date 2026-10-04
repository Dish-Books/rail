defmodule Rail.Learnings.Workers.IssueFinishedTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup %{project: project} do
    %{task: learnings_task(project, "IFN-1")}
  end

  test "a done or canceled issue with a task runs extraction for it", %{task: task} do
    for state <- [:done, :canceled] do
      {:ok, _issue} = Issues.update_issue(task.issue, %{state: state})
      Repo.update_all(from(t in Task, where: t.id == ^task.id), set: [learnings_extracted_at: nil])

      expect(Tools, :run_agent, fn _backend, _argv, opts ->
        File.write!(Path.join(opts[:cd], "result.json"), ~s({"observations": []}))
        {:ok, ""}
      end)

      assert :ok = perform_job(IssueFinished, %{issue_id: task.issue_id})
      assert %Task{learnings_extracted_at: %DateTime{}} = Repo.reload!(task)
    end
  end

  test "a failed pass is retried", %{task: task} do
    expect(Tools, :run_agent, fn _backend, _argv, _opts -> {:error, {:exit, 1}} end)

    assert {:error, {:exit, 1}} = perform_job(IssueFinished, %{issue_id: task.issue_id})
  end

  test "an issue with no task, or that is gone, runs nothing", %{project: project} do
    reject(&Tools.run_agent/3)
    task = learnings_task(project, "IFN-2")
    Repo.delete!(task)

    assert :ok = perform_job(IssueFinished, %{issue_id: task.issue_id})
    assert :ok = perform_job(IssueFinished, %{issue_id: "iss_gone"})
  end

  test "a done issue a promotion opened retires its rule, and a canceled one does not", %{project: project} do
    reject(&Tools.run_agent/3)

    for {state, expected} <- [canceled: :active, done: :retired] do
      promoted = learnings_task(project, "IFN-P-#{state}")
      Repo.delete!(%Task{id: promoted.id})
      rule = learning(project, %{rule: "Broken #{state}", kind: :convention})

      Repo.insert!(%LearningProposal{
        project_id: project.id,
        action: :promote,
        learning_id: rule.id,
        status: :approved,
        issue_id: promoted.issue_id
      })

      {:ok, _issue} = Issues.update_issue(promoted.issue, %{state: state})
      assert :ok = perform_job(IssueFinished, %{issue_id: promoted.issue_id})
      assert %Learning{status: ^expected} = Repo.reload!(rule)
    end
  end
end
