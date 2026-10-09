defmodule Rail.Pipeline.Actions.ListScreens do
  @moduledoc """
  Reads the screen states the explorers shot, each with every shot taken of it, out of the QA folder.
  A record that is not the shape Rail writes, or whose picture is not a plain file, is passed over, since
  anything under scratch can have been written by an agent.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9][a-z0-9-]{0,59}\z/

  @doc """
  Returns `task`'s screen states, the first shot first with the key breaking a tie, as `%{key:, label:,
  shots:, findings:}`. `shots` run oldest to latest as `%{index:, file:, label:, commit:, browser:,
  taken_at:}`, `file` relative to the QA folder, and `findings` are `%{key:, title:}` whose evidence cites one.
  """
  def list_screens(%Task{scratch_path: scratch_path} = task) do
    qa = Path.join(scratch_path, "qa")

    shots =
      qa
      |> Path.join("screens/*/*.json")
      |> Path.wildcard()
      |> Enum.flat_map(&read(qa, &1))

    case shots do
      [] -> []
      shots -> states(shots, Pipeline.list_findings(task))
    end
  end

  defp states(shots, findings) do
    shots
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {key, mine} ->
      mine = mine |> Enum.sort_by(& &1.taken_at, DateTime) |> Enum.with_index(&Map.put(&1, :index, &2))
      files = Enum.map(mine, &Path.basename(&1.file))

      %{
        key: key,
        label: List.last(mine).label,
        shots: mine,
        findings: for(finding <- findings, cites?(finding, files), do: %{key: finding.key, title: finding.title})
      }
    end)
    |> Enum.sort_by(&{DateTime.to_unix(hd(&1.shots).taken_at, :microsecond), &1.key})
  end

  # Saving a finding copies a cited picture into its own folder under a prefix, keeping its name.
  defp cites?(%Finding{evidence: evidence}, files) do
    names = for %{path: path} when is_binary(path) <- evidence, do: Path.basename(path)

    Enum.any?(names, fn name -> Enum.any?(files, &(name == &1 or String.ends_with?(name, "-" <> &1))) end)
  end

  defp read(qa, record) do
    key = record |> Path.dirname() |> Path.basename()
    file = "screens/#{key}/#{Path.basename(record, ".json")}.jpg"

    # `lstat` all the way down, so a link an agent left never takes the read out of the folder.
    with true <- key =~ @key,
         true <-
           Enum.all?(
             ["screens", "screens/#{key}"],
             &match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(qa, &1)))
           ),
         true <- Enum.all?([record, Path.join(qa, file)], &match?({:ok, %File.Stat{type: :regular}}, File.lstat(&1))),
         {:ok, content} <- File.read(record),
         {:ok, %{"label" => label, "taken_at" => taken_at} = shot} when is_binary(label) and is_binary(taken_at) <-
           Jason.decode(content),
         {:ok, taken_at, _offset} <- DateTime.from_iso8601(taken_at) do
      [
        %{
          key: key,
          file: file,
          label: label,
          commit: text(shot["commit"]),
          browser: text(shot["browser"]),
          taken_at: taken_at
        }
      ]
    else
      _not_a_shot -> []
    end
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: nil
end
