defmodule Rail.Tools.Actions.RefreshUsageTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  # The backend lib/test_helper.exs seeds for the shared project's roles is the oldest, so
  # it heads every list as `_seeded`.

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "probes each backend off its own row and upserts what it reports" do
    claude = System.find_executable("sh")

    tokened = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude}))
    Repo.update!(Backend.token_changeset(tokened, "tok"))
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude, label: "no token"}))
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/missing/claude", label: "no cli"}))

    # A backend is read off its row, so no CLI is ever run.
    reject(&Tools.run/3)

    assert {:ok,
            [
              _seeded,
              %Backend{id: claude_id, name: :claude, account_label: "Long-lived token", status: :ready},
              %Backend{id: no_token_id, label: "no token", status: :signed_out},
              %Backend{label: "no cli", status: :not_configured, session_lost_at: nil}
            ]} = Tools.refresh_usage()

    # Refreshing again updates the same rows rather than inserting new ones.
    assert {:ok, [_seeded, %Backend{id: ^claude_id}, %Backend{id: ^no_token_id}, _no_cli]} = Tools.refresh_usage()

    # The config the user owns survives a refresh, and a backend that was never
    # ready has lost nothing.
    assert %Backend{executable_path: ^claude, status: :ready, oauth_token: "tok"} = Repo.get!(Backend, claude_id)
    assert %Backend{session_lost_at: nil} = Repo.get!(Backend, no_token_id)
  end

  test "a ready backend found signed out is marked and its projects told once, until it has a token again", %{
    project: project
  } do
    scope = system_scope()
    claude = System.find_executable("sh")
    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude, label: "work"}))
    # Ready on its row, yet with no token to run on: nobody signed it out.
    backend = Repo.update!(Backend.usage_changeset(backend, %{status: :ready, account_label: "Long-lived token"}))

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, _role} = Roles.update_role(scope, role, %{backend_id: backend.id})
    %{workspace: workspace} = connect_slack_channel(project)

    {:ok, _project} =
      Projects.update_project(scope, project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posted, Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000900"})
    end)

    assert {:ok, _refreshed} = Tools.refresh_usage()

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{} = lost_at} =
             lost = Repo.get!(Backend, backend.id)

    assert_received {:posted, %{"channel" => "C_LEARN", "text" => text}}
    assert text =~ "Rail's work backend lost its sign-in."
    assert text =~ "/settings/backends"

    # Still signed out on the next probe: nothing new to say.
    assert {:ok, _refreshed} = Tools.refresh_usage()
    assert %Backend{session_lost_at: ^lost_at} = Repo.get!(Backend, backend.id)
    refute_received {:posted, _again}

    # A new token forgets the loss, and the next probe finds the backend ready.
    Repo.update!(Backend.token_changeset(lost, "tok"))
    assert {:ok, _refreshed} = Tools.refresh_usage()
    assert %Backend{status: :ready, session_lost_at: nil} = tokened = Repo.get!(Backend, backend.id)
    refute_received {:posted, _again}

    # A channel that cannot be posted to does not stop the refresh.
    Req.Test.stub(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "channel_not_found"}))
    Repo.update!(Backend.token_changeset(tokened, nil))

    assert capture_log(fn -> assert {:ok, _refreshed} = Tools.refresh_usage() end) =~
             "Could not tell C_LEARN that a backend lost its sign-in"

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{}} = Repo.get!(Backend, backend.id)
  end
end
