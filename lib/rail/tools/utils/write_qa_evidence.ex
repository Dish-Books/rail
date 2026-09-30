defmodule Rail.Tools.Utils.WriteQaEvidence do
  @moduledoc """
  Names and files one piece of QA evidence under the task, a picture or a file alike.

  The check's key leads the filename, because evidence belongs to one row of the
  checklist and the panel shows it against that row. `~` separates them: a slug
  cannot contain one and neither can a key, so the name comes apart again
  without anything having recorded where to cut it.

  What the caption actually said is written down beside the file rather than
  read back out of the filename, which has lost the capitals, the punctuation
  and anything past sixty characters by the time it is a filename.
  """

  @doc """
  Files evidence captioned `name` against the check `key` as
  `evidence/<key>~<slug><extension>`, with `write` putting the bytes at the
  absolute path it is handed, and returns that name relative to the QA directory.
  """
  def write_qa_evidence(scratch_path, name, key, extension, write) do
    file = "evidence/#{prefix(key)}#{slug(name)}#{extension}"
    path = Path.join([scratch_path, "qa", file])

    File.mkdir_p!(Path.dirname(path))
    write.(path)
    caption(path, Path.basename(file), name)

    file
  end

  # Evidence filed before there is a checklist still gets a name; it just
  # belongs to no row.
  defp prefix(nil), do: ""
  defp prefix(key), do: "#{slug(key)}~"

  # One line per file, appended rather than rewritten: a pass that dies half way
  # leaves every caption it had already written, and the panel falls back to the
  # filename for any it did not.
  defp caption(path, file, name) do
    line = Jason.encode_to_iodata!(%{file: file, name: name})

    File.write!(Path.join(Path.dirname(path), "captions.jsonl"), [line, "\n"], [:append])
  end

  # A caption becomes a filename, so it is reduced to something a filesystem and
  # a URL both accept. Two described the same way would collide, which is why
  # the name carries enough of the caption to tell them apart.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> then(fn slug -> if slug == "", do: "shot", else: slug end)
  end
end
