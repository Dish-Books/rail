defmodule RailWeb.Live.EngineerStageTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} = Users.register_oauth_user(%{github_id: "est-1", login: "dana", name: "Dana", email: "dana@est.example"})
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    remote = create_temp_git_repo(prefix: "rail_est_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..10, "", &"line #{&1}\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "the engineer's work"])
    git!(repo, ["push", "--set-upstream", "origin", "feature"])

    task = learnings_task(project, "EST-1")
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer, worktree_path: repo})

    {:ok, _run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_est",
        started_at: DateTime.utc_now()
      })

    %{conn: log_in_user(conn, user), task: task, repo: repo}
  end

  test "a saved comment carries the code around its line, from the view it was written in", %{
    conn: conn,
    task: task,
    repo: repo
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    stage = with_target(view, "#engineer-stage")

    render_click(stage, "open_diff_comment", %{
      "path" => "rows.ex",
      "kind" => "added",
      "old_line" => "",
      "new_line" => "8"
    })

    view |> form("[data-qa='diff_comment_form']", %{"body" => "Name the eighth."}) |> render_submit()

    expected =
      Enum.join(
        [
          "  + line 2",
          "  + line 3",
          "  + line 4",
          "  + line 5",
          "  + line 6",
          "  + line 7",
          "> + line 8",
          "  + line 9",
          "  + line 10"
        ],
        "\n"
      )

    assert %DiffComment{context_text: ^expected} = Repo.get_by!(DiffComment, body: "Name the eighth.")

    File.write!(Path.join(repo, "rows.ex"), Enum.map_join(1..10, "", &"line #{&1}\n") <> "line 11\n")
    view |> element("#diff-filter-uncommitted") |> render_click()

    render_click(stage, "open_diff_comment", %{
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

  test "opening, saving and sending a comment recolors no line", %{conn: conn, task: task} do
    {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")
    code = html |> Floki.parse_document!() |> Floki.find(".diff-body .diff-code")
    assert [_first | _rest] = code

    render_click(with_target(view, "#engineer-stage"), "open_diff_comment", %{
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

      view |> with_target("#engineer-stage") |> render_click("select_diff_wrap", %{"wrap" => "wrap"})

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

      render_click(with_target(view, "#engineer-stage"), "open_diff_comment", %{
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
