defmodule Rail.Pipeline.Actions.AskQuestions do
  @moduledoc """
  Files the questions an agent asks through `ask_questions` on its run, held as asked until its turn ends.

  The run is left working: `register_asked_questions/2` makes them the round, and parks the run, once the turn is over.
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
    |> Ecto.Changeset.update_change(:options, &for(option <- &1, String.trim(option) != "", do: String.trim(option)))
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
      Repo.all(
        from q in Question,
          where: q.run_id == ^run_id and q.status in [:asked, :pending],
          order_by: [asc: q.inserted_at, asc: q.id]
      )

    seen = Map.new(held, &{normalized(&1.prompt), &1})

    {asked, already, _seen} =
      Enum.reduce(changesets, {[], [], seen}, fn changeset, {asked, already, seen} ->
        key = normalized(Ecto.Changeset.get_field(changeset, :prompt))

        case Map.fetch(seen, key) do
          {:ok, question} ->
            {asked, [question | already], seen}

          :error ->
            question = Repo.insert!(changeset)
            {[question | asked], already, Map.put(seen, key, question)}
        end
      end)

    %{asked: Enum.reverse(asked), already: Enum.reverse(already)}
  end

  defp normalized(prompt), do: prompt |> String.trim() |> String.downcase()
end
