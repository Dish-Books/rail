defmodule Rail.Tools.Utils.WriteQaEvidence do
  @moduledoc """
  Names and files one piece of QA evidence under the task, a picture or a file alike.

  The check's key leads the filename, because evidence belongs to one row of the
  checklist and the panel shows it against that row. `~` separates them: a slug
  cannot contain one and neither can a key, so the name comes apart again
  without anything having recorded where to cut it.

  What the caption actually said is written down beside the file rather than
  read back out of the filename, which has lost the capitals, the punctuation
  and anything past sixty characters by the time it is a filename. So are the
  commit HEAD was on and the browser that took it, which a finding citing it copies.

  The bytes land under a hidden name in the QA folder, outside the listing, and
  a rename files them, so the panel and the evidence route never serve half a file.
  """

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Files evidence captioned `name` against the check `key` as
  `evidence/<key>~<slug><extension>`, with `write` putting the bytes at the
  absolute path it is handed, and returns that name relative to the QA directory.
  `browser` names the browser it came from, if any.
  """
  def write_qa_evidence(%Task{scratch_path: scratch_path} = task, name, key, extension, write, browser) do
    file = "evidence/#{prefix(key)}#{slug(name)}#{extension}"
    path = Path.join([scratch_path, "qa", file])
    temporary = Path.join([scratch_path, "qa", ".#{Path.basename(file)}.#{System.unique_integer([:positive])}.tmp"])

    File.mkdir_p!(Path.dirname(path))
    write.(temporary)
    File.rename!(temporary, path)
    commit = if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
    caption(path, %{file: Path.basename(file), name: name, commit: commit, browser: browser})

    file
  end

  # Evidence filed before there is a checklist still gets a name; it just
  # belongs to no row.
  defp prefix(nil), do: ""
  defp prefix(key), do: "#{slug(key)}~"

  # One line per file, appended rather than rewritten: a pass that dies half way
  # leaves every caption it had already written, and the panel falls back to the
  # filename for any it did not.
  defp caption(path, caption) do
    line = Jason.encode_to_iodata!(caption)

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
