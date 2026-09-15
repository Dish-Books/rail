defmodule Rail.Git.Actions.ExpandDiffGapTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Expand Gap Project",
        github_repo: "org/expand-gap",
        github_installation_id: 47_016,
        linear_workspace: %{
          name: "Expand Gap Workspace",
          external_id: "lin_ws_expand_gap",
          token: "lin_api_token_expand_gap",
          webhook_secret: "whsec_expand_gap"
        },
        linear_team_key: "EXG",
        default_branch: "main",
        clone_path: "/tmp/repos/expand-gap",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_exg_1", "identifier" => "EXG-1", "title" => "Expand Gap"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Expand Gap"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), Enum.map_join(1..10, "", &"line #{&1}\n"))
    File.mkdir_p!(Path.join(repo, "lib"))
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, repo: repo}
  end

  test "reads the unchanged lines across the gap", %{task: task} do
    assert {"tracked.txt:0", lines} = Git.expand_diff_gap(task, "tracked.txt", 0, 3, 5)
    assert Enum.map(lines, & &1.text) == ["line 3", "line 4", "line 5"]
  end

  # A gap is drawn by the same row the hunks around it are, so it carries the
  # same highlighted html they do.
  test "highlights what it read", %{task: task} do
    File.write!(Path.join(task.worktree_path, "thing.ex"), "defmodule Thing do\n  :ok\nend\n")

    assert {"thing.ex:0", [%{html: html}]} = Git.expand_diff_gap(task, "thing.ex", 0, 1, 1)
    assert html =~ ~s(class="l-keyword")
  end

  test "a file it cannot read expands to nothing", %{task: task} do
    assert {"missing.txt:1", []} = Git.expand_diff_gap(task, "missing.txt", 1, 1, 5)
  end

  test "a directory is not a file to read lines out of", %{task: task} do
    assert {"lib:0", []} = Git.expand_diff_gap(task, "lib", 0, 1, 5)
  end

  test "an empty file has no lines to fill a gap with", %{task: task, repo: repo} do
    File.write!(Path.join(repo, "empty.txt"), "")

    assert {"empty.txt:0", []} = Git.expand_diff_gap(task, "empty.txt", 0, 1, 5)
  end

  test "a task whose worktree is gone expands to nothing", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {"tracked.txt:0", []} = Git.expand_diff_gap(task, "tracked.txt", 0, 1, 5)
  end
end
