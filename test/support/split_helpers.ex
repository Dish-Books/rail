defmodule RailTest.SplitHelpers do
  @moduledoc false

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  A parent task at Split with a child per `{identifier, builds_on}`, in order, each at Engineer with
  no run yet, as approval leaves the ones it has not started. Returns `{parent, children}`.
  """
  def split_task(project, identifier, children, attrs \\ %{}) do
    parent_issue = linear_issue(project, identifier, Map.merge(%{title: "Work on #{identifier}"}, attrs))
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)

    children =
      for {{child_identifier, builds_on}, number} <- Enum.with_index(children, 1) do
        issue =
          linear_issue(
            project,
            child_identifier,
            Map.merge(attrs, %{title: "Child #{child_identifier}", parent: parent_issue})
          )

        child = %{number: number, builds_on: builds_on, plan: "## Implementation plan\n\nPart #{number}."}
        {:ok, task} = Pipeline.create_child_task(parent, issue, child)
        Repo.preload(task, [:issue, :project])
      end

    {Repo.preload(parent, [:issue, :project]), children}
  end

  defp linear_issue(project, identifier, attrs) do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_#{System.unique_integer([:positive])}",
              "identifier" => identifier,
              "title" => attrs.title
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(Scope.for_system(), project, Map.put(attrs, :description, "The ticket."))
    issue
  end
end
