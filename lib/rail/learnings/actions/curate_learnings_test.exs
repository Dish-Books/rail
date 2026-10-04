defmodule Rail.Learnings.Actions.CurateLearningsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.CuratorPass
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Learnings.Workers.CollectPullRequest
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup do
    %{project: project} = triage_project()

    {:ok, _curator} =
      Roles.create_role(system_scope(), project, %{
        stage: :curator,
        name: "Curator",
        model: "claude-opus-5-5",
        system_prompt: "You curate.",
        backend_id: "bkd_test_seed"
      })

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/" <> _pulls ->
          Req.Test.json(conn, [
            %{
              "number" => 31,
              "merged_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
            }
          ])
      end
    end)

    tasks = for n <- 1..4, do: learnings_task(project, "CUR-#{n}")

    sighting = fn task, attrs ->
      Repo.insert!(
        Map.merge(
          %Observation{project_id: project.id, task_id: task.id, source_kind: :extraction, text: "Use the factory"},
          attrs
        )
      )
    end

    %{project: project, tasks: tasks, sighting: sighting}
  end

  test "proposals are inserted, those naming another project's ids are dropped, and what was read is stamped", %{
    project: project,
    tasks: [one, two | _rest],
    sighting: sighting
  } do
    first = sighting.(one, %{})
    second = sighting.(two, %{text: "Rows through the factory"})
    retiring = learning(project, %{rule: "Use SyncIssues", kind: :environment})
    test = self()

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      send(
        test,
        {:read, File.read!(Path.join(opts[:cd], "observations.md")), File.read!(Path.join(opts[:cd], "rules.md"))}
      )

      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "outcomes" => [%{"observation" => second.id, "outcome" => "dismiss"}],
          "proposals" => [
            %{
              "action" => "add",
              "title" => "Use the factory",
              "rule" => "Tests build rows with the factory",
              "kind" => "convention",
              "roles" => ["engineer", "nonsense"],
              "evidence" => [first.id]
            },
            %{"action" => "retire", "learning" => retiring.id, "summary" => "Code gone in #109"},
            %{"action" => "retire", "learning" => "lrn_foreign"},
            %{"action" => "merge", "targets" => ["lrn_foreign"], "rule" => "x", "kind" => "convention"},
            %{"action" => "add", "evidence" => ["obs_not_read"], "rule" => "y", "kind" => "convention"},
            %{"action" => "nonsense"},
            "not a proposal"
          ]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{id: pass_id, finished_at: %DateTime{}, error: nil}} = Learnings.curate_learnings(project)

    assert_received {:read, observations, rules}
    assert observations =~ first.id
    assert rules =~ retiring.id

    assert [
             %LearningProposal{
               action: :add,
               curator_pass_id: ^pass_id,
               learning: %Learning{id: draft_id, status: :proposed, roles: [:engineer]}
             },
             %LearningProposal{action: :retire, summary: "Code gone in #109"}
           ] =
             Repo.all(
               from p in LearningProposal, where: p.project_id == ^project.id, order_by: p.action, preload: :learning
             )

    assert %Observation{curator_pass_id: ^pass_id, learning_id: ^draft_id} = Repo.reload!(first)
    assert %Observation{curator_pass_id: ^pass_id, learning_id: nil} = Repo.reload!(second)
    assert_enqueued(worker: CollectPullRequest, args: %{project_id: project.id, number: 31})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      refute File.read!(Path.join(opts[:cd], "observations.md")) =~ first.id
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"outcomes": [], "proposals": []}))
      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{}} = Learnings.curate_learnings(project)
  end

  test "a failed pass stamps nothing, so the next pass reads it", %{
    project: project,
    tasks: [one | _rest],
    sighting: sighting
  } do
    observation = sighting.(one, %{})
    expect(Tools, :run_agent, fn _backend, _argv, _opts -> {:error, {:exit, 2}} end)

    assert {:error, {{:exit, 2}, %CuratorPass{finished_at: nil, error: "{:exit, 2}"}}} =
             Learnings.curate_learnings(project)

    assert %Observation{curator_pass_id: nil} = Repo.reload!(observation)
  end

  test "an add backed by three tasks that were not abandoned is activated as auto", %{
    project: project,
    tasks: [one, two, three, four],
    sighting: sighting
  } do
    backed = Enum.map([one, two, three], &sighting.(&1, %{}))
    abandoned = sighting.(four, %{abandoned: true})
    %{workspace: workspace, channel: channel} = connect_slack_channel(project)

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => channel.external_id
      })

    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/chat.postMessage" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:posted, Jason.decode!(body)["text"]})
          Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000902"})

        "/api/chat.getPermalink" ->
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p3"})
      end
    end)

    curate = fn proposals ->
      expect(Tools, :run_agent, fn _backend, _argv, opts ->
        File.write!(Path.join(opts[:cd], "result.json"), Jason.encode!(%{"proposals" => proposals}))
        {:ok, ""}
      end)

      {:ok, pass} = Learnings.curate_learnings(project)
      pass
    end

    curate.([
      %{"action" => "add", "rule" => "Three tasks", "kind" => "convention", "evidence" => Enum.map(backed, & &1.id)},
      %{"action" => "add", "rule" => "Two and an abandoned one", "kind" => "convention", "evidence" => [abandoned.id]}
    ])

    assert %Learning{status: :active, auto: true, approved_by_id: nil} = Repo.get_by!(Learning, rule: "Three tasks")
    assert %Learning{status: :proposed} = Repo.get_by!(Learning, rule: "Two and an abandoned one")
    assert_received {:posted, text}
    assert text =~ "• Three tasks (3 finished tasks)"
    refute text =~ "Provisional since"
  end

  test "a later sighting linked to a pending add counts towards activating it", %{
    project: project,
    tasks: [one, two, three | _rest],
    sighting: sighting
  } do
    early = Enum.map([one, two], &sighting.(&1, %{}))

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [
            %{
              "action" => "add",
              "rule" => "Use the factory",
              "kind" => "convention",
              "evidence" => Enum.map(early, & &1.id)
            }
          ]
        })
      )

      {:ok, ""}
    end)

    {:ok, _pass} = Learnings.curate_learnings(project)
    draft = Repo.get_by!(Learning, rule: "Use the factory")
    assert draft.status == :proposed

    later = sighting.(three, %{})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      assert File.read!(Path.join(opts[:cd], "proposals.md")) =~ draft.id

      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{"outcomes" => [%{"observation" => later.id, "outcome" => "link", "learning" => draft.id}]})
      )

      {:ok, ""}
    end)

    {:ok, _pass} = Learnings.curate_learnings(project)

    assert %Learning{status: :active, auto: true} = Repo.reload!(draft)

    assert %LearningProposal{status: :approved, evidence_ids: evidence} =
             Repo.get_by!(LearningProposal, learning_id: draft.id)

    assert later.id in evidence
  end

  test "a provisional rule is confirmed, rules are linked to, and conflicts and promotions are proposed", %{
    project: project,
    tasks: [one | _rest],
    sighting: sighting
  } do
    provisional = learning(project, %{rule: "Provisional", kind: :convention}, status: :provisional)
    %{id: active_id} = active = learning(project, %{rule: "Active", kind: :decision})
    seen = sighting.(one, %{})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "outcomes" => [
            %{"observation" => seen.id, "outcome" => "link", "learning" => active.id},
            %{"observation" => "obs_unread", "outcome" => "link", "learning" => active.id}
          ],
          "proposals" => [
            %{"action" => "add", "learning" => provisional.id, "summary" => "confirms"},
            %{"action" => "add", "learning" => active.id},
            %{
              "action" => "conflict",
              "learning" => active.id,
              "targets" => [provisional.id],
              "summary" => "they disagree"
            },
            %{"action" => "conflict", "learning" => active.id},
            %{"action" => "promote", "learning" => active.id, "promote_to" => "credo_check"},
            %{"action" => "rewrite", "rule" => "No targets", "kind" => "convention"},
            %{"action" => "rewrite", "targets" => [active.id], "rule" => "", "kind" => "convention"}
          ]
        })
      )

      {:ok, ""}
    end)

    {:ok, _pass} = Learnings.curate_learnings(project)

    assert %Observation{learning_id: ^active_id} = Repo.reload!(seen)

    assert [:add, :conflict, :promote] =
             Repo.all(
               from p in LearningProposal, where: p.project_id == ^project.id, order_by: p.action, select: p.action
             )

    assert %LearningProposal{promote_to: :credo_check} =
             Repo.get_by!(LearningProposal, action: :promote, learning_id: active_id)
  end

  test "the digest goes to the learnings channel and not a triage channel, lists what was activated, and its permalink is kept",
       %{project: project, tasks: tasks, sighting: sighting} do
    %{workspace: workspace} = connect_slack_channel(project)

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    learning(project, %{rule: "Fresh", kind: :convention}, status: :provisional)
    backed = Enum.map(Enum.take(tasks, 3), &sighting.(&1, %{source_kind: :review_finding, source_id: "rvf_#{&1.id}"}))
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/api/chat.postMessage" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:posted, Jason.decode!(body)})
          Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000900"})

        "/api/chat.getPermalink" ->
          send(test, {:permalink_of, conn.query_params["channel"]})
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p1790000000000900"})
      end
    end)

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [
            %{
              "action" => "add",
              "rule" => "Tests use the factory",
              "kind" => "convention",
              "evidence" => Enum.map(backed, & &1.id)
            }
          ]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{id: pass_id, digest_permalink: "https://slack.example/p1790000000000900"}} =
             Learnings.curate_learnings(project)

    assert {:ok, %CuratorPass{id: ^pass_id}} = Learnings.get_latest_curator_pass(project)

    assert_received {:posted, %{"channel" => "C_LEARN", "text" => text}}
    assert_received {:permalink_of, "C_LEARN"}
    assert text =~ "*Learnings for #{project.name}*"
    assert text =~ "*Auto-activated 1*"
    assert text =~ "• Tests use the factory (3 Fix decisions)"
    assert text =~ "*Provisional since the last run 1:*"
    assert text =~ "/learnings|Open Learnings in Rail>"
  end

  test "a quiet day, or a project with triage channels but no learnings channel, posts no digest", %{
    project: %{id: project_id} = project,
    tasks: [one | _rest],
    sighting: sighting
  } do
    connect_slack_channel(project)
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")
    Req.Test.stub(Rail.Slack, fn _conn -> flunk("posted a digest") end)

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(Path.join(opts[:cd], "result.json"), ~s({"outcomes": [], "proposals": []}))
      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{digest_permalink: nil}} = Learnings.curate_learnings(project)
    assert {:error, :not_found} = Learnings.get_latest_curator_pass(project)

    seen = sighting.(one, %{})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [%{"action" => "add", "rule" => "New", "kind" => "convention", "evidence" => [seen.id]}]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{id: pass_id, digest_permalink: nil}} = Learnings.curate_learnings(project)
    assert_received {:learnings_changed, ^project_id}
    assert [%LearningProposal{action: :add, curator_pass_id: ^pass_id}] = Repo.all(LearningProposal)
  end

  test "a learnings channel picked while the pass runs gets that pass's digest", %{
    project: project,
    tasks: [one | _rest],
    sighting: sighting
  } do
    %{workspace: workspace} = connect_slack_channel(project)
    seen = sighting.(one, %{})
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/chat.postMessage" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:posted, Jason.decode!(body)["channel"]})
          Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000903"})

        "/api/chat.getPermalink" ->
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p4"})
      end
    end)

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      {:ok, _picked} =
        Projects.update_project(system_scope(), project, %{
          "learnings_slack_workspace_id" => workspace.id,
          "learnings_channel_external_id" => "C_PICKED"
        })

      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [%{"action" => "add", "rule" => "New", "kind" => "convention", "evidence" => [seen.id]}]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{digest_permalink: "https://slack.example/p4"}} = Learnings.curate_learnings(project)
    assert_received {:posted, "C_PICKED"}
  end

  test "two projects each post their digest to their own learnings channel", %{
    project: %{name: project_name} = project
  } do
    %{project: %{name: other_name} = other} = triage_project()

    {:ok, _curator} =
      Roles.create_role(system_scope(), other, %{
        stage: :curator,
        name: "Curator",
        model: "claude-opus-5-5",
        system_prompt: "You curate.",
        backend_id: "bkd_test_seed"
      })

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/" <> _pulls -> Req.Test.json(conn, [])
      end
    end)

    %{workspace: workspace} = connect_slack_channel(project)
    test = self()

    for {target, channel} <- [{project, "C_MINE"}, {other, "C_OTHER"}] do
      learning(target, %{rule: "Fresh in #{channel}", kind: :convention}, status: :provisional)

      {:ok, _project} =
        Projects.update_project(system_scope(), target, %{
          "learnings_slack_workspace_id" => workspace.id,
          "learnings_channel_external_id" => channel
        })
    end

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/chat.postMessage" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"channel" => channel, "text" => text} = Jason.decode!(body)
          send(test, {:posted, channel, text})
          Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000904"})

        "/api/chat.getPermalink" ->
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p5"})
      end
    end)

    for target <- [project, other] do
      expect(Tools, :run_agent, fn _backend, _argv, opts ->
        File.write!(Path.join(opts[:cd], "result.json"), ~s({"outcomes": [], "proposals": []}))
        {:ok, ""}
      end)

      assert {:ok, %CuratorPass{}} = Learnings.curate_learnings(target)
    end

    assert_received {:posted, "C_MINE", "*Learnings for " <> ^project_name <> "*" <> _mine}
    assert_received {:posted, "C_OTHER", "*Learnings for " <> ^other_name <> "*" <> _theirs}
  end

  test "a digest with nothing activated lists what waits and what turned provisional, by where it came from", %{
    project: project,
    tasks: [one, two | _rest],
    sighting: sighting
  } do
    %{workspace: workspace} = connect_slack_channel(project)

    {:ok, _project} =
      Projects.update_project(system_scope(), project, %{
        "learnings_slack_workspace_id" => workspace.id,
        "learnings_channel_external_id" => "C_LEARN"
      })

    flagged = learning(project, %{rule: "Don't flag docs", kind: :calibration})
    Repo.insert!(%LearningProposal{project_id: project.id, action: :override, learning_id: flagged.id})

    {:ok, [_provisional]} =
      Learnings.record_corrections(one, [
        %Rail.Pipeline.Schemas.DiffComment{id: "dcm_cur", path: "a.ex", line_text: "x", body: "Say why"}
      ])

    seen = sighting.(two, %{})
    test = self()

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/chat.postMessage" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:posted, Jason.decode!(body)["text"]})
          Req.Test.json(conn, %{"ok" => true, "ts" => "1790000000.000901"})

        "/api/chat.getPermalink" ->
          Req.Test.json(conn, %{"ok" => true, "permalink" => "https://slack.example/p2"})
      end
    end)

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [
            %{"action" => "add", "rule" => "New", "kind" => "convention", "evidence" => [seen.id]},
            %{"action" => "retire", "learning" => flagged.id},
            %{"action" => "retire"}
          ]
        })
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{digest_permalink: "https://slack.example/p2"}} = Learnings.curate_learnings(project)
    assert_received {:posted, text}
    refute text =~ "Auto-activated"
    assert text =~ "*To review 3:*"
    assert text =~ "1 new"
    assert text =~ "1 flagged by an override"
    assert text =~ "1 retire"
    assert text =~ "*Provisional since the last run 1:* from a diff comment on CUR-1"
  end

  test "a third task's sighting linked to a pending add on a retired rule activates nothing", %{
    project: project,
    tasks: [one, two, three | _rest],
    sighting: sighting
  } do
    rule = learning(project, %{rule: "Retired since", kind: :convention}, status: :retired)
    early = Enum.map([one, two], &sighting.(&1, %{learning_id: rule.id, curator_pass_id: nil}))

    proposal =
      Repo.insert!(%LearningProposal{
        project_id: project.id,
        action: :add,
        learning_id: rule.id,
        evidence_ids: Enum.map(early, & &1.id)
      })

    later = sighting.(three, %{})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{"outcomes" => [%{"observation" => later.id, "outcome" => "link", "learning" => rule.id}]})
      )

      {:ok, ""}
    end)

    assert {:ok, %CuratorPass{}} = Learnings.curate_learnings(project)
    assert %Learning{status: :retired} = Repo.reload!(rule)
    assert %LearningProposal{status: :pending} = Repo.reload!(proposal)
  end

  test "the pass's folder is gone after it, whether it finished or failed", %{project: project} do
    test = self()

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      send(test, {:dir, opts[:cd]})
      File.write!(Path.join(opts[:cd], "result.json"), ~s({}))
      {:ok, ""}
    end)

    assert {:ok, _pass} = Learnings.curate_learnings(project)
    assert_received {:dir, dir}
    refute File.exists?(dir)

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      send(test, {:dir, opts[:cd]})
      {:error, {:exit, 1}}
    end)

    assert {:error, _failed} = Learnings.curate_learnings(project)
    assert_received {:dir, failed_dir}
    refute File.exists?(failed_dir)
  end

  test "an add citing a sighting that made a provisional rule leaves the sighting with that rule", %{
    project: project,
    tasks: [one, two | _rest],
    sighting: sighting
  } do
    %{id: provisional_id} = learning(project, %{rule: "Scope lists to the task", kind: :convention}, status: :provisional)
    corrected = sighting.(one, %{source_kind: :diff_comment, learning_id: provisional_id})
    loose = sighting.(two, %{})

    expect(Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(
        Path.join(opts[:cd], "result.json"),
        Jason.encode!(%{
          "proposals" => [
            %{"action" => "add", "rule" => "Scope", "kind" => "convention", "evidence" => [corrected.id, loose.id]}
          ]
        })
      )

      {:ok, ""}
    end)

    {:ok, _pass} = Learnings.curate_learnings(project)
    %Learning{id: draft_id} = Repo.get_by!(Learning, rule: "Scope")

    assert %Observation{learning_id: ^provisional_id} = Repo.reload!(corrected)
    assert %Observation{learning_id: ^draft_id} = Repo.reload!(loose)
    assert %LearningProposal{evidence_ids: [_corrected, _loose]} = Repo.get_by!(LearningProposal, learning_id: draft_id)
  end

  test "a proposal the same as one still pending is dropped, from a later pass or the same one", %{project: project} do
    [one, two, three] = for n <- 1..3, do: learning(project, %{rule: "Rule #{n}", kind: :convention})

    same = [
      %{"action" => "retire", "learning" => one.id},
      %{"action" => "promote", "learning" => one.id, "promote_to" => "credo_check"},
      %{"action" => "conflict", "learning" => two.id, "targets" => [three.id]},
      %{"action" => "merge", "targets" => [two.id, three.id], "rule" => "Merged", "kind" => "convention"},
      %{"action" => "merge", "targets" => [three.id, two.id], "rule" => "Merged again", "kind" => "convention"}
    ]

    different = [
      %{"action" => "retire", "learning" => two.id},
      %{"action" => "conflict", "learning" => two.id, "targets" => [one.id]},
      %{"action" => "rewrite", "targets" => [two.id, three.id], "rule" => "Rewritten", "kind" => "convention"}
    ]

    for proposals <- [same, same ++ different] do
      expect(Tools, :run_agent, fn _backend, _argv, opts ->
        File.write!(Path.join(opts[:cd], "result.json"), Jason.encode!(%{"proposals" => proposals}))
        {:ok, ""}
      end)

      {:ok, _pass} = Learnings.curate_learnings(project)
    end

    assert [:conflict, :conflict, :merge, :promote, :retire, :retire, :rewrite] =
             Repo.all(
               from p in LearningProposal, where: p.project_id == ^project.id, order_by: p.action, select: p.action
             )

    refute Repo.get_by(Learning, rule: "Merged again")
  end
end
