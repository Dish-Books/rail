defmodule Rail.Mcp.Actions.AuthenticateRunTokenTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Mcp
  alias Rail.Mcp.RunContext
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    scope = system_scope()
    unique = System.unique_integer([:positive])

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{
        github_id: "art_gh_#{unique}",
        login: "art_#{unique}",
        email: "art_#{unique}@example.com"
      })

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, %{id: role_id} = role} = Roles.update_role(scope, engineer, %{mcp_tools: ["linear__*"]})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_run_token_#{unique}",
        identifier: "RT#{unique}-1",
        title: "Run token issue",
        state: :backlog,
        owner_user_id: user.id
      })
      |> Repo.insert!()

    {:ok, task} =
      %Task{id: UXID.generate!(prefix: "tsk")}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "run-token-#{unique}",
          worktree_path: "/tmp/run-token-#{unique}/worktree",
          scratch_path: "/tmp/run-token-#{unique}/scratch"
        },
        project.id
      )
      |> Repo.insert()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    {token, hash} = Mcp.issue_run_token()

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/run-token-#{unique}/stream.ndjson",
        status: :running,
        started_at: DateTime.utc_now(),
        mcp_token_hash: hash
      })
      |> Repo.insert!()

    %{token: token, os_process: os_process, issue: issue, user_id: user_id, role_id: role_id}
  end

  test "resolves a live turn's token to its role and the issue's assignee", %{
    token: token,
    user_id: user_id,
    role_id: role_id
  } do
    assert {:ok,
            %RunContext{
              os_process: %OsProcess{status: :running},
              role: %Role{id: ^role_id, mcp_tools: ["linear__*"]},
              user: %User{id: ^user_id}
            }} = Mcp.authenticate_run_token(token)
  end

  test "an unassigned issue gives no user", %{token: token, issue: issue} do
    issue |> Ecto.Changeset.change(owner_user_id: nil) |> Repo.update!()

    assert {:ok, %RunContext{user: nil}} = Mcp.authenticate_run_token(token)
  end

  test "rejects a finished turn's token and anything that is not a token", %{token: token, os_process: os_process} do
    assert {:error, :invalid_token} = Mcp.authenticate_run_token("not_a_real_token")
    assert {:error, :invalid_token} = Mcp.authenticate_run_token("")
    assert {:error, :invalid_token} = Mcp.authenticate_run_token(nil)

    os_process |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
    assert {:error, :invalid_token} = Mcp.authenticate_run_token(token)
  end

  describe "a triage pass's token" do
    setup do
      %{project: project, role: %{id: triage_role_id}} = triage_project()
      %{workspace: workspace, channel: channel} = connect_slack_channel(project)
      {:ok, thread} = Rail.Triage.handle_slack_event(workspace, slack_message_event(channel, %{}))
      %{id: triage_user_id} = triage_user = slack_user(workspace.external_id)
      {:ok, _project} = Rail.Projects.update_project(system_scope(), project, %{triage_user_id: triage_user.id})

      %{thread: thread, triage_role_id: triage_role_id, triage_user_id: triage_user_id}
    end

    test "resolves to the project's triage role and triage user while the pass holds the thread", %{
      thread: thread,
      triage_role_id: triage_role_id,
      triage_user_id: triage_user_id
    } do
      expect(Rail.Tools, :run_agent, fn _backend, _argv, opts ->
        assert {:ok,
                %RunContext{
                  os_process: nil,
                  role: %Role{id: ^triage_role_id, stage: :triage},
                  user: %User{id: ^triage_user_id}
                }} = Mcp.authenticate_run_token(opts[:env]["RAIL_MCP_TOKEN"])

        send(self(), {:token, opts[:env]["RAIL_MCP_TOKEN"]})

        thread
        |> Thread.scratch_path()
        |> Path.join("result.json")
        |> File.write!(Jason.encode!(%{"items" => []}))

        {:ok, ""}
      end)

      assert :ok = Rail.Triage.triage_thread(thread)
      assert_received {:token, token}
      assert {:error, :invalid_token} = Mcp.authenticate_run_token(token)
    end

    test "is dead once the pass is stale", %{thread: thread} do
      expect(Rail.Tools, :run_agent, fn _backend, _argv, opts ->
        stale = DateTime.shift(DateTime.utc_now(), minute: -46)

        Repo.update_all(from(t in Thread, where: t.id == ^thread.id),
          set: [triage_started_at: stale]
        )

        assert {:error, :invalid_token} = Mcp.authenticate_run_token(opts[:env]["RAIL_MCP_TOKEN"])
        {:ok, ""}
      end)

      assert :ok = Rail.Triage.triage_thread(thread)
    end

    test "is refused when the project has no triage role", %{thread: thread, triage_role_id: triage_role_id} do
      {:ok, role} = Roles.get_role(id: triage_role_id)
      {:ok, _deleted} = Roles.delete_role(system_scope(), role)
      {token, hash} = Mcp.issue_run_token()

      Repo.update_all(from(t in Thread, where: t.id == ^thread.id),
        set: [triage_started_at: DateTime.utc_now(), mcp_token_hash: hash]
      )

      assert {:error, :invalid_token} = Mcp.authenticate_run_token(token)
    end
  end
end
