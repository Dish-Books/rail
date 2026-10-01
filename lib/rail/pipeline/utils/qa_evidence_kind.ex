defmodule Rail.Pipeline.Utils.QaEvidenceKind do
  @moduledoc false

  import Rail.Pipeline.Utils.ReadTextHead

  alias Rail.Pipeline.Schemas.QaEvidence

  @doc """
  What the file at `path` is: `:screenshot`, `:pdf`, `:text` or `:file`. Text is
  read for rather than guessed from the extension, because the agent chose it.
  """
  def qa_evidence_kind(path) do
    cond do
      QaEvidence.picture?(path) -> :screenshot
      String.downcase(Path.extname(path)) == ".pdf" -> :pdf
      match?({:text, _text, _truncated}, read_text_head(path, 8_192)) -> :text
      true -> :file
    end
  end
end
