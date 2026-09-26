defmodule Rail.Triage.Actions.PostTriageReply do
  @moduledoc false

  import Rail.Triage.Utils.PostToSlack
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.SlackIssueLink

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item

  @doc """
  Posts an item's reply, with the person's edits, in the thread as them. A reply
  that links its issue waits until the issue exists.
  """
  def post_triage_reply(%Scope{} = scope, %Item{id: item_id}, attrs) do
    item = Repo.get!(Item, item_id)

    with :ok <- open(item),
         {:ok, _drafted} <- Triage.update_triage_draft(scope, item, attrs),
         item = Item |> Repo.get!(item_id) |> Repo.preload([:created_issue, thread: [slack_channel: :slack_workspace]]),
         {:ok, text} <- text(item),
         {:ok, _message} <- post_to_slack(scope, item.thread, text) do
      {:ok, item} =
        item
        |> Ecto.Changeset.change(reply_posted_at: DateTime.utc_now(), reply_posted_by_id: scope.user.id)
        |> Repo.update()

      {:ok, _thread} = settle_thread(item.thread)
      {:ok, item}
    end
  end

  defp open(%Item{retriaging: true}), do: {:error, :locked}
  defp open(%Item{reply_posted_at: %DateTime{}}), do: {:error, :already_posted}
  defp open(%Item{}), do: :ok

  defp text(%Item{reply_text: text, created_issue: issue}) when is_binary(text) do
    cond do
      not String.contains?(text, "{issue link}") -> {:ok, text}
      is_nil(issue) -> {:error, :needs_issue_link}
      true -> {:ok, String.replace(text, "{issue link}", slack_issue_link(issue))}
    end
  end

  defp text(%Item{}), do: {:error, :no_reply}
end
