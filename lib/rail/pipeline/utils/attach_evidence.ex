defmodule Rail.Pipeline.Utils.AttachEvidence do
  @moduledoc """
  The one way evidence reaches a finding: a file a pass wrote under the QA folder is copied into the
  finding's own folder, so a later pass cannot change it, and a text file's opening is read into the finding.
  """

  import Rail.Pipeline.Utils.QaEvidenceKind
  import Rail.Pipeline.Utils.ReadTextHead

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.Task

  # Enough of a log to read the failure in; the whole file is a click away.
  @text_limit 16_384

  @doc """
  Attaches `entries`, string-keyed evidence as a tool call sends it, to the finding `key`, each seen at
  `said`'s commit and time. Returns `{:ok, entries}` ready to cast, or `{:error, text}` naming a path that
  is not a file in the QA folder, before anything is copied.
  """
  def attach_evidence(%Task{scratch_path: scratch_path}, key, entries, %{commit: _commit, at: _at} = said)
      when is_list(entries) do
    qa = Path.join(scratch_path, "qa")
    found = Enum.map(entries, &find(qa, &1))

    case Enum.find(found, &match?({:error, _text}, &1)) do
      {:error, text} -> {:error, text}
      nil -> {:ok, Enum.map(found, &attach(qa, key, &1, said))}
    end
  end

  # What an agent says about when and on which commit is not taken: Rail knows both.
  defp find(qa, %{"path" => path} = entry) when is_binary(path) do
    with true <- FindingEvidence.confined?(path),
         {:ok, %File.Stat{type: :regular, mtime: taken_at}} <- File.lstat(Path.join(qa, path), time: :posix) do
      {:file, Map.drop(entry, ["commit", "taken_at"]), DateTime.from_unix!(taken_at)}
    else
      _not_a_file -> {:error, "#{path} is not a file in #{qa}"}
    end
  end

  defp find(_qa, %{} = entry), do: {:said, Map.drop(entry, ["commit", "taken_at"])}

  defp attach(qa, key, {:file, entry, taken_at}, said),
    do: Map.merge(copy(qa, key, entry), %{"commit" => said.commit, "taken_at" => taken_at})

  defp attach(_qa, _key, {:said, entry}, said), do: Map.merge(entry, %{"commit" => said.commit, "taken_at" => said.at})

  # A file already in the finding's folder is one an earlier save attached, cited again.
  defp copy(qa, key, %{"path" => path} = entry) do
    folder = "evidence/#{key}/"

    if String.starts_with?(path, folder) do
      entry
    else
      attached = "#{folder}#{System.unique_integer([:positive])}-#{Path.basename(path)}"
      File.mkdir_p!(Path.join(qa, folder))
      File.cp!(Path.join(qa, path), Path.join(qa, attached))
      read_in(%{entry | "path" => attached}, Path.join(qa, attached))
    end
  end

  defp read_in(%{"text" => text} = entry, _file) when is_binary(text), do: entry

  # A log holding tool-call markup, as Rail's own do, stays a file to open: read in, the markup check refuses it.
  defp read_in(entry, file) do
    with :text <- qa_evidence_kind(file),
         {:text, text, truncated} <- read_text_head(file, @text_limit),
         false <- Finding.markup?(text) do
      Map.put(entry, "text", if(truncated, do: text <> "\n[cut short here; open the file for the rest]", else: text))
    else
      _not_text -> entry
    end
  end
end
