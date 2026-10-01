defmodule Rail.Pipeline.Utils.QaEvidenceKind do
  @moduledoc false

  import Rail.Pipeline.Utils.ReadTextHead

  @shots [".jpg", ".jpeg", ".png", ".gif", ".webp"]

  @doc """
  What the file at `path` is: `:screenshot`, `:pdf`, `:text` or `:file`. Text is
  read for rather than guessed from the extension, because the agent chose it.
  """
  def qa_evidence_kind(path) do
    extension = String.downcase(Path.extname(path))

    cond do
      extension in @shots -> :screenshot
      extension == ".pdf" -> :pdf
      match?({:text, _text, _truncated}, read_text_head(path, 8_192)) -> :text
      true -> :file
    end
  end
end
