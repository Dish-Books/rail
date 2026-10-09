defmodule RailWeb.Live.DiffViewTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  # The branch has the engineer's commit, a merge of main and a fix on top, newest last.
  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "dvw-1-#{id}",
        login: "dana-#{id}",
        name: "Dana",
        email: "dana-#{id}@dvw.example"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    remote = create_temp_git_repo(prefix: "rail_dvw_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..10, "", &"line #{&1}\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the engineer's work"])
    engineer = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    git!(repo, ["checkout", "main"])
    File.write!(Path.join(repo, "upstream.ex"), "landed on main\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "landed on main"])
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "feature"])
    git!(repo, ["merge", "--no-edit", "origin/main"])
    merge = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(repo, "fix.ex"), "defmodule Fix do\nend\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Fix 1 finding from round 1\n\nRail-Step: Fix round 1"])
    fix = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(repo, ["push", "--set-upstream", "origin", "feature"])

    task = learnings_task(project, "DVW-1")
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_dvw",
        started_at: DateTime.utc_now()
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      task: task,
      run: run,
      repo: repo,
      engineer: engineer,
      merge: merge,
      fix: fix
    }
  end

  test "the picker offers the whole branch, then each commit newest first, labeled by what made it", %{
    conn: conn,
    task: task
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    labels =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#diff-commit-listbox [role='option'] .whitespace-nowrap")
      |> Enum.map(&String.trim(Floki.text(&1)))

    assert labels == ["Whole branch", "Fix round 1", "Merge main", "Engineer"]
    assert has_element?(view, "#diff-commit-picker", "Whole branch")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "picking a commit shows only what it changed, and a comment there keeps its commit", %{
    conn: conn,
    task: task,
    engineer: engineer
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#diff-commit-option-#{String.slice(engineer, 0, 7)}") |> render_click()

    assert has_element?(view, "#diff-commit-picker", "Engineer")
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

  test "a merge's view shows what main brought in, takes no comment and offers no Send", %{
    conn: conn,
    user: user,
    task: task,
    merge: merge
  } do
    {:ok, _comment} =
      Pipeline.create_diff_comment(user_scope(user: user), task, %{
        path: "rows.ex",
        line_kind: :added,
        line: 1,
        line_text: "line 1",
        filter: :branch,
        body: "Waiting to go."
      })

    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    assert has_element?(view, "#send-diff-comments")

    view |> element("#diff-commit-option-#{String.slice(merge, 0, 7)}") |> render_click()

    assert has_element?(view, "[data-qa='diff_file_section'][data-path='upstream.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex'] .diff-body")
    refute has_element?(view, "[data-qa='diff_comment_add']")
    refute has_element?(view, "#send-diff-comments")
    assert has_element?(view, "[data-qa='diff_no_comments']", "No comments on a merge")

    render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
      "path" => "upstream.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "1"
    })

    refute has_element?(view, "[data-qa='diff_comment_form']")
  end

  # RAIL-53: the reply to the click is what draws them Sent, so nothing in between draws them unsent again.
  test "sent comments read Sent in the click's own reply, and Sending until it lands", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    for line <- ["3", "8"] do
      render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
        "path" => "rows.ex",
        "kind" => "added",
        "old_line" => "",
        "new_line" => line
      })

      view |> form("[data-qa='diff_comment_form']", %{"body" => "On line #{line}."}) |> render_submit()
    end

    unsent = view |> render() |> Floki.parse_document!() |> Floki.find("[data-qa='diff_comment']")
    assert length(unsent) == 2
    assert Enum.all?(unsent, &(Floki.find(&1, "[data-qa='diff_comment_sending']") != []))

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    reply = view |> element("#send-diff-comments") |> render_click()

    comments = reply |> Floki.parse_document!() |> Floki.find("[data-qa='diff_comment']")
    assert length(comments) == 2
    assert Enum.all?(comments, &(Floki.text(&1) =~ "Sent"))
    refute reply =~ "Not sent"
    refute reply =~ "send-diff-comments"
  end

  test "a send the agent cannot take says why, and the comments stay unsent", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
      "path" => "rows.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "3"
    })

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Hold on."}) |> render_submit()

    for {reason, said} <- [
          {:chat_unavailable, "The engineer has no conversation to send these to yet."},
          {{:invalid_stage, :merged}, "This conversation is closed now that the task is at Merged."},
          {:locked, "Could not send these: :locked"}
        ] do
      expect(Pipeline, :send_diff_comments, fn _scope, _run -> {:error, reason} end)

      view |> element("#send-diff-comments") |> render_click()

      assert has_element?(view, "#diff-error", said)
    end

    assert has_element?(view, "[data-qa='diff_comment']", "Not sent")
  end

  test "a commit's gap is read as the file was at that commit", %{conn: conn, task: task, repo: repo, fix: fix} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#diff-commit-option-#{String.slice(fix, 0, 7)}") |> render_click()
    expect(Git, :expand_diff_gap, fn _task, "fix.ex", 0, 1, 1, ^fix -> {"fix.ex:0", []} end)
    File.write!(Path.join(repo, "fix.ex"), "rewritten\n")

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
    fix: fix
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    render_click(with_target(view, "#diff-view"), "pick_commit", %{"commit" => "0000000000"})
    assert has_element?(view, "#diff-commit-picker", "Whole branch")

    view |> element("#diff-commit-option-#{String.slice(fix, 0, 7)}") |> render_click()
    git!(repo, ["reset", "--hard", "HEAD~1"])
    Phoenix.LiveView.send_update(view.pid, RailWeb.Live.DiffView, id: "diff-view", reload: true)

    assert has_element?(view, "#diff-commit-picker", "Whole branch")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "the uncommitted work is a view of its own while there is any", %{conn: conn, task: task, repo: repo} do
    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..11, "", &"line #{&1}\n"))
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    view |> element("#diff-commit-option-uncommitted") |> render_click()

    assert has_element?(view, "#diff-commit-picker", "Uncommitted")
    assert has_element?(view, "[data-qa='diff_file_section'][data-path='rows.ex']")
    refute has_element?(view, "[data-qa='diff_file_section'][data-path='fix.ex']")
  end

  test "a saved comment carries the code around its line, from the view it was written in", %{
    conn: conn,
    task: task,
    repo: repo
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    diff = with_target(view, "#diff-view")

    render_click(diff, "open_diff_comment", %{"path" => "rows.ex", "kind" => "added", "old_line" => "", "new_line" => "8"})

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Name the eighth."}) |> render_submit()

    expected =
      Enum.join(
        ["  + line 2", "  + line 3", "  + line 4", "  + line 5", "  + line 6", "  + line 7", "> + line 8"] ++
          ["  + line 9", "  + line 10"],
        "\n"
      )

    assert %DiffComment{filter: :branch, commit: nil, context_text: ^expected} =
             Repo.get_by!(DiffComment, body: "Name the eighth.")

    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..10, "", &"line #{&1}\n") <> "line 11\n")
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

  # The path comes from the page, so one the pane never drew is not read at all.
  test "a gap asked for in a file the diff does not show reads nothing", %{conn: conn, task: task} do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    reject(&Git.expand_diff_gap/6)

    render_click(with_target(view, "#diff-view"), "expand_gap", %{
      "path" => "../../../../etc/passwd",
      "gap_index" => "0",
      "start_line" => "1",
      "end_line" => "1000"
    })

    refute render(view) =~ "root:"
  end

  test "opening, saving and sending a comment recolors no line", %{conn: conn, task: task} do
    {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
    code = html |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code")
    assert [_first | _rest] = code

    render_click(with_target(view, "#diff-view"), "open_diff_comment", %{
      "path" => "rows.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "8"
    })

    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Name the eighth."}) |> render_submit()

    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)
    view |> element("#send-diff-comments") |> render_click()

    assert has_element?(view, "[data-qa='diff_comment']", "Sent")
    assert view |> render() |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code") == code
  end

  describe "long lines" do
    test "scroll until the reader picks Wrap, which redraws no line", %{conn: conn, task: task} do
      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
      lines = html |> Floki.parse_document!() |> Floki.find(".diff-body")

      assert html |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") == ["true"]

      view |> element("#diff-wrap-wrap") |> render_click()
      html = view |> render() |> Floki.parse_document!()

      assert Floki.attribute(html, "#diff-wrap-wrap", "aria-pressed") == ["true"]
      assert Floki.attribute(html, "#diff-wrap-scroll", "aria-pressed") == ["false"]
      assert Floki.find(html, ".diff-body") == lines

      view |> element("#diff-wrap-scroll") |> render_click()

      assert view |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") ==
               ["true"]
    end

    # The browser holds the choice, so its hook says so as the tab mounts.
    test "the choice this browser remembers is pressed once its hook says so", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

      view |> with_target("#diff-view") |> render_click("select_diff_wrap", %{"wrap" => "wrap"})

      assert view |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-wrap", "aria-pressed") == ["true"]
    end

    test "one reader's choice does not reach another reading the same task", %{conn: conn, task: task} do
      {:ok, first, _html} = live(conn, ~p"/tasks/#{task.id}")
      {:ok, second, _html} = live(conn, ~p"/tasks/#{task.id}")

      first |> element("#diff-wrap-wrap") |> render_click()

      assert first |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-wrap", "aria-pressed") == [
               "true"
             ]

      assert second |> render() |> Floki.parse_document!() |> Floki.attribute("#diff-wrap-scroll", "aria-pressed") ==
               ["true"]
    end

    test "a wrapped line still opens a comment under it", %{conn: conn, task: task} do
      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      view |> element("#diff-wrap-wrap") |> render_click()

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
