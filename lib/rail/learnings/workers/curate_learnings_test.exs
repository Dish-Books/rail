defmodule Rail.Learnings.Workers.CurateLearningsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Learnings.Workers.CurateLearnings

  test "a pass that cannot run is reported, and a project that is gone has none", %{project: project} do
    Req.Test.stub(Client, &Req.Test.json(Plug.Conn.put_status(&1, 401), %{"message" => "Bad credentials"}))

    assert {:error, {{:github_api_error, 401, _body}, _pass}} = perform_job(CurateLearnings, %{project_id: project.id})
    assert :ok = perform_job(CurateLearnings, %{project_id: "prj_gone"})
  end

  test "a pass that finishes is done", %{project: project} do
    stub(Rail.Git, :checkout_detached_worktree, fn _project, path -> {:ok, path} end)
    stub(Rail.Git, :remove_worktree, fn _repo, _path -> :ok end)

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest -> Req.Test.json(conn, %{"token" => "ghs_token"})
        _pulls -> Req.Test.json(conn, [])
      end
    end)

    expect(Rail.Tools, :run_agent, fn _backend, _argv, opts ->
      File.write!(Path.join(opts[:cd], "result.json"), ~s({}))
      {:ok, ""}
    end)

    assert :ok = perform_job(CurateLearnings, %{project_id: project.id})
  end
end
