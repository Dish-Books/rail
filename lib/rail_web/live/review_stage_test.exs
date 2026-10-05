defmodule RailWeb.Live.ReviewStageTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users

  setup %{conn: conn, project: project} do
    {:ok, user} = Users.register_oauth_user(%{github_id: "rst-1", login: "dana", name: "Dana", email: "dana@rst.example"})
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, review} = Roles.get_role(project_id: project.id, stage: :review)
    task = learnings_task(project, "RST-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    for {role, conversation} <- [{engineer, "sess_rst_engineer"}, {review, "sess_rst_review"}] do
      {:ok, _run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: conversation,
          started_at: DateTime.utc_now()
        })
    end

    checklist = learning(project, %{rule: "Handle nil", kind: :convention})
    calibration = learning(project, %{rule: "Don't flag a missing @doc on private components", kind: :calibration})

    for finding <- [
          %{
            key: "unhandled-nil",
            title: "Nil is not handled",
            file: "lib/a.ex",
            line: 3,
            severity: :major,
            recommendation: :fix,
            status: :open,
            rule: checklist.id
          },
          %{
            key: "missing-doc",
            title: "Missing @doc on comment_round/1",
            file: "lib/b.ex",
            line: 88,
            severity: :nit,
            recommendation: :skip,
            status: :open,
            rule: calibration.id
          },
          %{
            key: "missing-doc-2",
            title: "Missing @doc on round_badge/1",
            file: "lib/b.ex",
            line: 131,
            severity: :nit,
            recommendation: :skip,
            status: :open,
            rule: calibration.id
          }
        ],
        do: {:ok, _saved} = Pipeline.save_review_finding(task, finding)

    %{conn: log_in_user(conn, user), task: task, calibration: calibration}
  end

  test "suppressed findings sit apart, collapsed, with their count, and a checklist finding shows its rule", %{
    conn: conn,
    task: task
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")

    assert has_element?(view, "#finding-unhandled-nil [data-qa=review_finding_rule]", "rule")
    assert has_element?(view, "#review-suppressed-toggle[aria-expanded=false]", "Suppressed (2)")
    refute has_element?(view, "#finding-missing-doc")
    assert has_element?(view, "[data-qa=review_finding_tally]", "1 to decide")

    view |> element("#review-suppressed-toggle") |> render_click()
    assert has_element?(view, "#finding-missing-doc[data-state=suppressed]", "Missing @doc on comment_round/1")

    view |> element("#review-suppressed-toggle") |> render_click()
    refute has_element?(view, "#finding-missing-doc")
  end

  test "a suppressed finding shows its rule, offers Fix only, and Fix moves it into the list", %{
    conn: conn,
    task: task,
    calibration: calibration
  } do
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-suppressed-toggle") |> render_click()
    view |> element("#finding-missing-doc") |> render_click()

    assert has_element?(view, "[data-qa=finding_suppressed]", "Suppressed")
    assert has_element?(view, "#finding-suppressor", "Don't flag a missing @doc on private components")
    assert has_element?(view, "#finding-suppressor", "Suppressed 2 findings · never overridden")
    assert has_element?(view, "#finding-open-rule[href='/learnings/#{calibration.id}']")
    assert has_element?(view, "#decide-fix-missing-doc")
    refute has_element?(view, "#decide-skip-missing-doc")
    refute has_element?(view, "[data-qa=finding_undecided]")

    view |> element("#decide-fix-missing-doc") |> render_click()

    assert %ReviewFinding{decision: :fix} = Repo.get_by!(ReviewFinding, task_id: task.id, key: "missing-doc")
    assert has_element?(view, "#finding-missing-doc[data-state=to_fix]")
    assert has_element?(view, "#review-suppressed-toggle", "Suppressed (1)")
  end

  test "a suppressed finding says how often its rule was overridden", %{
    conn: conn,
    project: project,
    task: task,
    calibration: calibration
  } do
    other = learnings_task(project, "RST-2", :review)

    override = fn key ->
      findings =
        for finding <- [
              %{key: key, title: key, severity: :nit, recommendation: :skip, status: :open, rule: calibration.id}
            ] do
          {:ok, saved} = Pipeline.save_review_finding(other, finding)
          saved
        end

      {:ok, fixed} = Pipeline.decide_review_finding(system_scope(), Enum.find(findings, &(&1.key == key)), :fix)
      {:ok, _flagged} = Rail.Learnings.record_overrides(other, [fixed])
    end

    override.("elsewhere-1")
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-suppressed-toggle") |> render_click()
    view |> element("#finding-missing-doc") |> render_click()
    assert has_element?(view, "#finding-suppressor", "overridden once")

    override.("elsewhere-2")
    {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
    view |> element("#review-suppressed-toggle") |> render_click()
    view |> element("#finding-missing-doc") |> render_click()
    assert has_element?(view, "#finding-suppressor", "overridden 2 times")
  end
end
