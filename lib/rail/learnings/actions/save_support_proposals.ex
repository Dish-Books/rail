defmodule Rail.Learnings.Actions.SaveSupportProposals do
  @moduledoc """
  The support agent's proposed rules for a conversation, by its keys: new ones added, undecided ones redrafted, undecided
  ones it left out deleted. A rule the support person decided is closed to it. The caller holds the conversation's row lock.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.EnqueueEmbedding

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Repo
  alias Rail.Support.Schemas.ChatMessage
  alias Rail.Support.Schemas.Conversation

  @doc """
  Saves `rules`, maps with `key`, `title`, `rule`, `why` and `kind`, as the turn of chat `line`. Returns
  `{:ok, %{added:, edited:, dropped:}}`, each a list of proposals, or `{:error, {key, changeset}}` for the first rule
  Rail could not save.
  """
  def save_support_proposals(%Conversation{id: id, project_id: project_id}, %ChatMessage{id: line_id}, rules)
      when is_list(rules) do
    Repo.transaction(fn ->
      # Locked, so an Approve waits for this pass and approves what it wrote, or this pass finds it decided.
      current =
        Repo.all(
          from p in LearningProposal,
            where: p.support_conversation_id == ^id and p.project_id == ^project_id,
            preload: :learning,
            lock: "FOR UPDATE"
        )

      open = for %LearningProposal{status: :pending} = p <- current, into: %{}, do: {p.support_key, p}
      closed = for %LearningProposal{support_key: key} <- current, not Map.has_key?(open, key), do: key

      # The agent's list is untrusted: a key it repeats is saved once, as it first wrote it.
      saved =
        for %{"key" => key} = attrs <- Enum.uniq_by(rules, &(is_map(&1) && &1["key"])),
            is_binary(key),
            key not in closed do
          case save(project_id, id, line_id, Map.get(open, key), attrs) do
            {:ok, outcome} -> outcome
            {:error, changeset} -> Repo.rollback({key, changeset})
          end
        end

      kept = for {_outcome, %LearningProposal{support_key: key}} <- saved, do: key
      dropped = for {key, proposal} <- open, key not in kept, do: proposal

      Repo.delete_all(
        from l in Learning, where: l.project_id == ^project_id and l.id in ^Enum.map(dropped, & &1.learning_id)
      )

      # A changed rule or why cleared its draft's embedding; a new title alone leaves it.
      enqueue_embedding(
        for {_outcome, %LearningProposal{learning: %Learning{embedding: nil} = draft}} <- saved, do: draft
      )

      %{
        added: for({:added, p} <- saved, do: p),
        edited: for({:edited, p} <- saved, do: p),
        dropped: dropped
      }
    end)
  end

  defp save(project_id, conversation_id, line_id, nil, attrs) do
    with {:ok, draft} <-
           %Learning{project_id: project_id, status: :proposed, roles: [:triage]}
           |> Learning.changeset(draft_attrs(attrs))
           |> Repo.insert(),
         {:ok, proposal} <-
           %LearningProposal{
             project_id: project_id,
             support_conversation_id: conversation_id,
             support_chat_message_id: line_id,
             support_key: attrs["key"]
           }
           |> LearningProposal.changeset(%{action: :add, learning_id: draft.id, title: attrs["title"]})
           |> Repo.insert() do
      {:ok, {:added, %{proposal | learning: draft}}}
    end
  end

  defp save(_project_id, _conversation_id, _line_id, %LearningProposal{learning: draft} = proposal, attrs) do
    drafted = Learning.changeset(draft, draft_attrs(attrs))
    titled = LearningProposal.changeset(proposal, %{title: attrs["title"]})
    outcome = if drafted.changes == %{} and titled.changes == %{}, do: :kept, else: :edited

    with {:ok, draft} <- Repo.update(drafted),
         {:ok, proposal} <- Repo.update(titled) do
      {:ok, {outcome, %{proposal | learning: draft}}}
    end
  end

  defp draft_attrs(attrs), do: %{rule: attrs["rule"], why: attrs["why"], kind: attrs["kind"]}
end
