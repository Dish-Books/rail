defmodule Rail.Git.Actions.LoadDiffTest do
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
        name: "Load Diff Project",
        github_repo: "org/load-diff",
        github_installation_id: 47_014,
        linear_workspace: %{
          name: "Load Diff Workspace",
          external_id: "lin_ws_load_diff",
          token: "lin_api_token_load_diff",
          webhook_secret: "whsec_load_diff"
        },
        linear_team_key: "LDF",
        default_branch: "main",
        clone_path: "/tmp/repos/load-diff",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_ldf_1", "identifier" => "LDF-1", "title" => "Load Diff"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Load Diff"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    repo = create_temp_git_repo()
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "shipped.ex"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "committed change"])
    File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "gh_load_diff", login: "reader", email: "reader@example.com"})

    %{scope: user_scope(user: reader), task: task, repo: repo}
  end

  test "the branch view carries everything the branch did", %{scope: scope, task: task} do
    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert files |> Enum.map(& &1.path) |> Enum.sort() == ["shipped.ex", "wip.ex"]
  end

  test "the uncommitted view carries only what is not committed", %{scope: scope, task: task} do
    assert {:ok, [%{path: "wip.ex"}]} = Git.load_diff(scope, task, :uncommitted)
  end

  test "every file comes back with the rows that draw it", %{scope: scope, task: task} do
    assert {:ok, files} = Git.load_diff(scope, task, :branch)
    shipped = Enum.find(files, &(&1.path == "shipped.ex"))

    assert shipped.additions == 1
    assert shipped.display_path == "shipped.ex"
    assert [%{kind: :hunk_header}, %{kind: :line, line_kind: :added, text: "committed"}] = shipped.rows
  end

  # Deleted lines are highlighted against the old file and added ones against the
  # new, because the two sides interleaved are not code anything can parse.
  test "the rows come back highlighted, each side as its own code", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "thing.ex"), "defmodule Thing do\n  :was\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "thing"])
    File.write!(Path.join(repo, "thing.ex"), "defmodule Thing do\n  :is\nend\n")

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)
    rows = files |> Enum.find(&(&1.path == "thing.ex")) |> Map.fetch!(:rows)

    assert %{html: was} = Enum.find(rows, &(&1[:line_kind] == :deleted))
    assert %{html: is} = Enum.find(rows, &(&1[:line_kind] == :added))
    assert was =~ ":was"
    assert is =~ ":is"
    assert is =~ "l-string-special-symbol"
  end

  test "a file in a language nothing here highlights comes back as its plain text", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "notes.txt"), "just prose\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)
    rows = files |> Enum.find(&(&1.path == "notes.txt")) |> Map.fetch!(:rows)

    assert %{text: "just prose", html: nil} = Enum.find(rows, &(&1[:line_kind] == :added))
  end

  test "untracked files are written into the diff git would not write them into", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "brand_new.ex"), "one\ntwo\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)
    new_file = Enum.find(files, &(&1.path == "brand_new.ex"))

    assert new_file.status == :added
    assert [%{kind: :hunk_header, text: "@@ -0,0 +1,2 @@"}, %{text: "one"}, %{text: "two"}] = new_file.rows
  end

  test "an untracked binary file is named rather than drawn", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "logo.png"), <<137, 80, 78, 71, 0, 1, 2>>)

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{binary?: true, rows: [%{kind: :binary}]} = Enum.find(files, &(&1.path == "logo.png"))
  end

  test "an empty untracked file is added with no lines in it", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "empty.ex"), "")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{rows: [%{kind: :hunk_header, text: "@@ -0,0 +1,0 @@"}]} = Enum.find(files, &(&1.path == "empty.ex"))
  end

  test "the agents' own scratch is not part of the diff", %{scope: scope, task: task, repo: repo} do
    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/notes.md"), "scratch\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    refute Enum.any?(files, &String.starts_with?(&1.path, ".rail"))
  end

  # Nothing has forked from the base yet, so there is no merge base to diff from.
  test "a branch with no merge base falls back to what is uncommitted", %{scope: scope, task: task, repo: repo} do
    git!(repo, ["checkout", "--orphan", "unrelated"])
    File.write!(Path.join(repo, "tracked.txt"), "changed\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert Enum.any?(files, &(&1.path == "wip.ex"))
  end

  test "a worktree that is not a repository shows nothing rather than failing", %{scope: scope, task: task} do
    loose = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: loose})

    assert {:ok, []} = Git.load_diff(scope, task, :branch)
  end

  # git lists a dangling symlink as untracked, and then there is nothing to read.
  test "an untracked file that cannot be read contributes nothing", %{scope: scope, task: task, repo: repo} do
    File.ln_s!("nowhere", Path.join(repo, "dangling.ex"))

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    refute Enum.any?(files, &(&1.path == "dangling.ex"))
  end

  test "a task whose worktree is gone has no diff to read", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {:error, :no_worktree} = Git.load_diff(scope, task)
  end

  test "a file is read only while it still looks the way it did", %{scope: scope, task: task} do
    {:ok, files} = Git.load_diff(scope, task, :branch)
    shipped = Enum.find(files, &(&1.path == "shipped.ex"))
    refute shipped.viewed?

    {:ok, _marked} = Git.set_file_viewed(scope, task, shipped.path, shipped.digest, true)

    {:ok, files} = Git.load_diff(scope, task, :branch)
    assert Enum.find(files, &(&1.path == "shipped.ex")).viewed?

    {:ok, _moved} = Git.set_file_viewed(scope, task, shipped.path, "a_stale_digest", true)

    {:ok, files} = Git.load_diff(scope, task, :branch)
    refute Enum.find(files, &(&1.path == "shipped.ex")).viewed?
  end
end
