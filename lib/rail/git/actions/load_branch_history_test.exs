defmodule Rail.Git.Actions.LoadBranchHistoryTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_lbh_1", "identifier" => "LBH-1", "title" => "Load Branch History"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Load Branch History"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    remote = create_temp_git_repo(prefix: "rail_branch_history_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, repo: repo, remote: remote}
  end

  test "the branch's own commits along the first parent, newest first, each labeled by what made it", %{
    task: task,
    repo: repo,
    remote: remote
  } do
    File.write!(Path.join(repo, "a.ex"), "engineer\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Send comments as one round"])

    File.write!(Path.join(remote, "main.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Landed on main"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])

    File.write!(Path.join(repo, "a.ex"), "fixed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Fix 2 findings from round 1\n\nTicket: LBH-1\nRail-Step: Fix round 1"])
    head = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    short = repo |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

    assert [
             %{
               sha: ^head,
               short_sha: ^short,
               subject: "Fix 2 findings from round 1",
               label: "Fix round 1",
               at: %DateTime{}
             },
             %{label: "Merge main"},
             %{subject: "Send comments as one round", label: "Engineer"}
           ] = Git.load_branch_history(task)
  end

  test "a branch git cannot read has no history", %{task: task} do
    assert Git.load_branch_history(%{task | worktree_path: System.tmp_dir!()}) == []
  end
end
