defmodule Rail.Pipeline.Actions.SaveDesignOption do
  @moduledoc """
  Checks one option the designer saved and puts it in the manifest `read_design/1`
  reads: only once its page and screenshot exist, three before a pick, one after.
  """

  import Ecto.Changeset
  import Ecto.Query
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @key ~r/\A[a-z0-9-]+\z/
  @limit 3

  @types %{
    key: :string,
    title: :string,
    summary: :string,
    good_at: {:array, :string},
    costs: {:array, :string},
    assumptions: :string
  }

  @doc """
  Saves the option in `attrs` on `task`, replacing one under the same key.
  Returns `{:ok, option}` as `read_design/1` reads it, or `{:error, changeset}`.
  """
  def save_design_option(%Task{} = task, attrs) when is_map(attrs) do
    dir = Path.join(task.scratch_path, "design")

    # Parallel saves each rewrite the whole manifest, so they take turns on the task's row.
    result =
      Repo.transaction(fn ->
        Repo.one!(from t in Task, where: t.id == ^task.id, lock: "FOR UPDATE")
        entries = entries(dir)

        changeset =
          {%{good_at: [], costs: [], assumptions: ""}, @types}
          |> cast(attrs, Map.keys(@types))
          |> update_change(:title, &String.trim/1)
          |> update_change(:summary, &String.trim/1)
          |> validate_required([:key, :title, :summary])
          |> validate_format(:key, @key, message: "must be lowercase letters, digits and dashes")
          |> validate_built(dir)
          |> validate_room(entries, Pipeline.read_design(task))

        case apply_action(changeset, :insert) do
          {:ok, option} -> write(dir, entries, option)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    with {:ok, key} <- result do
      Pipeline.broadcast_output_saved(task)
      {:ok, Enum.find(Pipeline.read_design(task).options, &(&1.key == key))}
    end
  end

  defp validate_built(%Ecto.Changeset{valid?: false} = changeset, _dir), do: changeset

  defp validate_built(changeset, dir) do
    key = get_field(changeset, :key)

    [page: "#{key}.html", screenshot: "#{key}.png"]
    |> Enum.reject(fn {_field, file} -> File.regular?(Path.join(dir, file)) end)
    |> Enum.reduce(changeset, fn {field, file}, changeset ->
      add_error(changeset, field, "#{Path.join(dir, file)} does not exist yet; write it, then save the option")
    end)
  end

  defp validate_room(%Ecto.Changeset{valid?: false} = changeset, _entries, _design), do: changeset

  defp validate_room(changeset, entries, design) do
    key = get_field(changeset, :key)
    keys = for %{"key" => saved} <- entries, do: saved

    cond do
      match?(%{picked: picked} when is_binary(picked) and picked != key, design) ->
        add_error(changeset, :key, "is not the picked option #{design.picked}, the only one that can be saved now")

      key not in keys and length(keys) >= @limit ->
        add_error(changeset, :key, "would be a fourth option; save again under #{Enum.join(keys, ", ")}")

      true ->
        changeset
    end
  end

  # What is on disk already, whoever wrote it. An entry that is not an object
  # names nothing and is left out of the rewrite.
  defp entries(dir) do
    with {:ok, content} <- File.read(Path.join(dir, "manifest.json")),
         {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(content) do
      Enum.filter(options, &is_map/1)
    else
      _unreadable -> []
    end
  end

  defp write(dir, entries, option) do
    entry = %{
      "key" => option.key,
      "title" => option.title,
      "summary" => option.summary,
      "good_at" => option.good_at || [],
      "costs" => option.costs || [],
      "assumptions" => option.assumptions || ""
    }

    saved =
      if Enum.any?(entries, &(&1["key"] == option.key)),
        do: Enum.map(entries, &if(&1["key"] == option.key, do: entry, else: &1)),
        else: List.insert_at(entries, -1, entry)

    write_scratch_file(Path.join(dir, "manifest.json"), Jason.encode!(%{"options" => saved}, pretty: true))
    option.key
  end
end
