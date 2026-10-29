defmodule RailWeb.Live.DiffViewTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Rail.Git.Utils.ParseDiff

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users
  alias RailWeb.Live.DiffView

  # The branch has the engineer's commit, a merge of main and a fix on top, newest last.
  #
  # Git is only ever asked through Rail.Git, so the worktree is a directory holding the patches the stubs answer
  # from: branch.diff, what the branch changed against main, uncommitted work included, uncommitted.diff, that
  # work alone, and <sha>.diff for each commit, against its first parent. A commit is on the branch while its
  # patch is there, so a test moves the branch on by writing or removing one.
  setup %{conn: conn, project: project} do
    # What is merged is read from the project's clone, which another test may have made, so reading it here
    # would spawn git: these pages see nothing on the default branch, as when there is no clone.
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :list_default_branch_paths, fn _project, paths -> if paths == [], do: MapSet.new() end)

    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "dvw-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@dvw.example"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    task = learnings_task(project, "DVW-1")
    repo = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(repo)

    engineer = String.duplicate("e", 40)
    merge = String.duplicate("b", 40)
    fix = String.duplicate("f", 40)

    rows = """
    diff --git a/rows.ex b/rows.ex
    new file mode 100644
    index 0000000..7a1c613
    --- /dev/null
    +++ b/rows.ex
    @@ -0,0 +1,10 @@
    #{Enum.map_join(1..10, "\n", &"+line #{&1}")}
    """

    File.write!(Path.join(repo, "#{engineer}.diff"), rows)

    File.write!(Path.join(repo, "#{merge}.diff"), """
    diff --git a/upstream.ex b/upstream.ex
    new file mode 100644
    index 0000000..5d1b3a4
    --- /dev/null
    +++ b/upstream.ex
    @@ -0,0 +1 @@
    +landed on main
    """)

    # Main's file came in by the merge, so against main the branch is still only the engineer's.
    File.write!(Path.join(repo, "branch.diff"), rows)
    File.write!(Path.join(repo, "uncommitted.diff"), "")

    # Newest first, as git logs them.
    commits = [
      %{
        sha: fix,
        short_sha: String.slice(fix, 0, 7),
        parent: merge,
        subject: "Fix 1 finding from round 1",
        at: ~U[2026-10-28 12:02:00Z],
        label: "Fix round 1",
        merge?: false,
        main?: false,
        merged: nil,
        conflicts: 0,
        files: 1,
        additions: 2,
        deletions: 0
      },
      %{
        sha: merge,
        short_sha: String.slice(merge, 0, 7),
        parent: engineer,
        subject: "Merge remote-tracking branch 'origin/main' into feature",
        at: ~U[2026-10-28 12:01:00Z],
        label: "Merge main",
        merge?: true,
        main?: true,
        merged: String.duplicate("c", 40),
        conflicts: 0,
        files: 1,
        additions: 1,
        deletions: 0
      },
      %{
        sha: engineer,
        short_sha: String.slice(engineer, 0, 7),
        parent: String.duplicate("a", 40),
        subject: "the engineer's work",
        at: ~U[2026-10-28 12:00:00Z],
        label: "Implement",
        merge?: false,
        main?: false,
        merged: nil,
        conflicts: 0,
        files: 1,
        additions: 10,
        deletions: 0
      }
    ]

    stub(Git, :load_branch_history, fn task, _rounds ->
      on_branch = Enum.filter(commits, &File.exists?(Path.join(task.worktree_path, "#{&1.sha}.diff")))
      files = parse_diff(File.read!(Path.join(task.worktree_path, "branch.diff")))

      %{
        base: "main",
        head: on_branch |> List.first() |> Map.fetch!(:short_sha),
        commits: on_branch,
        files: length(files),
        additions: Enum.sum_by(files, & &1.additions),
        deletions: Enum.sum_by(files, & &1.deletions)
      }
    end)

    # Rows come back unhighlighted, which the pane draws as their text.
    stub(Git, :load_diff, fn scope, task, filter, _previous ->
      viewed = Git.list_viewed_files(scope, task, :diff)

      patch =
        case filter do
          {:commit, sha} -> "#{sha}.diff"
          view -> "#{view}.diff"
        end

      {:ok,
       for file <- parse_diff(File.read!(Path.join(task.worktree_path, patch))) do
         rows = Enum.map(file.rows, &Map.put(&1, :html, nil))
         Map.merge(file, %{rows: rows, viewed?: viewed[file.path] == file.digest})
       end}
    end)

    stub(Git, :branch_fingerprint, fn worktree_path ->
      %{sha: head_sha} = Enum.find(commits, &File.exists?(Path.join(worktree_path, "#{&1.sha}.diff")))
      dirty = File.read!(Path.join(worktree_path, "uncommitted.diff"))
      %{head_sha: head_sha, dirty_digest: :sha256 |> :crypto.hash(dirty) |> Base.encode16(case: :lower)}
    end)

    stub(Git, :worktree_dirty?, fn worktree_path -> File.read!(Path.join(worktree_path, "uncommitted.diff")) != "" end)

    # Round 1 read the branch up to the merge, so what came after is the fix round it led to.
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})
    {:ok, %{round: 1, head: ^merge}} = Pipeline.save_review(task)

    File.write!(Path.join(repo, "#{fix}.diff"), """
    diff --git a/fix.ex b/fix.ex
    new file mode 100644
    index 0000000..e8f1c2b
    --- /dev/null
    +++ b/fix.ex
    @@ -0,0 +1,2 @@
    +defmodule Fix do
    +end
    """)

    File.write!(Path.join(repo, "branch.diff"), rows <> File.read!(Path.join(repo, "#{fix}.diff")))

    %{
      conn: log_in_user(conn, user),
      user: user,
      task: task,
      repo: repo,
      engineer: engineer,
      merge: merge,
      fix: fix
    }
  end

  # A link names the commit a round read, which need not be the one that wrote the file it was sent for.
  test "the picker offers the whole branch, then each commit newest first, labeled by what made it, and a link to a commit that does not touch its file opens the whole branch at the file",
       %{conn: conn, task: task, engineer: engineer, fix: fix} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    labels =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#diff-commit-listbox [data-qa='diff_commit_title']")
      |> Enum.map(&String.trim(Floki.text(&1)))

    assert labels == ["Whole branch", "Fix round 1", "Merge main", "Implement"]
    assert has_element?(view, "#diff-commit-picker", "Whole branch")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")

    Phoenix.LiveView.send_update(view.pid, DiffView, id: "diff-view", open: %{commit: fix, at: 1}, focus_file: "rows.ex")

    assert has_element?(view, "#diff-commit-picker", "Whole branch")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")

    Phoenix.LiveView.send_update(view.pid, DiffView,
      id: "diff-view",
      open: %{commit: engineer, at: 2},
      focus_file: "rows.ex"
    )

    assert has_element?(view, "#diff-commit-picker", "Implement")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "a merge's view shows what main brought in and takes no comment, and picking a commit shows only what it changed, where a comment keeps its commit",
       %{conn: conn, task: task, engineer: engineer, merge: merge} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#diff-commit-option-#{String.slice(merge, 0, 7)}") |> render_click()

    assert has_element?(view, "[data-qa='diff_file_section'][data-path='upstream.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex'] .diff-body")
    refute has_element?(view, "[data-qa='diff_comment_add']")
    assert has_element?(view, "[data-qa='diff_no_comments']", "No comments on a merge")

    render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
      "path" => "upstream.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "1"
    })

    refute has_element?(view, "[data-qa='diff_comment_form']")

    view |> element("#diff-commit-option-#{String.slice(engineer, 0, 7)}") |> render_click()

    assert has_element?(view, "#diff-commit-picker", "Implement")
    assert has_element?(view, "[data-qa='diff_first_parent']", "against its first parent")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")

    render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
      "path" => "rows.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "3"
    })

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Name the third."}) |> render_submit()

    assert %DiffComment{filter: :commit, commit: ^engineer} = Repo.get_by!(DiffComment, body: "Name the third.")

    assert has_element?(
             view,
             "[data-qa='diff_file_section'][data-path='rows.ex'] [data-qa='diff_comment']",
             "Name the third."
           )

    # In the whole branch the commit's line numbers are not the branch's, so it is lifted above its file.
    view |> element("#diff-commit-option-branch") |> render_click()

    assert has_element?(view, "[data-qa='diff_comments_lifted'] [data-qa='diff_comment']", "Name the third.")
  end

  # Review's tray sends the reader's comments; a sent one stays under its line with Resolve.
  test "in Review a sent comment stays under its line with Resolve, and an unsent one reads Not sent", %{
    conn: conn,
    user: user,
    task: task,
    project: project
  } do
    scope = user_scope(user: user)
    comment = %{path: "rows.ex", line_kind: :added, line: 3, line_text: "line 3", filter: :branch}
    {:ok, _sent} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Sent before Review."))
    # As the Review tray's Send leaves them.
    Repo.update_all(from(c in DiffComment, where: c.task_id == ^task.id and c.status == :unsent), set: [status: :sent])
    {:ok, _unsent} = Pipeline.create_diff_comment(scope, task, Map.put(comment, :body, "Waits in the tray."))
    {:ok, _review} = Pipeline.update_task(task, %{stage: :review})
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, _lead_run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_dvw_lead",
        started_at: DateTime.utc_now()
      })

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-item-diff") |> render_click()

    assert has_element?(view, "[data-qa=diff_comment]", "Sent before Review.")
    assert has_element?(view, "[data-qa=diff_comment_resolve]")
    assert has_element?(view, "[data-qa=diff_comment] [data-qa=diff_comment_unsent]")
  end

  # The path comes from the page, so one the pane never drew is not read at all: the one read expected is the
  # commit's, and any other would fail the view.
  test "a commit's gap is read as the file was at that commit, and a gap asked for in a file the diff does not show reads nothing",
       %{conn: conn, task: task, fix: fix} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#diff-commit-option-#{String.slice(fix, 0, 7)}") |> render_click()
    expect(Git, :expand_diff_gap, fn _task, "fix.ex", 0, 1, 1, ^fix -> {"fix.ex:0", []} end)

    render_click(with_target(view, "#diff-view"), "expand_gap", %{
      "path" => "../../../../etc/passwd",
      "gap_index" => "0",
      "start_line" => "1",
      "end_line" => "1000"
    })

    refute render(view) =~ "root:"

    render_click(with_target(view, "#diff-view"), "expand_gap", %{
      "path" => "fix.ex",
      "gap_index" => "0",
      "start_line" => "1",
      "end_line" => "1"
    })
  end

  # A page drawn before a rebase can still name a commit the branch no longer has.
  test "a commit the branch does not have is not picked, and one that vanished is the whole branch again", %{
    conn: conn,
    task: task,
    repo: repo,
    engineer: engineer,
    fix: fix
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    render_click(with_target(view, "#diff-view"), "pick_commit", %{"commit" => "0000000000"})
    assert has_element?(view, "#diff-commit-picker", "Whole branch")

    view |> element("#diff-commit-option-#{String.slice(fix, 0, 7)}") |> render_click()
    # The fix is reset away, and the branch is the engineer's work again.
    File.rm!(Path.join(repo, "#{fix}.diff"))
    File.cp!(Path.join(repo, "#{engineer}.diff"), Path.join(repo, "branch.diff"))
    Phoenix.LiveView.send_update(view.pid, DiffView, id: "diff-view", reload: true)

    assert has_element?(view, "#diff-commit-picker", "Whole branch")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "the uncommitted work is a view of its own while there is any", %{conn: conn, task: task, repo: repo} do
    File.write!(Path.join(repo, "uncommitted.diff"), """
    diff --git a/rows.ex b/rows.ex
    index 7a1c613..f3b2d90 100644
    --- a/rows.ex
    +++ b/rows.ex
    @@ -8,3 +8,4 @@
     line 8
     line 9
     line 10
    +line 11
    """)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#diff-commit-option-uncommitted") |> render_click()

    assert has_element?(view, "#diff-commit-picker", "Uncommitted")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "a saved comment carries the code around its line, from the view it was written in, and opening, saving and sending a comment recolors no line",
       %{conn: conn, task: task, repo: repo} do
    {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
    diff = with_target(view, "#diff-view")
    code = html |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code")
    assert [_first | _rest] = code

    render_click(diff, "open_diff_comment", %{"path" => "rows.ex", "kind" => "added", "old_line" => "", "new_line" => "8"})

    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Name the eighth."}) |> render_submit()

    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code

    expected =
      Enum.join(
        ["  + line 2", "  + line 3", "  + line 4", "  + line 5", "  + line 6", "  + line 7", "> + line 8"] ++
          ["  + line 9", "  + line 10"],
        "\n"
      )

    assert %DiffComment{filter: :branch, commit: nil, context_text: ^expected} =
             Repo.get_by!(DiffComment, body: "Name the eighth.")

    # As the Review tray's Send leaves them, and tells the page.
    Repo.update_all(from(c in DiffComment, where: c.task_id == ^task.id and c.status == :unsent), set: [status: :sent])
    send(view.pid, {:diff_comments_changed, task.id})
    # The page hands the pane its comments through send_update, which queues behind the first render.
    _settled = render(view)

    assert has_element?(view, "[data-qa='diff_comment']", "Sent")
    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code

    File.write!(Path.join(repo, "uncommitted.diff"), """
    diff --git a/rows.ex b/rows.ex
    index 7a1c613..f3b2d90 100644
    --- a/rows.ex
    +++ b/rows.ex
    @@ -8,3 +8,4 @@
     line 8
     line 9
     line 10
    +line 11
    """)

    render_click(diff, "pick_commit", %{"commit" => "uncommitted"})

    render_click(diff, "open_diff_comment", %{
      "path" => "rows.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "11"
    })

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Why another?"}) |> render_submit()

    assert %DiffComment{filter: :uncommitted, context_text: uncommitted} = Repo.get_by!(DiffComment, body: "Why another?")
    assert uncommitted =~ "> + line 11"
    assert uncommitted =~ "    line 10"
  end

  test "marking a file reviewed on the diff leaves the plan's card for that path as it was, and the other way round", %{
    conn: conn,
    user: user,
    task: task
  } do
    scope = user_scope(user: user)
    {:ok, _card} = Git.set_file_viewed(scope, task, :plan, "rows.ex", "card_digest", true)

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#diff-header-rows-ex [data-qa='diff-viewed-checkbox'][aria-pressed='false']")

    view |> element("#diff-header-rows-ex [data-qa='diff-viewed-checkbox']") |> render_click()

    assert has_element?(view, "#diff-header-rows-ex [data-qa='diff-viewed-checkbox'][aria-pressed='true']")
    assert %{"rows.ex" => diff_digest} = Git.list_viewed_files(scope, task, :diff)
    assert diff_digest != "card_digest"
    assert Git.list_viewed_files(scope, task, :plan) == %{"rows.ex" => "card_digest"}

    view |> element("#diff-header-rows-ex [data-qa='diff-viewed-checkbox']") |> render_click()

    assert Git.list_viewed_files(scope, task, :diff) == %{}
    assert Git.list_viewed_files(scope, task, :plan) == %{"rows.ex" => "card_digest"}
  end

  describe "long lines" do
    test "scroll until the reader picks Wrap, which redraws no line and does not reach another reading the same task",
         %{conn: conn, task: task} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, other, _html} = live(conn, ~p"/tasks/#{task.id}")
      lines = html |> Floki.parse_document!() |> Floki.find(".diff-body")

      assert html |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") == ["true"]

      view |> element("#diff-wrap-wrap") |> render_click()
      html = view |> render() |> Floki.parse_document!()

      assert Floki.attribute(html, "#diff-wrap-wrap", "aria-pressed") == ["true"]
      assert Floki.attribute(html, "#diff-wrap-scroll", "aria-pressed") == ["false"]
      assert Floki.find(html, ".diff-body") == lines

      assert other |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") ==
               ["true"]

      view |> element("#diff-wrap-scroll") |> render_click()

      assert view |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") ==
               ["true"]
    end

    # The browser holds the choice, so its hook says so as the tab mounts.
    test "the choice this browser remembers is pressed once its hook says so, and a wrapped line still opens a comment under it",
         %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> with_target("#diff-view") |> render_click("select_diff_wrap", %{"wrap" => "wrap"})

      assert view |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-wrap", "aria-pressed") == ["true"]

      render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
        "path" => "rows.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => "8"
      })

      html = view |> render() |> Floki.parse_document!()

      assert [segment] =
               html
               |> Floki.find(".diff-rows > .contents")
               |> Enum.filter(&(Floki.find(&1, "[data-qa='diff_comment_form']") != []))

      assert segment |> Floki.find(".diff-line") |> List.last() |> Floki.find(".diff-num") |> Enum.map(&Floki.text/1) ==
               ["", "8"]
    end
  end
end
