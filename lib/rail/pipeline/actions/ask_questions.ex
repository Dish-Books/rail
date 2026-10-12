defmodule Rail.Pipeline.Actions.AskQuestions do
  @moduledoc """
  Files the questions an agent asks through `ask_questions` on its run, held as asked until its turn ends.

  The run is left working: `register_asked_questions/1` makes them the round, and parks the run, once the turn is over.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Files `questions`, string-keyed maps with a `"prompt"` and optional `"options"`, on `run` in the order given.
  Anything else in the list is an invalid entry.

  A prompt the run already asked or holds open, or one earlier in the list, is reused rather than filed again.
  Returns `{:ok, %{asked: filed, already: reused}}`, or `{:error, [{number, changeset}]}` for every invalid
  entry, counted from 1, and then nothing is filed.
  """
  def ask_questions(%Run{} = run, questions) when is_list(questions) do
    changesets = Enum.map(questions, &changeset(run, &1))

    case for {%Ecto.Changeset{valid?: false} = changeset, number} <- Enum.with_index(changesets, 1),
             do: {number, changeset} do
      [] -> Repo.transaction(fn -> file(run, changesets) end)
      invalid -> {:error, invalid}
    end
  end

  defp changeset(%Run{} = run, attrs) when is_map(attrs) do
    %Question{task_id: run.task_id, run_id: run.id, status: :asked}
    |> Question.changeset(%{"prompt" => attrs["prompt"], "options" => attrs["options"] || []})
    |> Ecto.Changeset.update_change(:prompt, &String.trim/1)
    |> Ecto.Changeset.validate_change(:options, fn :options, options ->
      if Enum.all?(options, &is_binary/1), do: [], else: [options: "must be a list of text"]
    end)
    # A non-text option already made the changeset invalid; the filter only keeps the trim from raising on it.
    |> Ecto.Changeset.update_change(:options, &for(o <- &1, is_binary(o), String.trim(o) != "", do: String.trim(o)))
  end

  # An agent's call can hold anything, so an entry that is not a question is refused like a blank one.
  defp changeset(%Run{}, _not_a_map) do
    %Question{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:question, "must be an object with a prompt")
  end

  # The run is locked so two calls landing at once cannot both file the same prompt.
  defp file(%Run{id: run_id}, changesets) do
    Repo.one!(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE")

    held =
      from(q in Question,
        where: q.run_id == ^run_id and q.status in [:asked, :pending],
        order_by: [asc: q.inserted_at, asc: q.id]
      )
      |> Repo.all()
      |> Map.new(&{normalized(&1.prompt), &1})

    {fresh, repeated, _seen} = Enum.reduce(changesets, {[], [], MapSet.new(Map.keys(held))}, &sort_out/2)
    now = DateTime.utc_now()

    # A round is read back by inserted_at, so each row is a microsecond after the one asked before it.
    rows =
      for {changeset, offset} <- fresh |> Enum.reverse() |> Enum.with_index() do
        at = DateTime.add(now, offset, :microsecond)

        changeset
        |> Ecto.Changeset.apply_changes()
        |> Map.take([:task_id, :run_id, :prompt, :options, :status])
        |> Map.merge(%{id: UXID.generate!(prefix: "qst"), inserted_at: at, updated_at: at})
      end

    {_count, filed} = Repo.insert_all(Question, rows, returning: true)
    asked = Enum.sort_by(filed, &DateTime.to_unix(&1.inserted_at, :microsecond))
    by_key = Map.merge(held, Map.new(asked, &{normalized(&1.prompt), &1}))

    %{asked: asked, already: repeated |> Enum.reverse() |> Enum.map(&Map.fetch!(by_key, &1))}
  end

  defp sort_out(changeset, {fresh, repeated, seen}) do
    key = normalized(Ecto.Changeset.get_field(changeset, :prompt))

    if MapSet.member?(seen, key),
      do: {fresh, [key | repeated], seen},
      else: {[changeset | fresh], repeated, MapSet.put(seen, key)}
  end

  defp normalized(prompt), do: prompt |> String.trim() |> String.downcase()
end
