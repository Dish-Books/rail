defmodule Rail.Pipeline.Actions.ClassifyQaEvidence do
  @moduledoc """
  Says what a file under a task's QA directory holds, so it is served as that
  rather than as whatever the agent named it.
  """

  import Rail.Pipeline.Utils.QaEvidenceKind

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Classifies `path`, relative to `task`'s QA directory, as `{:ok, kind}` with the
  kinds `Rail.Pipeline.list_qa_evidence/1` gives, or `{:error, :not_found}`.
  """
  def classify_qa_evidence(%Task{scratch_path: scratch_path}, path) do
    file = Path.join([scratch_path, "qa", path])

    if File.regular?(file), do: {:ok, qa_evidence_kind(file)}, else: {:error, :not_found}
  end
end
