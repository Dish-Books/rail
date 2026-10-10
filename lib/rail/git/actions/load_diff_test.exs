defmodule Rail.Git.Actions.LoadDiffTest do
  use Rail.DataCase, async: true

  import Rail.Git.Utils.HighlightLines

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Users

  setup %{project: project} do
    scope = system_scope()

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

    remote = create_temp_git_repo(prefix: "rail_load_diff_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "shipped.ex"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "committed change"])
    File.write!(Path.join(repo, "wip.ex"), "uncommitted\n")

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, reader} =
      Users.register_oauth_user(%{github_id: "gh_load_diff", login: "reader", email: "reader@example.com"})

    %{scope: user_scope(user: reader), task: task, repo: repo, remote: remote}
  end

  test "the branch view carries everything the branch did", %{scope: scope, task: task} do
    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert files |> Enum.map(& &1.path) |> Enum.sort() == ["shipped.ex", "wip.ex"]
  end

  # The clone's own main stays where the branch forked; only origin's moves on.
  test "a branch with a newer main merged in shows only what the branch did", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote
  } do
    File.write!(Path.join(remote, "upstream.ex"), "theirs\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert files |> Enum.map(& &1.path) |> Enum.sort() == ["shipped.ex", "wip.ex"]
  end

  test "the uncommitted view carries only what is not committed", %{scope: scope, task: task} do
    assert {:ok, [%{path: "wip.ex"}]} = Git.load_diff(scope, task, :uncommitted)
  end

  test "a commit's view holds only what that commit changed, against its first parent", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "shipped.ex"), "committed\nagain\n")
    File.write!(Path.join(repo, "later.ex"), "defmodule Later do\nend\n")
    git!(repo, ["add", "shipped.ex", "later.ex"])
    git!(repo, ["commit", "-m", "later change"])
    File.write!(Path.join(repo, "later.ex"), "defmodule Later do\n  :moved_on\nend\n")
    sha = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, [later, shipped]} = Git.load_diff(scope, task, {:commit, sha})

    assert %{path: "later.ex", rows: [_header, %{text: "defmodule Later do", html: html}, %{text: "end"}]} = later
    assert html =~ "l-keyword"
    assert %{path: "shipped.ex", additions: 1, rows: [_header, %{line_kind: :context}, %{text: "again"}]} = shipped
  end

  # A merge's first parent is the branch before it, so its view is what main brought in.
  test "a merge's view is what the default branch brought in", %{scope: scope, task: task, repo: repo, remote: remote} do
    File.write!(Path.join(remote, "upstream.ex"), "theirs\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])
    sha = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, [%{path: "upstream.ex", status: :added}]} = Git.load_diff(scope, task, {:commit, sha})
  end

  test "a commit name that is not a commit shows nothing, and is never handed to git as an option", %{
    scope: scope,
    task: task
  } do
    test_pid = self()

    stub(Tools, :run, fn executable, args, opts ->
      send(test_pid, {:ran, args})
      call_original(Tools, :run, [executable, args, opts])
    end)

    assert {:ok, []} = Git.load_diff(scope, task, {:commit, "--output=/tmp/x"})
    assert {:ok, []} = Git.load_diff(scope, task, {:commit, "0000000000"})
    refute_received {:ran, ["diff", "--output=/tmp/x^1" | _rest]}
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

  # The highlighter reads a whole file, so a hunk that opens partway through a
  # heredoc must be handed the lines above it.
  test "a hunk that begins inside a heredoc colors its tail as the heredoc and what follows as code", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    doc = ["defmodule Thing do", ~s(  @moduledoc """), "  one", "  two", "  three", "  four"]

    File.write!(
      Path.join(repo, "thing.ex"),
      Enum.join(doc ++ ["  five", ~s(  """), "", "  def run, do: :ok", "end\n"], "\n")
    )

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "thing"])

    File.write!(
      Path.join(repo, "thing.ex"),
      Enum.join(doc ++ ["  FIVE", ~s(  """), "", "  def run, do: :ok", "end\n"], "\n")
    )

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)
    rows = files |> Enum.find(&(&1.path == "thing.ex")) |> Map.fetch!(:rows)

    assert [_header, %{text: "  two", html: tail} | _rest] = rows
    assert %{html: code} = Enum.find(rows, &(&1[:text] == "  def run, do: :ok"))
    assert tail =~ "l-comment"
    assert code =~ "l-keyword-function"
    refute code =~ "l-comment"
  end

  test "a hunk that ends inside a heredoc leaves the next hunk of the file colored as code", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    doc = [~s(  @doc """), "  a", "  b", "  c", "  d", "  e", "  f", "  g", ~s(  """), "  def second, do: 2", ""]
    tail = ["  def third, do: 3", ""]
    was = ["defmodule Thing do", "  def first, do: 1"] ++ doc ++ tail ++ ["  def fourth, do: 4", "end\n"]
    File.write!(Path.join(repo, "thing.ex"), Enum.join(was, "\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "thing"])
    is = ["defmodule Thing do", "  def first, do: :one"] ++ doc ++ tail ++ ["  def fourth, do: :four", "end\n"]
    File.write!(Path.join(repo, "thing.ex"), Enum.join(is, "\n"))

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)
    rows = files |> Enum.find(&(&1.path == "thing.ex")) |> Map.fetch!(:rows)

    assert [%{kind: :hunk_header}, %{kind: :hunk_header}] = Enum.filter(rows, &(&1.kind == :hunk_header))

    for text <- ["  def third, do: 3", "  def fourth, do: :four"] do
      assert %{html: html} = Enum.find(rows, &(&1[:text] == text))
      assert html =~ "l-keyword-function"
      refute html =~ "l-comment"
    end
  end

  # The old side is the file at the diff's base, read at its old name, and the
  # base is the merge base rather than HEAD once a newer main is merged in.
  test "a deleted line is colored against the file as it was and an added one against the file as it is", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote
  } do
    doc = [~s(  @moduledoc """), "  one", "  two", "  three", "  four"]

    File.write!(
      Path.join(remote, "was.ex"),
      Enum.join(["defmodule Was do"] ++ doc ++ ["  def was, do: 1", ~s(  """), "end\n"], "\n")
    )

    File.write!(
      Path.join(remote, "is.ex"),
      Enum.join(["defmodule Is do"] ++ doc ++ [~s(  """), "  def was, do: 1", "end\n"], "\n")
    )

    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])
    git!(repo, ["mv", "was.ex", "renamed.ex"])

    File.write!(
      Path.join(repo, "renamed.ex"),
      Enum.join(["defmodule Was do"] ++ doc ++ [~s(  """), "  def is, do: 1", "end\n"], "\n")
    )

    File.write!(
      Path.join(repo, "is.ex"),
      Enum.join(["defmodule Is do"] ++ doc ++ ["  def is, do: 1", ~s(  """), "end\n"], "\n")
    )

    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the change"])

    assert {:ok, files} = Git.load_diff(scope, task, :branch)
    assert %{display_path: "was.ex → renamed.ex", rows: renamed} = Enum.find(files, &(&1.path == "renamed.ex"))
    assert %{rows: is} = Enum.find(files, &(&1.path == "is.ex"))

    assert %{html: inside_was} = Enum.find(renamed, &(&1[:line_kind] == :deleted))
    assert %{html: outside_is} = Enum.find(renamed, &(&1[:line_kind] == :added))
    assert %{html: outside_was} = Enum.find(is, &(&1[:line_kind] == :deleted))
    assert %{html: inside_is} = Enum.find(is, &(&1[:line_kind] == :added))
    assert inside_was =~ "l-comment"
    assert inside_is =~ "l-comment"
    assert outside_was =~ "l-keyword-function"
    assert outside_is =~ "l-keyword-function"
    refute outside_was =~ "l-comment"
    refute outside_is =~ "l-comment"
  end

  # Context rows take the new side's colors, so an old file read for them is thrown away.
  test "a file with nothing deleted never reads its old side", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "grown.ex"), "defmodule Grown do\n  def one, do: 1\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "grown"])
    File.write!(Path.join(repo, "grown.ex"), "defmodule Grown do\n  def one, do: 1\n  def two, do: 2\nend\n")
    test_pid = self()

    stub(Tools, :run, fn
      "git", ["cat-file" | _rest] = args, opts ->
        send(test_pid, :read_old_side)
        call_original(Tools, :run, ["git", args, opts])

      executable, args, opts ->
        call_original(Tools, :run, [executable, args, opts])
    end)

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)

    assert %{rows: rows} = Enum.find(files, &(&1.path == "grown.ex"))
    assert %{html: added} = Enum.find(rows, &(&1[:line_kind] == :added))
    assert %{html: context} = Enum.find(rows, &(&1[:line_kind] == :context))
    assert added =~ "l-keyword-function"
    assert context =~ "l-keyword"
    refute_received :read_old_side
  end

  test "a file whose hunks touch nothing that spans lines is colored as its hunk lines are", %{
    scope: scope,
    task: task,
    repo: repo,
    remote: remote
  } do
    was = Enum.map(1..20, &"  def f#{&1}, do: #{&1}")
    File.write!(Path.join(remote, "plain.ex"), Enum.join(["defmodule Plain do" | was], "\n") <> "\nend\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream change"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])
    committed = List.replace_at(was, 5, "  def f6, do: :six")
    File.write!(Path.join(repo, "plain.ex"), Enum.join(["defmodule Plain do" | committed], "\n") <> "\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "six"])
    uncommitted = List.replace_at(committed, 14, "  def f15, do: :fifteen")
    File.write!(Path.join(repo, "plain.ex"), Enum.join(["defmodule Plain do" | uncommitted], "\n") <> "\nend\n")

    for filter <- [:branch, :uncommitted] do
      assert {:ok, files} = Git.load_diff(scope, task, filter)
      lines = files |> Enum.find(&(&1.path == "plain.ex")) |> Map.fetch!(:rows) |> Enum.filter(&(&1.kind == :line))
      new = Enum.reject(lines, &(&1.line_kind == :deleted))
      old = Enum.reject(lines, &(&1.line_kind == :added))

      assert Enum.map(new, & &1.html) == new |> Enum.map(& &1.text) |> highlight_lines("plain.ex")

      assert old |> Enum.filter(&(&1.line_kind == :deleted)) |> Enum.map(& &1.html) ==
               old
               |> Enum.map(& &1.text)
               |> highlight_lines("plain.ex")
               |> Enum.zip(old)
               |> Enum.filter(fn {_html, row} -> row.line_kind == :deleted end)
               |> Enum.map(fn {html, _row} -> html end)
    end
  end

  # A file the highlighter cannot take whole is colored from its hunk lines, as
  # though nothing else were in it.
  test "a file that is not text outside its hunks still comes back colored", %{scope: scope, task: task, repo: repo} do
    body = Enum.map_join(1..12, "", &"  def f#{&1}, do: #{&1}\n")
    File.write!(Path.join(repo, "latin.ex"), <<"# caf", 0xE9, "\ndefmodule Latin do\n", body::binary, "end\n">>)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "latin-1"])

    File.write!(
      Path.join(repo, "latin.ex"),
      <<"# caf", 0xE9, "\ndefmodule Latin do\n", body::binary, "  def f13, do: 13\nend\n">>
    )

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)

    assert %{binary?: false, rows: rows} = Enum.find(files, &(&1.path == "latin.ex"))
    assert %{text: "  def f13, do: 13", html: html} = Enum.find(rows, &(&1[:line_kind] == :added))
    assert html =~ "l-keyword-function"
  end

  # A symlink's diff is the path it points at, which is not what reading it gives.
  test "a file that does not read as the diff shows it is colored from the diff's own lines", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "linked.ex"), "defmodule Linked do\nend\n")
    File.write!(Path.join(repo, "dangling.ex"), "defmodule Dangling do\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "links"])
    File.rm!(Path.join(repo, "linked.ex"))
    File.ln_s!("shipped.ex", Path.join(repo, "linked.ex"))
    File.rm!(Path.join(repo, "dangling.ex"))
    File.ln_s!("nowhere.ex", Path.join(repo, "dangling.ex"))

    assert {:ok, files} = Git.load_diff(scope, task, :uncommitted)
    added = files |> Enum.flat_map(& &1.rows) |> Enum.filter(&(&1[:line_kind] == :added))

    assert [%{text: "nowhere.ex", html: nowhere}, %{text: "shipped.ex", html: shipped}] = Enum.sort_by(added, & &1.text)
    assert nowhere =~ "nowhere"
    assert shipped =~ "shipped"
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

  # Bytes that are not text cannot be sent to the browser as lines, so a file
  # with no NUL in it is still binary when it is not valid UTF-8.
  test "an untracked file that is not text is named rather than drawn", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "blob.bin"), <<0x82, 0xFF, 0x41, ?\n>>)

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{binary?: true, status: :added, rows: [%{kind: :binary}]} = Enum.find(files, &(&1.path == "blob.bin"))
  end

  # git prints a text file's bytes as they are, and bytes that are not UTF-8
  # cannot be sent to the browser as lines.
  test "a committed file that is not text is named rather than drawn", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "menu.csv"), <<"caf", 0xE9, "\n">>)
    git!(repo, ["add", "menu.csv"])
    git!(repo, ["commit", "-m", "latin-1"])

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{binary?: true, status: :added, additions: 0, deletions: 0, rows: [%{kind: :binary}]} =
             Enum.find(files, &(&1.path == "menu.csv"))
  end

  test "an empty untracked file is added with no lines in it", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "empty.ex"), "")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{rows: [%{kind: :hunk_header, text: "@@ -0,0 +1,0 @@"}]} = Enum.find(files, &(&1.path == "empty.ex"))
  end

  test "a new file under .rail is part of the diff, like any other", %{scope: scope, task: task, repo: repo} do
    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/notes.md"), "notes\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert Enum.any?(files, &(&1.path == ".rail/notes.md"))
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

  test "an untracked file that cannot be read contributes nothing", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "locked.ex"), "secret\n")
    File.chmod!(Path.join(repo, "locked.ex"), 0o000)

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    refute Enum.any?(files, &(&1.path == "locked.ex"))
  end

  # A link is drawn by where it points, as git draws a tracked one, so one an agent
  # aims outside the worktree never shows what it reaches.
  test "an untracked link is drawn as its target, never what the target holds", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    outside = repo <> "_outside.txt"
    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(repo, "notes.txt"))
    File.ln_s!("nowhere", Path.join(repo, "dangling.ex"))

    assert {:ok, files} = Git.load_diff(scope, task, :branch)

    assert %{status: :added, rows: [%{kind: :hunk_header}, %{line_kind: :added, text: ^outside}]} =
             Enum.find(files, &(&1.path == "notes.txt"))

    assert %{rows: [%{kind: :hunk_header}, %{line_kind: :added, text: "nowhere"}]} =
             Enum.find(files, &(&1.path == "dangling.ex"))
  end

  test "a task whose worktree is gone has no diff to read", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    assert {:error, :no_worktree} = Git.load_diff(scope, task)
  end

  test "a file that has not moved keeps the rows it was drawn with", %{scope: scope, task: task} do
    {:ok, files} = Git.load_diff(scope, task, :branch)
    shipped = Enum.find(files, &(&1.path == "shipped.ex"))
    {:ok, _marked} = Git.set_file_viewed(scope, task, shipped.path, shipped.digest, true)

    kept =
      Enum.map(files, fn file ->
        %{file | viewed?: false, rows: Enum.map(file.rows, &Map.put(&1, :html, "kept"))}
      end)

    assert {:ok, files} = Git.load_diff(scope, task, :branch, kept)

    assert %{viewed?: true, rows: [_header, %{html: "kept"}]} = Enum.find(files, &(&1.path == "shipped.ex"))
  end

  test "a file that moved is read and highlighted afresh", %{scope: scope, task: task, repo: repo} do
    {:ok, files} = Git.load_diff(scope, task, :branch)
    kept = Enum.map(files, fn file -> %{file | rows: Enum.map(file.rows, &Map.put(&1, :html, "kept"))} end)

    File.write!(Path.join(repo, "wip.ex"), "rewritten\n")

    assert {:ok, files} = Git.load_diff(scope, task, :branch, kept)

    assert %{rows: [_header, %{text: "rewritten", html: html}]} = Enum.find(files, &(&1.path == "wip.ex"))
    assert html =~ "rewritten"
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
