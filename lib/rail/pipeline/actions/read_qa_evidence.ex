defmodule Rail.Pipeline.Actions.ReadQaEvidence do
  @moduledoc """
  The head of one text file a QA pass filed, for the panel to show inline.

  It takes an entry `Rail.Pipeline.list_qa_evidence/1` listed rather than a
  name, so nothing read here was named from outside the directory listing.
  """

  import Rail.Pipeline.Utils.ReadTextHead

  alias Rail.Pipeline.Schemas.Task

  @limit 65_536

  @doc """
  Reads the first 64 KB of `evidence`, listed as `:text`, as
  `{:ok, %{text:, truncated:}}`. `{:error, :not_text}` is a file that stops being
  text past where the listing looked, and `{:error, :not_found}` one that has gone.
  """
  def read_qa_evidence(%Task{scratch_path: scratch_path}, %{file: file, kind: :text}) do
    path = Path.join([scratch_path, "qa", "evidence", file])

    if File.regular?(path) do
      case read_text_head(path, @limit) do
        {:text, text, truncated} -> {:ok, %{text: text, truncated: truncated}}
        :binary -> {:error, :not_text}
      end
    else
      {:error, :not_found}
    end
  end
end
