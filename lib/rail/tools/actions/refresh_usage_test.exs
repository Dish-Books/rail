defmodule Rail.Tools.Actions.RefreshUsageTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  # The backend lib/test_helper.exs seeds for the shared project's roles is the oldest, so
  # it heads every list as `_seeded`.

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "probes each backend at its configured path and upserts what it reports" do
    # The path the probe runs comes off the backend row, so it must exist.
    claude = System.find_executable("sh")
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude}))

    stub(Tools, :run, fn
      ^claude, _args, _opts -> {~s({"loggedIn":true,"email":"claude@example.com","subscriptionType":"Pro"}), 0}
      _seeded, _args, _opts -> {~s({"loggedIn":false}), 0}
    end)

    claude_config =
      ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[) <>
        ~s({"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"}) <>
        ~s(]}}})

    stub(File, :read, fn _path -> {:ok, claude_config} end)

    assert {:ok,
            [
              _seeded,
              %Backend{
                id: claude_id,
                name: :claude,
                account_label: "claude@example.com",
                status: :ready,
                usage: [_session]
              }
            ]} = Tools.refresh_usage()

    # Refreshing again updates the same row rather than inserting a new one.
    assert {:ok, [_seeded, %Backend{id: ^claude_id}]} = Tools.refresh_usage()

    # The config the user owns survives a refresh.
    assert %Backend{executable_path: ^claude, status: :ready} = Repo.get!(Backend, claude_id)
  end

  test "probes every account as the account in its own config directory" do
    claude = System.find_executable("sh")

    %Backend{id: home_id} = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude}))

    %Backend{id: work_id} =
      work = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude, label: "work"}))

    work_dir = Backend.config_dir(work)

    # Each CLI call answers as whichever account its environment points at.
    stub(Tools, :run, fn _exe, _args, opts ->
      email = if opts[:env]["CLAUDE_CONFIG_DIR"] == work_dir, do: "work@example.com", else: "home@example.com"
      {~s({"loggedIn":true,"email":"#{email}"}), 0}
    end)

    stub(File, :read, fn _path -> {:ok, ~s({"cachedUsageUtilization":{}})} end)

    assert {:ok,
            [
              _seeded,
              %Backend{id: ^home_id, account_label: "home@example.com"},
              %Backend{id: ^work_id, account_label: "work@example.com"}
            ]} = Tools.refresh_usage()
  end

  test "records that a configured backend's binary has gone missing" do
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/non/existent/claude"}))
    reason = "Executable not found at '/non/existent/claude'"

    assert {:ok, [_seeded, %Backend{status: :not_configured, unavailable_reason: ^reason, session_lost_at: nil}]} =
             Tools.refresh_usage()
  end

  test "a ready backend found signed out is marked and its projects told once, until it is signed in again", %{
    project: project
  } do
    scope = system_scope()
    claude = System.find_executable("sh")

    # It offers the model the project's roles run, which is how the project is told.
    backend =
      Repo.insert!(
        Backend.changeset(%Backend{}, %{
          name: :claude,
          executable_path: claude,
          label: "work",
          models: [%{id: "claude-opus-5-5"}]
        })
      )

    # Ready on its row, yet signed out when the CLI is asked: nobody signed it out.
    backend = Repo.update!(Backend.usage_changeset(backend, %{status: :ready, account_label: "me@example.com"}))
    # The seeded account answers as unreadable, which loses it nothing.
    stub(Tools, :run, fn
      ^claude, ["auth" | _rest], _opts -> {~s({"loggedIn":false}), 0}
      _seeded, _args, _opts -> {"", 1}
    end)

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

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{} = lost_at} = Repo.get!(Backend, backend.id)

    assert_received {:posted, %{"channel" => "C_LEARN", "text" => text}}
    assert text =~ "Rail's work backend lost its sign-in."
    assert text =~ "/settings/backends"

    # Still signed out on the next probe: nothing new to say.
    assert {:ok, _refreshed} = Tools.refresh_usage()
    assert %Backend{session_lost_at: ^lost_at} = Repo.get!(Backend, backend.id)
    refute_received {:posted, _again}

    # Signed in again, the next probe finds it ready and forgets the loss.
    stub(Tools, :run, fn
      ^claude, ["auth" | _rest], _opts -> {~s({"loggedIn":true,"email":"me@example.com"}), 0}
      _usage_or_seeded, _args, _opts -> {"", 1}
    end)

    stub(File, :read, fn _path -> {:ok, ~s({"cachedUsageUtilization":{}})} end)
    assert {:ok, _refreshed} = Tools.refresh_usage()
    assert %Backend{status: :ready, session_lost_at: nil} = Repo.get!(Backend, backend.id)
    refute_received {:posted, _again}

    # A channel that cannot be posted to does not stop the refresh.
    Req.Test.stub(Rail.Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "channel_not_found"}))

    stub(Tools, :run, fn
      ^claude, ["auth" | _rest], _opts -> {~s({"loggedIn":false}), 0}
      _seeded, _args, _opts -> {"", 1}
    end)

    assert capture_log(fn -> assert {:ok, _refreshed} = Tools.refresh_usage() end) =~
             "Could not tell C_LEARN that a backend lost its sign-in"

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{}} = Repo.get!(Backend, backend.id)
  end
end
