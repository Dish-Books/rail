defmodule Rail.Tools.Actions.FileQaEvidence do
  @moduledoc """
  Files an output file a QA pass produced, a log, a PDF or anything else, against one check.

  Unlike a screenshot, the path arrives from a model. So it is held to the QA
  directory, followed through no link, and copied under a name Rail chooses:
  what the panel serves is never the path the agent gave.
  """

  import Rail.Tools.Utils.WriteQaEvidence

  alias Rail.Pipeline.Schemas.QaEvidence
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Copies `path`, relative to `task`'s QA directory, in as evidence captioned
  `name` against the check `key`, and returns `{:ok, file}` to cite in a finding.
  """
  def file_qa_evidence(%Task{scratch_path: scratch_path}, path, name, key) do
    qa = Path.join(scratch_path, "qa")
    source = Path.join(qa, path)

    cond do
      not QaEvidence.confined?(path) ->
        {:error, :unconfined_path}

      not regular?(qa, Path.split(path)) ->
        {:error, :not_a_file}

      true ->
        extension = String.downcase(Path.extname(path))

        {:ok, write_qa_evidence(scratch_path, name, key, extension, &File.cp!(source, &1))}
    end
  end

  # Every segment is looked at rather than the file alone, because a linked
  # directory half way down leads out as surely as a linked file.
  defp regular?(directory, [last]) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(directory, last)))
  end

  defp regular?(directory, [segment | rest]) do
    next = Path.join(directory, segment)

    match?({:ok, %File.Stat{type: :directory}}, File.lstat(next)) and regular?(next, rest)
  end
end
