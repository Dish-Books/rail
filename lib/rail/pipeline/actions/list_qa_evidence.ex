defmodule Rail.Pipeline.Actions.ListQaEvidence do
  @moduledoc """
  Every piece of evidence a QA pass has filed so far, newest first.

  The findings each name their own, but those only exist once the pass has
  written its report - and the whole point of watching a pass is seeing what it
  saw while it is still going. So this reads the directory rather than the rows.

  The check each one was filed against is in its name, because Rail put it there.
  What the caption said is read from the captions written beside the files -
  a filename has lost the capitals and the punctuation by the time it is a
  filename, and a picture from before there were captions falls back to it.

  A picture is listed whatever it is called. Any other file is listed only once
  Rail has filed it against a check, and a link is never listed, because this
  listing is what the panel serves.
  """

  import Rail.Pipeline.Utils.QaEvidenceKind

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Lists `task`'s QA evidence as `%{name:, file:, check:, kind:, taken_at:}`,
  newest first. `check` is the key of the row it was filed for, or `nil` for a
  picture filed before there was a checklist. `kind` is `:screenshot`, `:pdf`,
  `:text` or `:file`.
  """
  def list_qa_evidence(%Task{scratch_path: scratch_path}) do
    directory = Path.join([scratch_path, "qa", "evidence"])

    case File.ls(directory) do
      {:ok, entries} ->
        captions = captions(directory)

        entries |> Enum.flat_map(&evidence(directory, &1, captions)) |> newest_first()

      {:error, _none} ->
        []
    end
  end

  # One JSON object a line, the last one for a name winning, and anything
  # unreadable skipped: the file is appended to while a pass runs, so its last
  # line can be half written.
  defp captions(directory) do
    directory
    |> Path.join("captions.jsonl")
    |> File.read()
    |> case do
      {:ok, written} -> written
      {:error, _none} -> ""
    end
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, captions ->
      case Jason.decode(line) do
        {:ok, %{"file" => file, "name" => name}} -> Map.put(captions, file, name)
        _unreadable -> captions
      end
    end)
  end

  # `lstat` rather than `stat`, so a link is never followed out of the directory.
  defp evidence(directory, entry, captions) do
    path = Path.join(directory, entry)
    {check, caption} = split(entry)

    with {:ok, %File.Stat{type: :regular, mtime: taken_at}} <- File.lstat(path, time: :posix),
         kind when kind == :screenshot or is_binary(check) <- qa_evidence_kind(path) do
      [
        %{
          name: Map.get(captions, entry, caption),
          file: entry,
          check: check,
          kind: kind,
          taken_at: taken_at
        }
      ]
    else
      _unlisted -> []
    end
  end

  # Rail joined the check's key to the slugged caption with a `~`, which neither
  # of them can contain, so the name comes apart again exactly where it went
  # together. What comes out is as close to what the agent said as a filename
  # can get back to.
  defp split(entry) do
    case String.split(Path.rootname(entry), "~", parts: 2) do
      [check, caption] -> {check, caption(caption)}
      [caption] -> {nil, caption(caption)}
    end
  end

  defp caption(slug), do: slug |> String.replace("-", " ") |> String.capitalize()

  # Newest first, and by name where a pass filed two in the same second.
  defp newest_first(shots), do: Enum.sort_by(shots, &{&1.taken_at, &1.file}, :desc)
end
