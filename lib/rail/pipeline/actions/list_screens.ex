defmodule Rail.Pipeline.Actions.ListScreens do
  @moduledoc """
  Reads the screen states the explorers shot, each by its latest shot, out of the QA folder. A record that is not
  the shape Rail writes, or whose picture is not a plain file, is passed over, since anything under scratch can
  have been written by an agent.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task

  @key ~r/\A[a-z0-9][a-z0-9-]{0,59}\z/

  @doc """
  Returns `task`'s screen states by label, the key breaking a tie, so a round's retakes never reorder them, as
  `%{key:, label:, file:, commit:, browser:, taken_at:, findings:}` for each state's newest shot. `file` is relative
  to the QA folder, and `findings` are `%{key:, title:}` whose evidence cites that picture.
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

  # A retake leaves an earlier record only when it failed partway, and the newest one is still the state.
  defp states(shots, findings) do
    shots
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, mine} ->
      latest = Enum.max_by(mine, &{DateTime.to_unix(&1.taken_at, :microsecond), &1.file})
      file = Path.basename(latest.file)

      Map.put(
        latest,
        :findings,
        for(finding <- findings, cites?(finding, file), do: %{key: finding.key, title: finding.title})
      )
    end)
    |> Enum.sort_by(&{&1.label, &1.key})
  end

  # Saving a finding copies a cited picture into its own folder under a prefix, keeping its name.
  defp cites?(%Finding{evidence: evidence}, file) do
    names = for %{path: path} when is_binary(path) <- evidence, do: Path.basename(path)

    Enum.any?(names, &(&1 == file or String.ends_with?(&1, "-" <> file)))
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
