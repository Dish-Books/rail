defmodule RailTest.LearningsHelpers do
  @moduledoc """
  Arranges learnings tests: Goth and Vertex answered in-process with chosen vectors, rules in any state, and tasks on stubbed issues.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Learnings
  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Scope

  @dimensions 3072

  @doc """
  Switches Goth on and answers Vertex with the vector of the first key in `vectors` the text contains, or `far/0`,
  sending the test `{:embedded, text, task_type}` for each request.
  """
  def stub_vertex(vectors \\ %{}) do
    test = self()
    Mimic.stub(Rail, :goth_enabled?, fn -> true end)
    Mimic.stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    Mimic.stub(Goth.Config, :get, fn :project_id -> {:ok, "rail-testing"} end)

    Req.Test.stub(Vertex, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"instances" => [%{"content" => text, "task_type" => task_type}]} = Jason.decode!(body)
      send(test, {:embedded, text, task_type})
      values = Enum.find_value(vectors, far(), fn {key, values} -> String.contains?(text, key) && values end)
      Req.Test.json(conn, %{"predictions" => [%{"embeddings" => %{"values" => values}}]})
    end)

    :ok
  end

  @doc "Switches Goth on and has Vertex refuse every request."
  def stub_vertex_down do
    stub_vertex()
    Req.Test.stub(Vertex, &Plug.Conn.send_resp(&1, 503, "unavailable"))
    :ok
  end

  @doc "A full-length vector from its first few components, the rest zero."
  def vector(components) when is_list(components), do: components ++ List.duplicate(0.0, @dimensions - length(components))

  @doc "A vector at right angles to every `vector/1` built from fewer than 3000 components."
  def far, do: Enum.reverse([1.0 | List.duplicate(0.0, @dimensions - 1)])

  @doc """
  A rule in `project` as a person adds one, then put in the state `overrides` names: `:status`, `:auto`, `:embedding`,
  `:activated_at`, `:retired_at`.
  """
  def learning(project, attrs, overrides \\ []) do
    {:ok, %Learning{id: id}} = Learnings.create_learning(Scope.for_system(), project, attrs)

    set =
      Enum.map(overrides, fn
        {:embedding, nil} -> {:embedding, nil}
        {:embedding, components} -> {:embedding, Pgvector.new(vector(components))}
        other -> other
      end)

    set =
      if Keyword.has_key?(overrides, :embedding),
        do: Keyword.put(set, :embedding_model, "gemini-embedding-001"),
        else: set

    if set != [], do: Repo.update_all(from(l in Learning, where: l.id == ^id), set: set)
    Repo.get!(Learning, id)
  end

  @doc """
  A task on a new issue in `project`, at `stage`, with `identifier`.
  """
  def learnings_task(project, identifier, stage \\ :engineer) do
    external_id = "lin_#{System.unique_integer([:positive])}"

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => external_id, "identifier" => identifier, "title" => "Work on #{identifier}"}
          }
        }
      })
    end)

    {:ok, issue} =
      Issues.create_issue(Scope.for_system(), project, %{title: "Work on #{identifier}", description: "The ticket."})

    {:ok, task} = Pipeline.create_task(issue, stage)
    Repo.preload(task, [:issue, :project])
  end
end
