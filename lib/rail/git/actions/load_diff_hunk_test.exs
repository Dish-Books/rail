defmodule Rail.Git.Actions.LoadDiffHunkTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Users

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Diff Hunk Project",
        github_repo: "org/diff-hunk",
        github_installation_id: 47_029,
        linear_workspace: %{
          name: "Diff Hunk Workspace",
          external_id: "lin_ws_diff_hunk",
          token: "lin_api_token_diff_hunk",
          webhook_secret: "whsec_diff_hunk"
        },
        linear_team_key: "DHK",
        default_branch: "main",
        clone_path: "/tmp/repos/diff-hunk",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_dhk_1", "identifier" => "DHK-1", "title" => "Diff Hunk"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Diff Hunk"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    # Two edits far enough apart to land in hunks of their own.
    repo = create_temp_git_repo()
    lines = Enum.map_join(1..80, "", &"line #{&1}\n")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/example.ex"), lines)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the file before"])
    git!(repo, ["checkout", "-b", "feature"])

    changed =
      Enum.map_join(1..80, "", fn
        5 -> "changed near the top\n"
        70 -> "changed near the bottom\n"
        n -> "line #{n}\n"
      end)

    File.write!(Path.join(repo, "lib/example.ex"), changed)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the change under review"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "gh_diff_hunk", login: "hunk", email: "hunk@example.com"})

    %{scope: user_scope(user: reader), task: task}
  end

  test "returns the hunk holding the line, and counts the rest", %{scope: scope, task: task} do
    assert %{path: "lib/example.ex", other_hunks: 1, rows: rows} =
             Git.load_diff_hunk(scope, task, "lib/example.ex", 70)

    assert Enum.any?(rows, &(&1[:text] =~ "changed near the bottom"))
    refute Enum.any?(rows, &(&1[:text] =~ "changed near the top"))
  end

  test "the other end of the file is the other hunk", %{scope: scope, task: task} do
    assert %{rows: rows} = Git.load_diff_hunk(scope, task, "lib/example.ex", 5)

    assert Enum.any?(rows, &(&1[:text] =~ "changed near the top"))
    refute Enum.any?(rows, &(&1[:text] =~ "changed near the bottom"))
  end

  test "a finding naming only a file gets the first hunk", %{scope: scope, task: task} do
    assert %{rows: rows} = Git.load_diff_hunk(scope, task, "lib/example.ex")

    assert Enum.any?(rows, &(&1[:text] =~ "changed near the top"))
  end

  # A reviewer quotes the path it read, which is not always the one git prints.
  test "a path the reviewer wrote as a suffix still finds its file", %{scope: scope, task: task} do
    assert %{path: "lib/example.ex"} = Git.load_diff_hunk(scope, task, "example.ex", 5)
  end

  test "a line the change never touched still shows the change", %{scope: scope, task: task} do
    assert %{rows: rows} = Git.load_diff_hunk(scope, task, "lib/example.ex", 40)

    assert rows != []
  end

  test "a file the branch never touched has no hunk", %{scope: scope, task: task} do
    assert Git.load_diff_hunk(scope, task, "lib/untouched.ex", 1) == nil
  end

  test "a cleaned-up worktree has no hunk to read", %{scope: scope, task: task} do
    File.rm_rf!(task.worktree_path)

    assert Git.load_diff_hunk(scope, task, "lib/example.ex", 5) == nil
  end

  # A picture has no lines to show, and the pane is handed the fact of it rather
  # than nothing at all.
  test "a file with no lines still says the branch touched it", %{scope: scope, task: task} do
    File.write!(Path.join(task.worktree_path, "logo.png"), <<0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3>>)
    git!(task.worktree_path, ["add", "."])
    git!(task.worktree_path, ["commit", "-m", "a picture"])

    assert %{path: "logo.png", rows: [%{kind: :binary}], other_hunks: 0} =
             Git.load_diff_hunk(scope, task, "logo.png", 1)
  end

  # A file the branch changed without changing a line of it - here made
  # executable - is in the diff with nothing underneath to show.
  test "a file with no content change at all has no hunk", %{scope: scope, task: task} do
    repo = create_temp_git_repo()
    script = Path.join(repo, "script.sh")
    File.write!(script, "echo hello\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the script"])
    git!(repo, ["checkout", "-b", "feature"])
    File.chmod!(script, 0o755)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "made it runnable"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})

    assert Git.load_diff_hunk(scope, task, "script.sh", 1) == nil
  end
end
