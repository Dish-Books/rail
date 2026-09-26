defmodule RailTest.TriageHelpers do
  @moduledoc """
  Arranges what every triage test stands on: a Slack workspace answered by
  `Req.Test`, a channel connected to a project, and events as Slack sends them.
  Everything persisted goes through the contexts' public APIs.
  """

  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  @doc """
  Answers Slack's read endpoints for the calling test. `chat.postMessage` is
  deliberately absent, so a post the test did not expect crashes it.

  Takes `:team_id`, `:channels` (`[{id, name}]`), `:users` (`%{id => name}`) and
  `:replies` (the messages `conversations.replies` returns).
  """
  def stub_slack(opts \\ []) do
    team_id = Keyword.get(opts, :team_id, "T_TEST")
    channels = Keyword.get(opts, :channels, [])
    users = Keyword.get(opts, :users, %{})
    replies = Keyword.get(opts, :replies, [])

    Req.Test.stub(Rail.Slack, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      body =
        case conn.request_path do
          "/api/auth.test" ->
            %{"team_id" => team_id, "bot_id" => "B_RAIL", "user_id" => "U_RAIL"}

          "/api/conversations.list" ->
            %{"channels" => Enum.map(channels, fn {id, name} -> %{"id" => id, "name" => name} end)}

          "/api/users.info" ->
            user_id = conn.query_params["user"]
            %{"user" => %{"id" => user_id, "real_name" => Map.get(users, user_id, user_id)}}

          "/api/conversations.replies" ->
            %{"messages" => replies}

          "/api/chat.getPermalink" ->
            %{"permalink" => "https://slack.example/archives/#{conn.query_params["channel"]}/p1"}
        end

      Req.Test.json(conn, Map.put(body, "ok", true))
    end)

    :ok
  end

  @doc """
  Adds a Slack workspace and connects one channel of it to `project`. Returns
  `%{workspace: workspace, channel: channel}`. Takes `:bot_messages` for the
  channel's option to triage bot posts.
  """
  def connect_slack_channel(project, opts \\ []) do
    unique = System.unique_integer([:positive])
    team_id = "T#{unique}"
    channel_id = "C#{unique}"
    stub_slack(Keyword.merge([team_id: team_id, channels: [{channel_id, "rail-feedback"}]], opts))

    {:ok, workspace} =
      Projects.create_slack_workspace(Scope.for_system(), %{
        "name" => "Acme",
        "token" => "xoxb-bot",
        "app_token" => "xapp"
      })

    {:ok, [_channel]} =
      Projects.set_slack_channels(Scope.for_system(), project, [
        %{"external_id" => channel_id, "triage_bot_messages" => Keyword.get(opts, :bot_messages, false)}
      ])

    {:ok, channel} = Projects.get_slack_channel(external_id: channel_id)

    %{workspace: workspace, channel: channel}
  end

  @doc """
  An Events API `message` payload in `channel`, as Slack delivers it.
  """
  def slack_message_event(channel, fields) do
    event =
      Map.merge(
        %{
          "type" => "message",
          "channel" => channel.external_id,
          "channel_type" => "channel",
          "user" => "U_PRIYA",
          "text" => "hello",
          "ts" => "1790000000.000100"
        },
        fields
      )

    %{"type" => "event_callback", "event" => event}
  end

  @doc """
  A project on a real clone of a real remote, with a Triage role, so a pass can
  check its code out. Returns `%{project: project, role: role, remote: remote}`.
  """
  def triage_project do
    Req.Test.stub(Rail.GitHub.Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = RailTest.GitHelpers.create_temp_git_repo(prefix: "rail_triage_remote")
    clone = RailTest.GitHelpers.create_temp_git_repo(prefix: "rail_triage_clone")
    RailTest.GitHelpers.git!(clone, ["remote", "add", "origin", remote])
    unique = System.unique_integer([:positive])

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "teams" => %{
            "nodes" => [%{"id" => "lin_team_tri", "states" => %{"nodes" => [%{"id" => "st_tri", "type" => "triage"}]}}]
          }
        }
      })
    end)

    {:ok, project} =
      Projects.create_project(Scope.for_system(), %{
        name: "Triage Project #{unique}",
        github_repo: "example/triage-#{unique}",
        github_installation_id: 1,
        default_branch: "main",
        linear_team_key: "TRI",
        linear_workspace_id: "lw_test_seed",
        clone_path: clone
      })

    {:ok, role} =
      Roles.create_role(Scope.for_system(), project, %{
        stage: :triage,
        name: "Triage",
        model: "claude-opus-5-5",
        system_prompt: "You triage.",
        backend_id: "bkd_test_seed"
      })

    %{project: project, role: role, remote: remote}
  end

  @doc """
  Runs a real pass on `thread` with the agent answering `result`, and returns
  the thread as `Rail.Triage.get_triage_thread/2` loads it.
  """
  def triage_with(thread, result) do
    Mimic.expect(Rail.Tools, :run_agent, fn _backend, _argv, _opts ->
      thread
      |> Rail.Triage.Schemas.Thread.scratch_path()
      |> Path.join("result.json")
      |> File.write!(Jason.encode!(result))

      {:ok, ""}
    end)

    :ok = Rail.Triage.triage_thread(thread)
    {:ok, thread} = Rail.Triage.get_triage_thread(Scope.for_system(), thread.id)
    thread
  end

  @doc """
  A bug item as an agent writes one, with an issue and a reply drafted.
  """
  def triage_bug(overrides \\ %{}) do
    Map.merge(
      %{
        "key" => "stuck-at-design",
        "kind" => "bug",
        "title" => "Approved tasks stuck at Design",
        "verdict" => "confirmed",
        "summary" => "enter_stage writes the stage, then the role lookup raises.",
        "evidence" => [%{"file" => "lib/enter_stage.ex", "lines" => "42", "excerpt" => "Roles.get_role", "holds" => true}],
        "assumptions" => [%{"text" => "Billing is the BILL project."}],
        "issue_note" => "No existing issue covers this.",
        "issue" => %{"title" => "Approve leaves tasks at Design", "description" => "Root cause.", "priority" => "high"},
        "reply" => "Thanks Priya, we reproduced this. Filed as {issue link}."
      },
      overrides
    )
  end

  @doc """
  A user who linked Slack in the workspace `team_id`.
  """
  def slack_user(team_id, name \\ "Michael") do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "slack_#{unique}",
        login: "slack_#{unique}",
        name: name,
        email: "slack_#{unique}@example.com"
      })

    {:ok, user} =
      Users.update_user(Scope.for_system(), user, %{
        slack_user_id: "U_#{unique}",
        slack_team_id: team_id,
        slack_name: name,
        slack_access_token: "xoxp-#{unique}"
      })

    user
  end
end
