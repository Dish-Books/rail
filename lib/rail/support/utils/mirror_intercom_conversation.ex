defmodule Rail.Support.Utils.MirrorIntercomConversation do
  @moduledoc false

  import Ecto.Query
  import Rail.Support.Utils.RequestSupportDraft

  alias Rail.Repo
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Message

  @doc """
  Mirrors a conversation as Intercom handed it over, every part upserted by its id, and asks for a draft when
  `draft: true` and a customer wrote since the last one. Returns `{:ok, conversation}`.
  """
  def mirror_intercom_conversation(
        %IntercomWorkspace{} = workspace,
        %{"id" => external_id, "updated_at" => updated_at} = payload,
        opts
      )
      when is_integer(updated_at) do
    external_id = to_string(external_id)
    source = Map.put(payload["source"] || %{}, "created_at", payload["created_at"])
    rows = rows(source, payload)
    fetched_at = DateTime.from_unix!(updated_at * 1_000_000, :microsecond)
    last_customer_at = rows |> Enum.filter(&(&1.kind == :customer)) |> latest()
    fields = fields(source, rows, fetched_at)

    # Only the import may start a conversation Done; anything a webhook brings in starts Waiting.
    first_status =
      if Keyword.get(opts, :imported, false), do: Conversation.calculate_first_status(payload["state"]), else: :waiting

    {:ok, conversation} =
      Repo.transaction(fn ->
        # An older read than the stored one updates nothing; allow_stale keeps that from raising.
        _row =
          Repo.insert!(
            struct(
              Conversation,
              [
                project_id: workspace.project_id,
                intercom_workspace_id: workspace.id,
                external_id: external_id,
                status: first_status,
                done_at: if(first_status == :done, do: fetched_at)
              ] ++ fields
            ),
            on_conflict: from(c in Conversation, where: c.intercom_updated_at <= ^fetched_at, update: [set: ^fields]),
            conflict_target: [:intercom_workspace_id, :external_id],
            allow_stale: true
          )

        conversation = Repo.get_by!(Conversation, intercom_workspace_id: workspace.id, external_id: external_id)
        now = DateTime.utc_now()

        Repo.insert_all(
          Message,
          Enum.map(
            rows,
            &Map.merge(&1, %{
              id: UXID.generate!(prefix: "smg", monotonic: true),
              conversation_id: conversation.id,
              inserted_at: now,
              updated_at: now
            })
          ),
          on_conflict: {:replace, [:kind, :author_name, :text, :attachments, :posted_at, :updated_at]},
          conflict_target: [:conversation_id, :external_id]
        )

        # A customer writing after the posted reply starts the next round, with an empty draft so the sent reply is not
        # drafted again, and takes a Done conversation back to Waiting.
        new_round =
          is_struct(conversation.reply_posted_at, DateTime) and newer?(last_customer_at, conversation.reply_posted_at)

        reopened = Conversation.reopened?(conversation, last_customer_at)

        conversation
        |> Ecto.Changeset.change(
          if(new_round, do: [reply_text: nil, reply_posted_at: nil, reply_posted_by_id: nil, send_error: nil], else: [])
        )
        |> Ecto.Changeset.change(if(reopened, do: [status: :waiting, done_at: nil, done_by_id: nil], else: []))
        |> Repo.update!()
      end)

    if Keyword.get(opts, :draft, false) and conversation.status == :waiting and
         newer?(last_customer_at, conversation.drafted_at) do
      request_support_draft(conversation)
    else
      Phoenix.PubSub.broadcast(Rail.PubSub, "support", {:support_changed, conversation.id})
      {:ok, conversation}
    end
  end

  defp rows(source, payload) do
    parts = List.wrap(get_in(payload, ["conversation_parts", "conversation_parts"]))

    Enum.reject(
      [Message.build_attrs(source, "source") | Enum.map(parts, &Message.build_attrs(&1, &1["part_type"]))],
      &is_nil/1
    )
  end

  # What every read refreshes; the title only when Intercom has a subject, so the agent's title stays otherwise.
  defp fields(source, rows, fetched_at) do
    title = subject(source["subject"])
    author = source["author"] || %{}

    # A teammate's outbound message starts a conversation too; the customer is then whoever answers it.
    {customer_name, customer_email} =
      if Message.calculate_kind(author["type"], "source") == :customer,
        do: {author["name"], author["email"]},
        else: {Enum.find_value(rows, &(&1.kind == :customer && &1.author_name)), nil}

    [
      customer_name: customer_name,
      customer_email: customer_email,
      last_message_at: latest(rows),
      intercom_updated_at: fetched_at,
      updated_at: DateTime.utc_now()
    ] ++ if(title, do: [title: title], else: [])
  end

  defp latest(rows), do: rows |> Enum.map(& &1.posted_at) |> Enum.max(DateTime, fn -> nil end)

  defp newer?(%DateTime{} = at, %DateTime{} = than), do: DateTime.after?(at, than)
  defp newer?(%DateTime{}, nil), do: true
  defp newer?(nil, _than), do: false

  defp subject(html) when is_binary(html) do
    text = html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()
    if text == "", do: nil, else: text
  end

  defp subject(_none), do: nil
end
