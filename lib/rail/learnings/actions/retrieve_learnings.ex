defmodule Rail.Learnings.Actions.RetrieveLearnings do
  @moduledoc """
  The rules a run is given as it starts: the nearest to each query for its role, plus the pinned ones.
  A query that cannot be embedded adds nothing, and a project with no embedded rule in scope makes no request.
  """

  import Rail.Learnings.Utils.SearchLearnings

  alias Rail.Learnings.Clients.Vertex
  alias Rail.Learnings.Schemas.LearningRetrieval
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role

  @per_query 20
  @per_file 5
  @cap 25

  @doc """
  Returns the rules for `target`, a run or a role, against `queries`: text, or
  `{path, changed_lines}` for one file of a diff. A run's are logged, once per rule.
  """
  def retrieve_learnings(%Run{} = run, queries) do
    %Run{task: %Task{project_id: project_id}, role: %Role{stage: stage}} = run = Repo.preload(run, [:task, :role])
    learnings = retrieve(project_id, stage, queries)
    log(run, learnings)
    learnings
  end

  def retrieve_learnings(%Role{project_id: project_id, stage: stage}, queries) do
    retrieve(project_id, stage, queries)
  end

  defp retrieve(project_id, stage, queries) do
    scope = [project_id: project_id, statuses: [:active, :provisional], role: stage]
    ranked = if search_learnings(scope ++ [embedded: true, limit: 1], nil) == [], do: [], else: rank(scope, queries)
    pinned = search_learnings([{:pinned, true} | scope], nil)

    ranked ++ Enum.reject(pinned, fn pin -> Enum.any?(ranked, &(&1.id == pin.id)) end)
  end

  defp rank(scope, queries) do
    queries
    |> Enum.reject(&blank?/1)
    |> Elixir.Task.async_stream(&search(scope, &1),
      max_concurrency: 8,
      timeout: to_timeout(second: 30),
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, found} -> found
      # coveralls-ignore-next-line (a Vertex request that outlives the timeout)
      {:exit, _timeout} -> []
    end)
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_id, sightings} -> Enum.max_by(sightings, & &1.similarity) end)
    |> Enum.sort_by(&{-&1.similarity, &1.id})
    |> Enum.take(@cap)
  end

  defp search(scope, {path, text}) when is_binary(path) and is_binary(text) do
    case Vertex.embed("#{path}\n#{text}", "CODE_RETRIEVAL_QUERY") do
      {:ok, embedding} -> search_learnings(scope ++ [path: path, limit: @per_file], embedding)
      {:error, _unembeddable} -> []
    end
  end

  defp search(scope, text) when is_binary(text) do
    case Vertex.embed(text, "RETRIEVAL_QUERY") do
      {:ok, embedding} -> search_learnings([{:limit, @per_query} | scope], embedding)
      {:error, _unembeddable} -> []
    end
  end

  defp blank?({_path, text}), do: blank?(text)
  defp blank?(text), do: String.trim(text) == ""

  defp log(%Run{}, []), do: :ok

  defp log(%Run{id: run_id}, learnings) do
    now = DateTime.utc_now()

    rows =
      Enum.map(learnings, &%{id: UXID.generate!(prefix: "lrt"), learning_id: &1.id, run_id: run_id, inserted_at: now})

    Repo.insert_all(LearningRetrieval, rows, on_conflict: :nothing, conflict_target: [:learning_id, :run_id])
    :ok
  end
end
