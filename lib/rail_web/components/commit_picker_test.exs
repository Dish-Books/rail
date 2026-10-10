defmodule RailWeb.Components.CommitPickerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.CommitPicker

  setup do
    commit = %{
      sha: "9c41e07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      short_sha: "9c41e07",
      parent: "7b19e4c",
      subject: "Fix 4 findings from round 1",
      at: ~U[2026-10-07 16:42:00Z],
      label: "Fix round 1",
      merge?: false,
      main?: false,
      merged: nil,
      conflicts: 0,
      files: 6,
      additions: 97,
      deletions: 31
    }

    merge = %{
      commit
      | sha: "e52a0bdaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        short_sha: "e52a0bd",
        parent: "9c41e07",
        subject: "Merge remote-tracking branch 'origin/main' into feature",
        label: "Merge main",
        merge?: true,
        main?: true,
        merged: "41d9f3c",
        conflicts: 1,
        additions: 56,
        deletions: 15
    }

    %{
      merge: merge,
      history: %{base: "main", head: "e52a0bd", commits: [merge, commit], files: 14, additions: 612, deletions: 148}
    }
  end

  test "offers the whole branch with its range, files and stat, then each commit newest first", %{history: history} do
    html =
      (&CommitPicker.commit_picker/1)
      |> render_component(view: :branch, history: history, target: nil)
      |> Floki.parse_fragment!()

    assert html |> Floki.find("#diff-commit-picker") |> Floki.text() =~ ~r/Whole branch\s+2 commits/

    assert [whole, merge, fix] = Floki.find(html, "[role='option']")
    assert Floki.attribute(whole, "aria-selected") == ["true"]
    assert Floki.text(whole) =~ ~r/Whole branch\s+main...e52a0bd · 14 files.*\+612.*-148/s
    assert Floki.text(merge) =~ ~r/Merge main\s+e52a0bd\s+1 conflict\s+Merge origin\/main \(41d9f3c\)/
    assert Floki.text(fix) =~ ~r/Fix round 1\s+9c41e07\s+Fix 4 findings from round 1/
    assert Floki.text(fix) =~ ~r/\+97.*-31/s
    assert [] = Floki.find(fix, "[data-qa='diff_commit_conflicts']")
    refute Floki.text(html) =~ "Uncommitted"
  end

  # What was pushed to the branch outside Rail and merged back in is none of main, so it says what it is.
  test "a merge of the branch's own remote reads as its label and its own subject", %{history: history, merge: merge} do
    branch_merge = %{
      merge
      | sha: "f1ecd8aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        short_sha: "f1ecd8a",
        subject: "Merge remote-tracking branch 'origin/rail-52-a-branch-name-long-enough-to-run-past-the-list'",
        label: "Merge origin/rail-52-a-branch-name-long-enough-to-run-past-the-list",
        main?: false,
        merged: "9fb9877"
    }

    html =
      (&CommitPicker.commit_picker/1)
      |> render_component(view: :branch, history: %{history | commits: [branch_merge | history.commits]}, target: nil)
      |> Floki.parse_fragment!()

    assert [option] = Floki.find(html, "#diff-commit-option-f1ecd8a")
    assert Floki.text(option) =~ "Merge origin/rail-52-a-branch-name-long-enough-to-run-past-the-list"
    assert Floki.text(option) =~ "Merge remote-tracking branch 'origin/rail-52-"
    refute Floki.text(option) =~ "Merge main"
    refute Floki.text(option) =~ "9fb9877"
    # A long branch name is cut short rather than run out of the list.
    assert [classes] = option |> Floki.find("[data-qa='diff_commit_title']") |> Floki.attribute("class")
    assert classes =~ "truncate"
  end

  # A pick closes the list and tells the view, which keeps nothing a stale page could name.
  test "picking an option closes the list and sends what it is", %{history: history, merge: merge} do
    html =
      (&CommitPicker.commit_picker/1)
      |> render_component(view: {:commit, merge.sha}, history: history, target: "#diff-view")
      |> Floki.parse_fragment!()

    assert html |> Floki.find("#diff-commit-picker") |> Floki.text() =~ ~r/e52a0bd\s+Merge main/
    assert ["true"] = html |> Floki.find("#diff-commit-option-e52a0bd") |> Floki.attribute("aria-selected")
    assert [click] = html |> Floki.find("#diff-commit-option-e52a0bd") |> Floki.attribute("phx-click")
    assert click =~ ~s("commit":"#{merge.sha}")
    assert click =~ "#diff-commit-listbox"
    assert ["Escape"] = html |> Floki.find("#diff-commit-option-e52a0bd") |> Floki.attribute("phx-key")
    assert ["Escape"] = html |> Floki.find("#diff-commit-picker") |> Floki.attribute("phx-key")
  end

  test "offers the uncommitted work while there is any, or while it is the view", %{history: history} do
    dirty = render_component(&CommitPicker.commit_picker/1, view: :branch, history: history, dirty?: true, target: nil)
    picked = render_component(&CommitPicker.commit_picker/1, view: :uncommitted, history: history, target: nil)

    assert dirty =~ "diff-commit-option-uncommitted"
    assert picked |> Floki.parse_fragment!() |> Floki.find("#diff-commit-picker") |> Floki.text() =~ "Uncommitted"
  end

  test "a branch git could not read offers only itself", %{history: history} do
    html =
      render_component(&CommitPicker.commit_picker/1,
        view: :branch,
        history: %{history | head: nil, commits: [], files: 0, additions: 0, deletions: 0},
        target: nil
      )

    assert html =~ "Everything since main"
    refute html =~ "Commits, newest first"
  end
end
