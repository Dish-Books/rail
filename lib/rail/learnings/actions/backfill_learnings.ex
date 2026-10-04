defmodule Rail.Learnings.Actions.BackfillLearnings do
  @moduledoc """
  Fills a project's knowledge base from its past, once, from `bin/rail rpc`; a second run repeats no work.
  Finished tasks and merged PRs are queued as new ones are, and each Claude memory file becomes an add proposal and is then deleted.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding
  import Rail.Learnings.Utils.EnqueuePullRequests

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @kinds %{"feedback" => :convention, "project" => :decision, "reference" => :environment, "user" => :environment}

  @doc """
  Backfills `project`. Returns `{:ok, %{issues:, pull_requests:, memories:}}`,
  how many of each it queued or imported.
  """
  def backfill_learnings(%Project{id: project_id} = project) do
    issues =
      Repo.all(
        from i in Issue,
          join: t in Task,
          on: t.issue_id == i.id,
          where: i.project_id == ^project_id and i.state in ^Issue.finished_states(),
          where: is_nil(t.learnings_extracted_at),
          distinct: i.id
      )

    Enum.each(issues, &({:ok, _job} = Learnings.handle_issue_finished(&1)))

    with {:ok, numbers} <- enqueue_pull_requests(project, nil) do
      memories = import_memories(project)
      if memories > 0, do: broadcast_learnings_changed(project_id)
      {:ok, %{issues: length(issues), pull_requests: length(numbers), memories: memories}}
    end
  end

  # Claude keeps a project's memory under its config dir, in a folder named for
  # the checkout's path with every other character turned into a dash.
  defp import_memories(%Project{clone_path: clone_path} = project) do
    folder = String.replace(clone_path, ~r/[^A-Za-z0-9]/, "-")

    dirs =
      for %Backend{name: :claude} = backend <- Tools.list_backends(),
          do: Path.join([Backend.config_dir(backend), "projects", folder, "memory"])

    Enum.reduce(dirs, 0, fn dir, imported ->
      files = dir |> Path.join("*.md") |> Path.wildcard() |> Enum.reject(&(Path.basename(&1) == "MEMORY.md"))
      imported = imported + Enum.count(files, &import_memory(project, &1))

      if dir |> Path.join("*.md") |> Path.wildcard() == [Path.join(dir, "MEMORY.md")],
        do: File.rm(Path.join(dir, "MEMORY.md"))

      imported
    end)
  end

  # A file that cannot be read as a memory is left where it is rather than lost.
  defp import_memory(%Project{id: project_id}, path) do
    with {:ok, content} <- File.read(path),
         true <- String.valid?(content),
         %{} = memory <- parse(content) do
      imported =
        if Repo.exists?(from p in LearningProposal, where: p.project_id == ^project_id and p.source_key == ^path),
          do: false,
          else: propose(project_id, path, memory)

      File.rm(path)
      imported
    else
      _unreadable -> false
    end
  end

  defp propose(project_id, path, memory) do
    {:ok, _proposal} =
      Repo.transaction(fn ->
        draft =
          %Learning{project_id: project_id, status: :proposed}
          |> Learning.changeset(%{rule: memory.rule, why: memory.why, kind: memory.kind, roles: []})
          |> Repo.insert!()

        enqueue_embedding([draft])

        %LearningProposal{project_id: project_id}
        |> LearningProposal.changeset(%{
          action: :add,
          title: memory.title,
          summary: "Claude memory import",
          learning_id: draft.id,
          source_key: path
        })
        |> Repo.insert!()
      end)

    true
  end

  defp parse("---\n" <> rest) do
    case String.split(rest, ~r/\n---\s*\n/, parts: 2) do
      [front, body] -> memory(front, String.trim(body))
      [_unterminated] -> nil
    end
  end

  defp parse(body), do: memory("", String.trim(body))

  defp memory(front, body) do
    fields =
      for line <- String.split(front, "\n"),
          [_line, key, value] <- [Regex.run(~r/^\s*(name|description|type):\s*(.*)$/, line)],
          into: %{},
          do: {key, value |> String.trim() |> String.trim("\"")}

    rule = Enum.find([fields["description"], fields["name"], first_line(body)], &(is_binary(&1) and &1 != ""))

    if rule,
      do: %{
        title: fields["name"],
        rule: String.slice(rule, 0, 2_000),
        why: if(body == "", do: nil, else: body),
        kind: Map.get(@kinds, fields["type"], :environment)
      }
  end

  defp first_line(body), do: body |> String.split("\n", parts: 2) |> hd()
end
