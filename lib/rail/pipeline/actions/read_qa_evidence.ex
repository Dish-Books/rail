defmodule Rail.Pipeline.Actions.ReadQaEvidence do
  @moduledoc """
  The head of one text file a QA pass saved, for the panel to show inline.

  It takes either an entry `Rail.Pipeline.list_qa_evidence/1` listed or a piece
  of a finding's evidence, whose path `FindingEvidence.changeset/2` already confined
  to `<scratch>/qa`, so nothing read here was named from outside.
  """

  import Rail.Pipeline.Utils.ReadTextHead

  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.Task

  @listed_limit 65_536
  # A finding's log gets the whole column, and the lines around a failure are
  # rarely in the first 64 KB of one.
  @finding_limit 256 * 1024

  @doc """
  Reads the head of `evidence` as `{:ok, %{text:, truncated:}}`: the first 256 KB
  of a finding's file, or the first 64 KB of a file listed as `:text`.
  `{:error, :not_text}` is a file whose bytes are not text, and
  `{:error, :not_found}` one that is not there.
  """
  def read_qa_evidence(%Task{scratch_path: scratch_path}, %FindingEvidence{path: path}) when is_binary(path) do
    read(Path.join([scratch_path, "qa", path]), @finding_limit)
  end

  def read_qa_evidence(%Task{scratch_path: scratch_path}, %{file: file, kind: :text}) do
    read(Path.join([scratch_path, "qa", "evidence", file]), @listed_limit)
  end

  defp read(path, limit) do
    if File.regular?(path) do
      case read_text_head(path, limit) do
        {:text, text, truncated} -> {:ok, %{text: text, truncated: truncated}}
        :binary -> {:error, :not_text}
      end
    else
      {:error, :not_found}
    end
  end
end
