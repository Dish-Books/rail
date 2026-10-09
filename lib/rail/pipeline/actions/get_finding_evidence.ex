defmodule Rail.Pipeline.Actions.GetFindingEvidence do
  @moduledoc """
  One file a finding attached, found by the finding's key and the piece's place in its list, so the path
  served is the row's and never a request's; what the file holds picks how it is served, since an agent wrote it.
  """

  import Rail.Pipeline.Utils.QaEvidenceKind

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Returns `{:ok, %{file:, kind:}}`, the file's absolute path and `:screenshot`, `:pdf`, `:text` or `:file`,
  for piece `index` of `task`'s finding `key`, or `{:error, :not_found}`.
  """
  def get_finding_evidence(%Task{id: task_id, scratch_path: scratch_path}, key, index) do
    file =
      with {position, ""} when position >= 0 <- Integer.parse(to_string(index)),
           %Finding{evidence: evidence} <- Repo.get_by(Finding, task_id: task_id, key: key),
           %FindingEvidence{path: path} when is_binary(path) <- Enum.at(evidence, position),
           true <- FindingEvidence.confined?(path) do
        Path.join([scratch_path, "qa", path])
      else
        _missing -> nil
      end

    # `lstat` rather than `stat`, so a link is never followed out of the folder.
    case file && File.lstat(file) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, %{file: file, kind: qa_evidence_kind(file)}}
      _missing -> {:error, :not_found}
    end
  end
end
