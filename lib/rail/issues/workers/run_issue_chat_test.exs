defmodule Rail.Issues.Workers.RunIssueChatTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.RunIssueChat
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Users

  test "an issue that is gone has nothing to run" do
    reject(Tools, :run_agent, 3)
    assert :ok = perform_job(RunIssueChat, %{"issue_id" => "iss_gone"})
  end

  test "runs the agent once on the issue" do
    stub(Git, :checkout_detached_worktree, fn _project, worktree_path -> {:ok, worktree_path} end)
    stub(Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    %{project: project} = triage_project()
    {:ok, %{id: issue_id} = issue} = Issues.create_issue(system_scope(), project, %{title: "Up next"})
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "icw_#{unique}", login: "icw_#{unique}", email: "icw_#{unique}@example.com"})

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, _line} = Issues.send_issue_chat(Scope.for_user(user), issue, %{"text" => "Make it 2 points."})

    expect(Tools, :run_agent, fn _role, _argv, _opts ->
      [Rail.scratch_root(), project.id, "issue-chat", issue_id, "result.json"]
      |> Path.join()
      |> File.write!(Jason.encode!(%{"message" => "Set it to 2 points.", "ticket" => %{"estimate" => 2}}))

      {:ok, ""}
    end)

    assert :ok = perform_job(RunIssueChat, %{"issue_id" => issue_id})
    assert %Issue{estimate: 2, chat_requested_at: nil} = Repo.get!(Issue, issue_id)
  end
end
