defmodule Rail.Issues.Workers.EnsureGithubLabelsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues.Workers.EnsureGithubLabels
  alias Rail.Projects

  test "saving a GitHub project queues its labels, and a Linear project queues nothing", %{project: project} do
    {:ok, created} =
      Projects.create_project(system_scope(), %{
        name: "Labelled",
        github_repo: "example/labelled-#{System.unique_integer([:positive])}",
        github_installation_id: 1,
        tracker: "github",
        default_branch: "main",
        clone_path: "/tmp/labelled"
      })

    assert_enqueued(worker: EnsureGithubLabels, args: %{project_id: created.id})

    {:ok, _updated} = Projects.update_project(system_scope(), project, %{name: "Still Linear"})
    refute_enqueued(worker: EnsureGithubLabels, args: %{project_id: project.id})
  end

  test "makes every rail: label, leaving the ones that already exist", %{github_project: project} do
    Req.Test.expect(Client, 10, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"POST", "/repos/example/test-gh/labels"} ->
          case Jason.decode!(body) do
            %{"name" => "rail: triage", "color" => "d4c5f9", "description" => "Rail: waiting to be sorted"} ->
              conn
              |> Plug.Conn.put_status(422)
              |> Req.Test.json(%{"errors" => [%{"resource" => "Label", "code" => "already_exists", "field" => "name"}]})

            %{"name" => "rail: " <> _rest} ->
              conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
          end
      end
    end)

    assert :ok = perform_job(EnsureGithubLabels, %{project_id: project.id})
  end

  test "stops at the first label GitHub refuses, for Oban to retry", %{github_project: project} do
    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/labels" ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible by integration"})
      end
    end)

    assert {:error, :github_issues_permission_missing} = perform_job(EnsureGithubLabels, %{project_id: project.id})
  end

  test "a project that is gone, or tracked in Linear, needs no labels", %{project: project} do
    assert :ok = perform_job(EnsureGithubLabels, %{project_id: project.id})
    assert :ok = perform_job(EnsureGithubLabels, %{project_id: "prj_gone"})
  end

  test "a token GitHub will not mint fails the job, for Oban to retry", %{github_project: project} do
    Req.Test.expect(Client, fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end)

    assert {:error, _reason} = perform_job(EnsureGithubLabels, %{project_id: project.id})
  end
end
