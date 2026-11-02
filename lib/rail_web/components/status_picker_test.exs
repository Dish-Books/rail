defmodule RailWeb.Components.StatusPickerTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Users

  @statuses [
    %{id: "st_todo", name: "Todo", state: :backlog},
    %{id: "st_started", name: "In Progress", state: :in_progress},
    %{id: "st_deploy", name: "Waiting on deploy", state: :in_progress},
    %{id: "st_review", name: "In Review", state: :in_review},
    %{id: "st_done", name: "Done", state: :done}
  ]

  setup %{conn: conn, project: project} do
    stub(Issues, :get_cycles, fn _project -> {:ok, %{cycles: [], statuses: []}} end)
    stub(Issues, :get_blockers, fn _issues -> %{} end)
    stub(Issues, :link_pull_request, fn _scope, _issue -> {:ok, nil} end)

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_status_picker",
        login: "status_picker",
        email: "status_picker@example.com",
        admin: true
      })

    insert = fn identifier, attrs ->
      %Issue{}
      |> Issue.tracker_changeset(
        Map.merge(
          %{
            project_id: project.id,
            external_id: "lin_#{identifier}",
            identifier: identifier,
            title: "Title #{identifier}",
            state: :in_progress,
            state_name: "In Progress",
            external_updated_at: ~U[2026-11-01 09:00:00.000000Z]
          },
          attrs
        )
      )
      |> Repo.insert!()
    end

    answered = fn name, type ->
      fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueUpdate" => %{
              "success" => true,
              "issue" => %{
                "state" => %{"name" => name, "type" => type},
                "updatedAt" => "2026-11-01T10:00:00.000Z"
              }
            }
          }
        })
      end
    end

    %{conn: log_in_user(conn, user), insert: insert, issue: insert.("PIC-1", %{}), answered: answered}
  end

  describe "on a row" do
    test "a click opens the statuses with the current one marked, and leaves the page where it is", %{
      conn: conn,
      issue: %{id: id}
    } do
      test = self()

      stub(Issues, :get_statuses, fn _scope, _project ->
        send(test, :read)
        {:ok, @statuses}
      end)

      {:ok, view, _html} = live(conn, ~p"/issues")

      assert has_element?(view, "#status-picker-#{id}-trigger[aria-expanded='false'][title='In Progress']")
      refute has_element?(view, "#status-picker-#{id}-menu")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      assert has_element?(view, "#issues-view")
      assert has_element?(view, "#status-picker-#{id}-trigger[aria-expanded='true']")
      assert has_element?(view, "#status-picker-#{id}-menu[popover='manual'][phx-hook='StatusMenu']")
      assert has_element?(view, "#status-picker-#{id}-menu [role='menu'][aria-label='Change status']")
      assert has_element?(view, "#status-picker-#{id}-status-st_review", "In Review")
      assert has_element?(view, "#status-picker-#{id}-status-st_deploy", "Waiting on deploy")
      assert has_element?(view, "#status-picker-#{id}-status-st_started[aria-current='true']", "Current status")
      refute has_element?(view, "#status-picker-#{id}-status-st_review[aria-current]")
      assert_received :read
    end

    test "the menu appears once the statuses arrive, and they are read once", %{conn: conn, issue: %{id: id}} do
      test = self()

      stub(Issues, :get_statuses, fn _scope, _project ->
        send(test, {:reading, self()})

        receive do
          :answer -> {:ok, @statuses}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      view |> element("#status-picker-#{id}-trigger") |> render_click()

      assert_receive {:reading, reader}
      refute has_element?(view, "#status-picker-#{id}-menu [role='menu']")
      refute has_element?(view, "#status-picker-#{id}-menu [role='alert']")

      send(reader, :answer)
      render_async(view)
      assert has_element?(view, "#status-picker-#{id}-status-st_review")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      refute has_element?(view, "#status-picker-#{id}-menu")
      assert has_element?(view, "#status-picker-#{id}-trigger[aria-expanded='false']")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      assert has_element?(view, "#status-picker-#{id}-status-st_review")
      refute_received {:reading, _second}
    end

    test "a click away during the read reaches the hook, and the answer opens no menu", %{conn: conn, issue: %{id: id}} do
      test = self()

      stub(Issues, :get_statuses, fn _scope, _project ->
        send(test, {:reading, self()})

        receive do
          :answer -> {:ok, @statuses}
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      view |> element("#status-picker-#{id}-trigger") |> render_click()

      assert_receive {:reading, reader}
      assert has_element?(view, "#status-picker-#{id}-menu[phx-hook='StatusMenu']")

      view |> element("#status-picker-#{id}-menu") |> render_hook("close")
      send(reader, :answer)
      render_async(view)

      refute has_element?(view, "#status-picker-#{id}-menu")
      assert has_element?(view, "#status-picker-#{id}-trigger[aria-expanded='false']")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      assert has_element?(view, "#status-picker-#{id}-status-st_review")
      refute_received {:reading, _second}
    end

    test "Escape or a click away closes it, and only an open menu listens for Escape", %{conn: conn, issue: %{id: id}} do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")

      refute has_element?(view, "#status-picker-#{id}[phx-window-keydown]")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      # The empty binding keeps a click on the menu's padding off the row, without stopping it.
      assert has_element?(view, "#status-picker-#{id}-menu[phx-click='[]']")

      view |> element("#status-picker-#{id}") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#status-picker-#{id}-menu")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      view |> element("#status-picker-#{id}-menu") |> render_hook("close")
      refute has_element?(view, "#status-picker-#{id}-menu")
    end

    test "picking the current status sends nothing and closes the menu", %{conn: conn, issue: %{id: id}} do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      # No Req.Test stub is set, so any request to Linear would raise here.
      view |> element("#status-picker-#{id}-status-st_started") |> render_click()

      refute has_element?(view, "#status-picker-#{id}-menu")
      assert %Issue{state_name: "In Progress"} = Repo.get!(Issue, id)
    end

    test "a status the menu never offered does nothing", %{conn: conn, issue: %{id: id}} do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> with_target("#status-picker-#{id}") |> render_click("pick", %{"status_id" => "st_other"})
      assert has_element?(view, "#issues-view")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      view |> with_target("#status-picker-#{id}") |> render_click("pick", %{"status_id" => "st_other"})
      assert has_element?(view, "#status-picker-#{id}-menu")
      assert %Issue{state_name: "In Progress"} = Repo.get!(Issue, id)
    end

    test "a refused pick keeps the menu open and says the status did not change, until it closes", %{
      conn: conn,
      issue: %{id: id}
    } do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"issueUpdate" => %{"success" => false}}}))
      view |> element("#status-picker-#{id}-status-st_review") |> render_click()

      assert has_element?(
               view,
               "#status-picker-#{id}-menu [role='alert']",
               "Could not change the status in Linear. It is still In Progress."
             )

      assert has_element?(view, "#status-picker-#{id}-status-st_started[aria-current='true']")
      assert has_element?(view, "#issue-card-#{id} [data-qa='issue-status-badge'][title='In Progress']")
      assert %Issue{state_name: "In Progress"} = Repo.get!(Issue, id)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      view |> element("#status-picker-#{id}-trigger") |> render_click()
      refute has_element?(view, "#status-picker-#{id}-menu [role='alert']")
    end

    test "the refusal note goes once a live update moves the ticket to another status", %{
      conn: conn,
      issue: %{id: id} = issue
    } do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"issueUpdate" => %{"success" => false}}}))
      view |> element("#status-picker-#{id}-status-st_review") |> render_click()
      assert has_element?(view, "#status-picker-#{id}-menu [role='alert']")

      issue |> Issue.tracker_changeset(%{state: :in_review, state_name: "In Review"}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      assert has_element?(view, "#status-picker-#{id}-status-st_review[aria-current='true']")
      assert has_element?(view, "#status-picker-#{id}-menu")
      refute has_element?(view, "#status-picker-#{id}-menu [role='alert']")
    end

    test "the refusal note stays through a live update that leaves the status alone", %{
      conn: conn,
      issue: %{id: id} = issue
    } do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)
      {:ok, view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, &Req.Test.json(&1, %{"data" => %{"issueUpdate" => %{"success" => false}}}))
      view |> element("#status-picker-#{id}-status-st_review") |> render_click()

      issue |> Issue.tracker_changeset(%{title: "Renamed in Linear"}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})

      assert has_element?(view, "#issue-card-#{id}", "Renamed in Linear")
      assert has_element?(view, "#status-picker-#{id}-menu [role='alert']", "It is still In Progress.")
    end

    test "a live update that moves a row leaves its menu, and a pick there acts on its own issue", %{
      conn: conn,
      issue: %{id: id},
      insert: insert,
      answered: answered
    } do
      %{id: other_id} = other = insert.("PIC-2", %{})
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      other |> Issue.tracker_changeset(%{title: "Moved to the top"}) |> Repo.update!()
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, other_id})
      assert has_element?(view, "#issue-card-#{other_id}", "Moved to the top")
      assert has_element?(view, "#status-picker-#{id}-menu")

      Req.Test.expect(Rail.Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"id" => "lin_PIC-1"} = Jason.decode!(body)["variables"]
        answered.("In Review", "started").(conn)
      end)

      view |> element("#status-picker-#{id}-status-st_review") |> render_click()

      assert %Issue{state_name: "In Review"} = Repo.get!(Issue, id)
      assert %Issue{state_name: "In Progress"} = Repo.get!(Issue, other_id)
    end

    test "a pick queued behind the one that closed the menu still reaches the tracker", %{
      conn: conn,
      issue: %{id: id},
      answered: answered
    } do
      test = self()
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)

      {:ok, view, _html} = live(conn, ~p"/issues")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      Req.Test.expect(Rail.Linear, 2, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"input" => %{"stateId" => state_id}} = Jason.decode!(body)["variables"]
        send(test, {:sent, state_id})

        case state_id do
          "st_review" -> answered.("In Review", "started").(conn)
          "st_started" -> answered.("In Progress", "started").(conn)
        end
      end)

      view |> with_target("#status-picker-#{id}") |> render_click("pick", %{"status_id" => "st_review"})
      view |> with_target("#status-picker-#{id}") |> render_click("pick", %{"status_id" => "st_started"})

      assert_received {:sent, "st_review"}
      assert_received {:sent, "st_started"}
      assert %Issue{state_name: "In Progress"} = Repo.get!(Issue, id)
    end
  end

  describe "when the statuses cannot be read" do
    test "the menu says so in place of the list, and Try again reads them again", %{conn: conn, issue: %{id: id}} do
      {:ok, answers} = Agent.start_link(fn -> [{:error, :down}, {:error, :down}, {:ok, @statuses}] end)

      stub(Issues, :get_statuses, fn _scope, _project ->
        Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end)
      end)

      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "#status-picker-#{id}-menu [role='alert']",
               "Linear did not answer, so the statuses are not listed."
             )

      refute has_element?(view, "#status-picker-#{id}-menu [role='menu']")

      view |> element("#status-picker-#{id}-retry") |> render_click()
      render_async(view)
      assert has_element?(view, "#status-picker-#{id}-retry", "Try again")

      view |> element("#status-picker-#{id}-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#status-picker-#{id}-retry")
      assert has_element?(view, "#status-picker-#{id}-status-st_review")
    end

    test "closing and opening reads again, with no old failure on show", %{conn: conn, issue: %{id: id}} do
      test = self()

      stub(Issues, :get_statuses, fn _scope, _project ->
        send(test, {:reading, self()})

        receive do
          answer -> answer
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      assert_receive {:reading, first}
      send(first, {:error, :down})
      render_async(view)
      assert has_element?(view, "#status-picker-#{id}-retry")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      view |> element("#status-picker-#{id}-trigger") |> render_click()
      assert_receive {:reading, second}
      refute has_element?(view, "#status-picker-#{id}-menu [role='menu']")
      refute has_element?(view, "#status-picker-#{id}-menu [role='alert']")

      send(second, {:ok, @statuses})
      render_async(view)
      assert has_element?(view, "#status-picker-#{id}-status-st_review")
    end

    test "a read that crashes is a failed read, and a GitHub issue names GitHub", %{
      conn: conn,
      github_project: project
    } do
      %{id: id} = github_issue(project, %{number: 401, state: :backlog, state_name: "Backlog"})
      stub(Issues, :get_statuses, fn _scope, _project -> raise "GitHub is down" end)

      {:ok, view, _html} = live(conn, ~p"/issues")

      view |> element("#status-picker-#{id}-trigger") |> render_click()
      render_async(view)

      assert has_element?(view, "#status-picker-#{id}-menu [role='alert']", "GitHub did not answer")
    end
  end

  describe "in Properties" do
    test "the Status line opens the same menu and reads as the owner line does", %{
      conn: conn,
      issue: %{id: id},
      answered: answered
    } do
      stub(Issues, :get_statuses, fn _scope, _project -> {:ok, @statuses} end)

      {:ok, view, _html} = live(conn, ~p"/issues/PIC-1")
      Req.Test.allow(Rail.Linear, self(), view.pid)

      assert has_element?(view, "button#issue-status[aria-haspopup='menu']", "In Progress")

      view |> element("#issue-status") |> render_click()
      render_async(view)
      assert has_element?(view, "#issue-status-picker-#{id}-menu[data-trigger='issue-status']")

      Req.Test.expect(Rail.Linear, answered.("In Review", "started"))
      view |> element("#issue-status-picker-#{id}-status-st_review") |> render_click()

      assert has_element?(view, "#issue-status", "In Review")
      assert has_element?(view, "#issue-status .text-emerald-500")
      refute has_element?(view, "#issue-status-picker-#{id}-menu")
    end
  end
end
