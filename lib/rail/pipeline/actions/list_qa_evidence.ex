defmodule Rail.Pipeline.Actions.ListQaEvidence do
  @moduledoc """
  Every screenshot a QA pass has filed so far, newest first.

  The findings each name their own, but those only exist once the pass has
  written its report - and the whole point of watching a pass is seeing what it
  saw while it is still going. So this reads the directory rather than the rows.

  The check each one was filed against is in its name, because Rail put it there.
  What the caption said is read from the captions written beside the pictures -
  a filename has lost the capitals and the punctuation by the time it is a
  filename, and a picture from before there were captions falls back to it.

  Nothing else in that directory is a picture: an agent writing its own there is
  writing somewhere no finding can cite.
  """

  alias Rail.Pipeline.Schemas.Task

  @shots [".jpg", ".jpeg", ".png", ".gif", ".webp"]

  @doc """
  Lists `task`'s QA screenshots as `%{name:, file:, check:, taken_at:}`, newest
  first. `check` is the key of the row it was taken for, or `nil` for a picture
  filed before there was a checklist to file it against.
  """
  def list_qa_evidence(%Task{scratch_path: scratch_path}) do
    directory = Path.join([scratch_path, "qa", "evidence"])

    case File.ls(directory) do
      {:ok, entries} ->
        captions = captions(directory)

        entries |> Enum.filter(&shot?/1) |> Enum.map(&shot(directory, &1, captions)) |> newest_first()

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

  defp shot?(entry), do: String.downcase(Path.extname(entry)) in @shots

  defp shot(directory, entry, captions) do
    {check, caption} = split(entry)

    %{
      name: Map.get(captions, entry, caption),
      file: entry,
      check: check,
      taken_at: File.stat!(Path.join(directory, entry), time: :posix).mtime
    }
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
