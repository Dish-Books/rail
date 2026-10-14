defmodule RailTest.WorkflowHelpers do
  @moduledoc false

  import Ecto.Query
  import RailTest.GitHelpers

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Workflows

  @doc """
  A workflow file's text, weekly on Mondays at 09:00 UTC unless `overrides` say otherwise.
  """
  def workflow_yaml(overrides \\ %{}) do
    %{"name" => "Dependency updates", "schedule" => "0 9 * * 1", "instructions" => "Update the dependencies."}
    |> Map.merge(overrides)
    |> Enum.map_join(fn {key, value} -> "#{key}: #{inspect(value)}\n" end)
  end

  @doc """
  Merges `files`, path to text, to a new repository's default branch, fetches it into a clone the project is
  pointed at and syncs `project`'s workflows from there as at `synced_at`, which `DateTime.utc_now/0` answers until a test stubs it
  again. Returns that project's workflows, with their project.
  """
  def sync_workflow_files(%Project{} = project, files, synced_at \\ ~U[2026-10-12 08:00:00.000000Z]) do
    remote = create_temp_git_repo(prefix: "rail_wf_remote")

    for {path, text} <- files do
      File.mkdir_p!(Path.dirname(Path.join(remote, path)))
      File.write!(Path.join(remote, path), text)
    end

    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "workflows"])
    clone = create_temp_git_repo(prefix: "rail_wf_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    # The seeded projects' clones are not on disk, so the project is pointed at this one.
    Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [clone_path: clone])
    Mimic.stub(DateTime, :utc_now, fn -> synced_at end)
    {:ok, _changed} = Workflows.sync_workflows(%{project | clone_path: clone})
    {:ok, workflows} = Workflows.list_workflows(Scope.for_system(), [])

    Enum.filter(workflows, &(&1.project_id == project.id))
  end

  @doc """
  Expects one ticket opened in Linear and answers it as `identifier`, with the title it was sent.
  """
  def expect_linear_issue(identifier) do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(body)["variables"]["input"]

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_#{identifier}",
              "identifier" => identifier,
              "title" => input["title"],
              "description" => input["description"],
              "branchName" => String.downcase(identifier),
              "url" => "https://linear.app/issue/#{identifier}"
            }
          }
        }
      })
    end)
  end
end
