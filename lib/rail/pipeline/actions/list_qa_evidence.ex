defmodule Rail.Pipeline.Actions.ListQaEvidence do
  @moduledoc """
  Every screenshot a QA pass has filed so far, newest first.

  The findings each name their own, but those only exist once the pass has
  written its report - and the whole point of watching a pass is seeing what it
  saw while it is still going. So this reads the directory rather than the rows.

  Rail named every one of these files from the check `qa_shot` was given and the
  caption it was given, so both come back out of the name. Nothing else is in
  that directory: an agent writing its own picture there is writing somewhere no
  finding can cite.
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
      {:ok, entries} -> entries |> Enum.filter(&shot?/1) |> Enum.map(&shot(directory, &1)) |> newest_first()
      {:error, _none} -> []
    end
  end

  defp shot?(entry), do: String.downcase(Path.extname(entry)) in @shots

  defp shot(directory, entry) do
    {check, caption} = split(entry)

    %{
      name: caption,
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
