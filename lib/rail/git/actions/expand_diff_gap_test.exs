defmodule Rail.Git.Actions.ExpandDiffGapTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{checkout: checkout} = context = create_task_checkout()
    File.write!(Path.join(checkout, "tracked.txt"), Enum.map_join(1..10, "", &"line #{&1}\n"))
    File.mkdir_p!(Path.join(checkout, "lib"))
    File.write!(Path.join(checkout, "lib/kept.ex"), "kept\n")
    context
  end

  test "reads the unchanged lines across the gap, as the checkout has them", %{task: task} do
    assert {"tracked.txt:0", lines} = Git.expand_diff_gap(task, "tracked.txt", 0, 3, 5)
    assert Enum.map(lines, & &1.text) == ["line 3", "line 4", "line 5"]
  end

  test "reads a commit's gap as the file was at that commit", %{task: task, checkout: checkout} do
    git!(checkout, ["add", "tracked.txt"])
    git!(checkout, ["commit", "-m", "tracked"])
    sha = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()
    File.write!(Path.join(checkout, "tracked.txt"), "rewritten\n")

    assert {"tracked.txt:1", [%{text: "line 2"}, %{text: "line 3"}]} =
             Git.expand_diff_gap(task, "tracked.txt", 1, 2, 3, sha)
  end

  # A gap is drawn by the same row the hunks around it are, so it carries the
  # same highlighted html they do.
  test "highlights what it read", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "thing.ex"), "defmodule Thing do\n  :ok\nend\n")

    assert {"thing.ex:0", [%{html: html}]} = Git.expand_diff_gap(task, "thing.ex", 0, 1, 1)
    assert html =~ ~s(class="l-keyword)
  end

  test "a gap inside a heredoc that opens above it is colored as the heredoc", %{task: task, checkout: checkout} do
    lines = ["defmodule Thing do", ~s(  @moduledoc """), "  one", "  two", "  def inside, do: 1", ~s(  """), "end\n"]
    File.write!(Path.join(checkout, "thing.ex"), Enum.join(lines, "\n"))

    assert {"thing.ex:0", [%{text: "  two"}, %{text: "  def inside, do: 1", html: html}]} =
             Git.expand_diff_gap(task, "thing.ex", 0, 4, 5)

    assert html =~ "l-comment"
    refute html =~ "l-keyword-function"
  end

  # The highlighter cannot take a file that is not text whole, but the gap's own lines can be.
  test "a gap in a file with a byte that is not text elsewhere is still colored", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "latin.ex"), <<"# caf", 0xE9, "\ndefmodule Latin do\n  def one, do: 1\nend\n">>)

    assert {"latin.ex:0", [%{text: "  def one, do: 1", html: html}]} = Git.expand_diff_gap(task, "latin.ex", 0, 3, 3)
    assert html =~ "l-keyword-function"
  end

  test "a file it cannot read expands to nothing", %{task: task} do
    assert {"missing.txt:1", []} = Git.expand_diff_gap(task, "missing.txt", 1, 1, 5)
  end

  test "a directory is not a file to read lines out of", %{task: task} do
    assert {"lib:0", []} = Git.expand_diff_gap(task, "lib", 0, 1, 5)
  end

  test "an empty file has no lines to fill a gap with", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "empty.txt"), "")

    assert {"empty.txt:0", []} = Git.expand_diff_gap(task, "empty.txt", 0, 1, 5)
  end

  test "a task whose repository is gone expands to nothing", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert {"tracked.txt:0", []} = Git.expand_diff_gap(task, "tracked.txt", 0, 1, 5)
  end
end
