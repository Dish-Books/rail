defmodule Rail.Git.Actions.LoadDiffHunksTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users

  setup %{project: project} do
    scope = system_scope()

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

    # Two edits far enough apart to land in hunks of their own, beside a file the branch leaves alone.
    repo = create_temp_git_repo()
    lines = Enum.map_join(1..80, "", &"line #{&1}\n")
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/example.ex"), lines)
    File.write!(Path.join(repo, "lib/other.ex"), Enum.map_join(1..20, "", &"other #{&1}\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the file before"])
    # The diff forks from `origin/main`; this stands in for the fetch.
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
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

  test "a long range comes back whole, every line of it named, counting the other change it leaves out", %{
    scope: scope,
    task: task
  } do
    assert [%{path: "lib/example.ex", changed?: true, in_diff?: true, hidden_lines: 0, other_changes: 1, rows: rows}] =
             Git.load_diff_hunks(scope, task, [{"lib/example.ex", 40, 80}])

    named = Enum.filter(rows, & &1[:named?])
    assert Enum.count(named, &is_integer(&1.new_line)) == 41
    assert Enum.any?(named, &(&1.line_kind == :deleted and &1.text == "line 70"))
    assert %{new_line: 37} = hd(rows)
    refute Enum.any?(rows, &(&1.kind == :hunk_header))
    refute Enum.any?(rows, &(&1.text =~ "changed near the top"))
  end

  test "a range in the middle of a long change counts the changed lines it leaves out", %{
    scope: scope,
    task: %{worktree_path: worktree} = task
  } do
    rewritten = Enum.map_join(1..80, "", &if(&1 in 50..60, do: "rewritten #{&1}\n", else: "line #{&1}\n"))
    File.write!(Path.join(worktree, "lib/example.ex"), rewritten)
    git!(worktree, ["commit", "-am", "a long change"])

    assert [%{changed?: true, other_changes: 0, rows: rows} = excerpt] =
             Git.load_diff_hunks(scope, task, [{"lib/example.ex", 55, nil}])

    # The 11 lines added and 11 deleted, less what the window around line 55 shows.
    hidden = 22 - Enum.count(rows, &(&1.line_kind != :context))
    assert %{hidden_lines: ^hidden} = excerpt
    assert hidden > 0
    assert [%{new_line: 55, line_kind: :added}] = Enum.filter(rows, &(&1[:named?] == true and is_integer(&1.new_line)))
  end

  # The decision the plan names: never the file's first change in place of the lines asked for.
  test "a range on lines the branch did not change comes back as those lines, unchanged", %{scope: scope, task: task} do
    assert [%{changed?: false, in_diff?: true, other_changes: 2, hidden_lines: 0, rows: rows}] =
             Git.load_diff_hunks(scope, task, [{"lib/example.ex", 40, 42}])

    assert Enum.map(rows, & &1.new_line) == Enum.to_list(37..45)
    assert Enum.all?(rows, &(&1.line_kind == :context))
    assert ["line 40", "line 41", "line 42"] = rows |> Enum.filter(& &1[:named?]) |> Enum.map(& &1.text)
    refute Enum.any?(rows, &(&1.text =~ "changed"))
  end

  test "an unchanged line below what the branch added keeps its old number", %{
    scope: scope,
    task: %{worktree_path: worktree} = task
  } do
    File.write!(Path.join(worktree, "lib/other.ex"), ["new 1\nnew 2\n" | Enum.map(1..20, &"other #{&1}\n")])

    assert [%{changed?: false, rows: rows}] = Git.load_diff_hunks(scope, task, [{"lib/other.ex", 17, nil}])
    assert %{old_line: 15, new_line: 17, text: "other 15", named?: true} = Enum.find(rows, & &1[:named?])
  end

  test "a range spanning two changes is one run, the lines between read from the file", %{scope: scope, task: task} do
    assert [%{changed?: true, other_changes: 0, rows: rows}] =
             Git.load_diff_hunks(scope, task, [{"lib/example.ex", 5, 70}])

    refute Enum.any?(rows, &(&1.kind == :hunk_header))
    assert rows |> Enum.map(& &1.new_line) |> Enum.reject(&is_nil/1) == Enum.to_list(2..73)
    assert %{line_kind: :context, text: "line 40", old_line: 40} = Enum.find(rows, &(&1.new_line == 40))
    assert Enum.count(rows, &(&1.line_kind == :deleted)) == 2
  end

  test "a file the branch never touched comes back read from the worktree, not in the diff", %{
    scope: scope,
    task: task
  } do
    assert [%{path: "lib/other.ex", in_diff?: false, changed?: false, additions: 0, other_changes: 0, rows: rows}] =
             Git.load_diff_hunks(scope, task, [{"./lib/other.ex", 2, 3}])

    assert ["other 2", "other 3"] = rows |> Enum.filter(& &1[:named?]) |> Enum.map(& &1.text)
    assert %{new_line: 1, old_line: 1} = hd(rows)
  end

  test "ranges across two files come back in the order asked, from one read of the diff", %{
    scope: scope,
    task: task
  } do
    expect(Git, :load_diff, fn scope, task, filter -> call_original(Git, :load_diff, [scope, task, filter]) end)

    assert [
             %{path: "lib/example.ex", changed?: true},
             %{path: "lib/other.ex"},
             %{path: "lib/example.ex", changed?: false}
           ] =
             Git.load_diff_hunks(scope, task, [
               {"lib/example.ex", 70, nil},
               {"lib/other.ex", 1, 1},
               {"lib/example.ex", 30, 31}
             ])
  end

  test "a path with no line takes its file's first change, and one the branch did not change nothing", %{
    scope: scope,
    task: task
  } do
    assert [%{other_changes: 1, rows: rows}, nil] =
             Git.load_diff_hunks(scope, task, [{"lib/example.ex", nil, nil}, {"lib/other.ex", nil, nil}])

    assert Enum.any?(rows, &(&1.text =~ "changed near the top"))
    refute Enum.any?(rows, & &1[:named?])
  end

  # A reviewer quotes the path it read, which is not always the one git prints.
  test "a path the reviewer wrote as a suffix still finds its file", %{scope: scope, task: task} do
    assert [%{path: "lib/example.ex"}] = Git.load_diff_hunks(scope, task, [{"example.ex", 5, nil}])
  end

  test "a file that is not there, or a range past the end of a file outside the diff, has nothing to show", %{
    scope: scope,
    task: task
  } do
    assert [nil, nil] = Git.load_diff_hunks(scope, task, [{"lib/untouched.ex", 1, nil}, {"lib/other.ex", 30, 31}])
  end

  # The plan's rule: no rows from elsewhere in the file, only why there are none, with the file still in the diff.
  test "a range past the end of a file in the diff names the file's length and no rows", %{scope: scope, task: task} do
    File.write!(Path.join(task.worktree_path, "lib/other.ex"), "")

    assert [
             %{path: "lib/example.ex", in_diff?: true, additions: 2, rows: [], missing: {:past_end, 80}},
             %{path: "lib/other.ex", in_diff?: true, deletions: 20, rows: [], missing: {:past_end, 0}}
           ] = Git.load_diff_hunks(scope, task, [{"lib/example.ex", 90, 95}, {"lib/other.ex", 1, nil}])
  end

  test "a cleaned-up worktree has nothing to read", %{scope: scope, task: task} do
    File.rm_rf!(task.worktree_path)

    assert [nil, nil] = Git.load_diff_hunks(scope, task, [{"lib/example.ex", 5, nil}, {"lib/other.ex", 1, nil}])
  end

  # A picture has no lines to show, and the pane is handed the fact of it rather than nothing at all.
  test "a file with no lines still says it is there", %{scope: scope, task: task} do
    File.write!(Path.join(task.worktree_path, "logo.png"), <<0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3>>)
    File.write!(Path.join(task.worktree_path, "kept.bin"), <<1, 0, 2>>)
    git!(task.worktree_path, ["add", "logo.png"])
    git!(task.worktree_path, ["commit", "-m", "a picture"])
    git!(task.worktree_path, ["add", "kept.bin"])
    git!(task.worktree_path, ["commit", "-m", "a file main also has"])
    git!(task.worktree_path, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    assert [
             %{path: "logo.png", rows: [%{kind: :binary}], in_diff?: false},
             %{path: "kept.bin", rows: [%{kind: :binary}], in_diff?: false}
           ] = Git.load_diff_hunks(scope, task, [{"logo.png", 1, nil}, {"kept.bin", 1, nil}])

    File.write!(Path.join(task.worktree_path, "logo.png"), <<0x89, 0x50, 0, 9>>)

    assert [%{rows: [%{kind: :binary}], in_diff?: true}, %{rows: [%{kind: :binary}], in_diff?: true}] =
             Git.load_diff_hunks(scope, task, [{"logo.png", 1, nil}, {"logo.png", nil, nil}])
  end

  # Bytes that are not UTF-8 cannot be sent to a browser, so a line holding them is drawn with them replaced.
  test "a line that is not UTF-8 outside the change is drawn with its bad bytes replaced", %{
    scope: scope,
    task: %{worktree_path: worktree} = task
  } do
    File.write!(Path.join(worktree, "lib/latin.ex"), [<<"caf", 0xE9, "\n">> | Enum.map(2..20, &"latin #{&1}\n")])
    git!(worktree, ["add", "."])
    git!(worktree, ["commit", "-m", "a latin file"])
    git!(worktree, ["update-ref", "refs/remotes/origin/main", "HEAD"])

    File.write!(Path.join(worktree, "lib/latin.ex"), [
      <<"caf", 0xE9, "\n">> | Enum.map(2..20, &if(&1 == 20, do: "last\n", else: "latin #{&1}\n"))
    ])

    assert [%{in_diff?: true, rows: [%{text: text, html: nil, named?: true} | _rest]}, %{changed?: true}] =
             Git.load_diff_hunks(scope, task, [{"lib/latin.ex", 1, nil}, {"lib/latin.ex", 20, nil}])

    assert String.valid?(text)
  end

  # A file the branch changed without changing a line of it - here made executable - shows its lines as they are.
  test "a file with no content change shows its lines unchanged", %{scope: scope, task: task} do
    repo = create_temp_git_repo()
    script = Path.join(repo, "script.sh")
    File.write!(script, "echo hello\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the script"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    git!(repo, ["checkout", "-b", "feature"])
    File.chmod!(script, 0o755)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "made it runnable"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})

    assert [%{in_diff?: true, changed?: false, rows: [%{text: "echo hello", named?: true}]}, nil] =
             Git.load_diff_hunks(scope, task, [{"script.sh", 1, nil}, {"script.sh", nil, nil}])
  end

  test "a whole file deleted on the branch says so, with no rows", %{scope: scope, task: task} do
    File.rm!(Path.join(task.worktree_path, "lib/other.ex"))

    assert [%{path: "lib/other.ex", in_diff?: true, deletions: 20, rows: [], missing: :deleted, other_changes: 0}] =
             Git.load_diff_hunks(scope, task, [{"lib/other.ex", 1, 2}])
  end

  # FileLines reads no link, so the lines a range names in one are not drawn.
  test "a link the branch changes says its lines are not read", %{scope: scope, task: task} do
    File.ln_s!("lib/example.ex", Path.join(task.worktree_path, "linked.ex"))

    assert [%{path: "linked.ex", in_diff?: true, rows: [], missing: :unreadable}] =
             Git.load_diff_hunks(scope, task, [{"linked.ex", 1, nil}])
  end

  test "what a range replaced shows above it, and only what was deleted between its lines is named", %{
    scope: scope,
    task: task
  } do
    assert [%{rows: rows}] = Git.load_diff_hunks(scope, task, [{"lib/example.ex", 70, 71}])

    assert [%{text: "line 70", named?: false}] =
             rows |> Enum.filter(&(&1.line_kind == :deleted)) |> Enum.map(&Map.put_new(&1, :named?, false))

    assert [%{text: "line 69", named?: false}, %{text: "line 70", line_kind: :deleted} | _rest] =
             rows |> Enum.drop(2) |> Enum.map(&Map.put_new(&1, :named?, false))
  end

  test "what was deleted after the file's last line follows it", %{scope: scope, task: task} do
    File.write!(Path.join(task.worktree_path, "lib/other.ex"), Enum.map_join(1..18, "", &"other #{&1}\n"))

    assert [%{changed?: false, rows: rows}] = Git.load_diff_hunks(scope, task, [{"lib/other.ex", 14, 15}])

    assert ["other 19", "other 20"] = rows |> Enum.filter(&(&1.line_kind == :deleted)) |> Enum.map(& &1.text)
    assert %{line_kind: :deleted} = List.last(rows)
  end
end
