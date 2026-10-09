defmodule Rail.Mcp.Utils.RunToolBrowserConnectTest do
  use Rail.DataCase, async: false

  import Ecto.Query
  import Rail.Mcp.Utils.RunToolBrowserConnect
  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.Schemas.BrowserSession, as: Session
  alias Rail.Tools.Schemas.OsProcess

  # Serial, and against a real Chrome: what is under test is which tab opens which link.
  @moduletag :browser

  setup_all do
    {:ok, _host} = ensure_browser_host(ready_timeout_ms: 60_000)
    :ok
  end

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_btc_#{System.unique_integer([:positive])}",
              "identifier" => "BTC-1",
              "title" => "Sign in"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Sign in"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    # The app the seed's link points at: a page served the way the worktree's server would.
    site = Path.join(task.scratch_path, "site")
    File.mkdir_p!(site)
    File.write!(Path.join(site, "signin.html"), "<!doctype html><title>Signed in</title>")

    {:ok, server} =
      Bandit.start_link(plug: {Plug.Static, at: "/", from: site}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    # A stand-in for a project's seed: each run makes the next account, logs a
    # link of its own on the way, and prints the magic link last.
    File.mkdir_p!(Path.join(task.worktree_path, "scripts"))

    File.write!(Path.join(task.worktree_path, "scripts/seed.sh"), """
    echo ran >> runs
    n=$(( $(cat seeded 2>/dev/null || echo 0) + 1 )); echo $n > seeded
    echo "Created explorer-$n@rail.test in Acme $n, see http://127.0.0.1:#{port}/"
    echo "Sign in: http://127.0.0.1:#{port}/signin.html?n=$n."
    """)

    File.write!(Path.join(task.worktree_path, "scripts/broken.sh"), "echo 'could not reach the database'; exit 3")
    File.write!(Path.join(task.worktree_path, "scripts/linkless.sh"), "echo 'Created someone@rail.test'")
    File.write!(Path.join(task.worktree_path, "scripts/nameless.sh"), "echo 'http://127.0.0.1:#{port}/signin.html'")

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: Path.join(task.scratch_path, "stream.ndjson"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    on_exit(fn ->
      for name <- ["explorer 1", "explorer 2", "signup", "twin"] do
        case Tools.get_browser_session(task, name) do
          pid when is_pid(pid) -> GenServer.stop(pid, :normal, 10_000)
          nil -> :ok
        end
      end

      File.rm_rf(task.scratch_path)
      File.rm_rf(task.worktree_path)
    end)

    %{
      task: task,
      project: project,
      opts: [stage: :review_lead, os_process: os_process],
      link: "http://127.0.0.1:#{port}/signin.html",
      seeded: Path.join(task.worktree_path, "seeded")
    }
  end

  test "each name is a browser of its own, signed in once as an account of its own", %{
    task: task,
    project: project,
    opts: opts,
    link: link,
    seeded: seeded
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, first} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert first =~ "Browser: explorer 1"
    assert first =~ "Signed in as: explorer-1@rail.test"

    assert {:ok, second} = run_tool_browser_connect(task, %{"browser" => "explorer 2"}, opts)
    assert second =~ "Signed in as: explorer-2@rail.test"

    eventually(fn ->
      assert Tools.get_browser_url(task, "explorer 1") == link <> "?n=1"
      assert Tools.get_browser_url(task, "explorer 2") == link <> "?n=2"
    end)

    assert [
             %Session{name: "explorer 1", account: "explorer-1@rail.test", browser_context_id: one},
             %Session{name: "explorer 2", account: "explorer-2@rail.test", browser_context_id: two}
           ] = Repo.all(from s in Session, where: s.task_id == ^task.id, order_by: s.name)

    assert one != two

    # Connecting again keeps the account it already has rather than making another,
    # and a reconnect asking for bare is told it is still signed in.
    assert {:ok, again} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert again =~ "Signed in as: explorer-1@rail.test"
    refute again =~ "`bare` only opens a new browser"

    assert {:ok, bare} = run_tool_browser_connect(task, %{"browser" => "explorer 1", "account" => "bare"}, opts)
    assert bare =~ "Signed in as: explorer-1@rail.test"
    assert bare =~ "`bare` only opens a new browser, so ask under a new name"

    assert File.read!(seeded) == "2\n"
    assert Tools.get_browser_url(task, "explorer 1") == link <> "?n=1"
  end

  # Two connects for one new name at once are one browser: the second waits for the
  # first to open and sign it in, so the seed runs once and the row keeps the tab.
  test "connects for one new name at once share one browser, one account and one seed run", %{
    task: task,
    project: project,
    opts: opts
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)
    test = self()

    replies =
      1..4
      |> Enum.map(fn _caller ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
          run_tool_browser_connect(task, %{"browser" => "twin"}, opts)
        end)
      end)
      |> Task.await_many(60_000)

    # Where the tab is reads as the sign-in link lands, so the replies agree on the tab and the account.
    assert [["Your tab: " <> _tab, "Signed in as: explorer-1@rail.test" <> _own]] =
             replies
             |> Enum.map(fn {:ok, reply} ->
               ~r/^(?:Your tab|Signed in as): .*$/m |> Regex.scan(reply) |> List.flatten()
             end)
             |> Enum.uniq()

    assert File.read!(Path.join(task.worktree_path, "runs")) == "ran\n"

    assert [%Session{status: :running, target_id: "" <> _target, account: "explorer-1@rail.test"}] =
             Repo.all(from s in Session, where: s.task_id == ^task.id)
  end

  test "a browser asked for bare opens with nobody signed in and the seed not run", %{
    task: task,
    project: project,
    opts: opts,
    seeded: seeded
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, text} = run_tool_browser_connect(task, %{"browser" => "signup", "account" => "bare"}, opts)

    refute text =~ "Signed in as"
    refute text =~ "Account seed: none"
    refute File.exists?(seeded)
    assert Tools.get_browser_url(task, "signup") in [nil, "about:blank"]
    assert %{signed_in?: true, account: nil} = BrowserSession.details(Tools.get_browser_session(task, "signup"))

    # Asked for again without `bare`, it stays the bare browser it was opened as,
    # after a restart too.
    assert {:ok, _again} = run_tool_browser_connect(task, %{"browser" => "signup"}, opts)
    :ok = GenServer.stop(Tools.get_browser_session(task, "signup"), :shutdown, 10_000)

    assert {:ok, resumed} = run_tool_browser_connect(task, %{"browser" => "signup"}, opts)
    refute resumed =~ "Signed in as"
    refute File.exists?(seeded)
  end

  test "with no seed set, a browser opens with nobody signed in and says so", %{task: task, opts: opts} do
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, text} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)

    assert text =~ "Browser: explorer 1"
    refute text =~ "Signed in as"
    assert text =~ "Account seed: none, so sign in as your prompt says."
    assert Tools.get_browser_url(task, "explorer 1") in [nil, "about:blank"]

    # Every connect says so, a reconnect included.
    assert {:ok, again} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert again =~ "Account seed: none"
  end

  # The seed is the project's, so what it said is what the agent needs to report it.
  test "a seed that fails says so with the end of what it printed, and runs again next time", %{
    task: task,
    project: project,
    opts: opts,
    seeded: seeded
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/broken.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:refused, refused} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert refused =~ "The account seed `sh scripts/broken.sh` exited with 3"
    assert refused =~ "could not reach the database"

    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, text} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert text =~ "Signed in as: explorer-1@rail.test"
    assert File.read!(seeded) == "1\n"
  end

  # A tab whose seed failed before Rail restarted was never signed in, so the
  # session that finds it again still signs it in.
  test "a tab found again after a restart is signed in if its seed never did", %{
    task: task,
    project: project,
    opts: opts,
    seeded: seeded
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/broken.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:refused, _failed} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    :ok = GenServer.stop(Tools.get_browser_session(task, "explorer 1"), :shutdown, 10_000)

    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, text} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert text =~ "Signed in as: explorer-1@rail.test"
    assert File.read!(seeded) == "1\n"

    assert [%Session{status: :running, signed_in_at: %DateTime{}}] =
             Repo.all(from s in Session, where: s.task_id == ^task.id)
  end

  test "a seed that prints no link signs nobody in and says what it printed", %{task: task, project: project, opts: opts} do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/linkless.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:refused, refused} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    assert refused =~ "printed no link to sign in with"
    assert refused =~ "Created someone@rail.test"
    assert %{signed_in?: false} = BrowserSession.details(Tools.get_browser_session(task, "explorer 1"))
  end

  test "a seed that prints a link and no email signs the tab in without naming the account", %{
    task: task,
    project: project,
    opts: opts,
    link: link
  } do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/nameless.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    assert {:ok, text} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
    refute text =~ "Signed in as"
    refute text =~ "Account seed: none"
    eventually(fn -> assert Tools.get_browser_url(task, "explorer 1") == link end)
    assert %{signed_in?: true, account: nil} = BrowserSession.details(Tools.get_browser_session(task, "explorer 1"))
  end

  test "a seed that runs too long, or cannot be run, is said", %{task: task, project: project, opts: opts} do
    project |> Ecto.Changeset.change(account_seed_command: "sh scripts/seed.sh") |> Repo.update!()
    {:ok, task} = Pipeline.get_task(task.id)

    expect(Tools, :run_in_sandbox, fn _os_process, "sh scripts/seed.sh" -> {:error, :timeout} end)

    assert {:refused, "The account seed `sh scripts/seed.sh` did not finish within two minutes" <> _rest} =
             run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)

    expect(Tools, :run_in_sandbox, fn _os_process, _seed -> {:error, {:docker_api_error, 404, %{}}} end)
    assert {:error, {:docker_api_error, 404, %{}}} = run_tool_browser_connect(task, %{"browser" => "explorer 1"}, opts)
  end

  test "an account or a name Rail cannot use is refused before anything opens", %{task: task, opts: opts} do
    assert {:refused, "`account` is `fresh` or `bare`." <> _rest} =
             run_tool_browser_connect(task, %{"browser" => "explorer 1", "account" => "admin"}, opts)

    assert {:refused, "`browser` is a name" <> _rest} = run_tool_browser_connect(task, %{"browser" => ""}, opts)
    assert Repo.all(from s in Session, where: s.task_id == ^task.id) == []
  end
end
