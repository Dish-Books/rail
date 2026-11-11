defmodule Rail.Issues.Workers.EmbedIssues do
  @moduledoc """
  The five-minute sweep that embeds every ticket whose title or description changed since it was last embedded,
  whatever wrote it, so `Rail.Issues.search_issues/2` finds it by its new wording.
  """
  use Oban.Worker, queue: :issues, max_attempts: 1, unique: [states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Repo

  defmacrop text(issue) do
    quote do
      fragment("coalesce(?, '') || E'\\n\\n' || coalesce(?, '')", unquote(issue).title, unquote(issue).description)
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # With Goth off every ticket's call would fail before a request, so there is nothing to try.
    if Rail.goth_enabled?() do
      from(i in Issue,
        where: is_nil(i.embedding_digest) or i.embedding_digest != fragment("md5(?)", text(i)),
        order_by: [asc: i.id],
        select: %{id: i.id, text: text(i), digest: fragment("md5(?)", text(i))}
      )
      |> Repo.all()
      |> Task.async_stream(&embed/1, max_concurrency: 5, timeout: to_timeout(minute: 1), on_timeout: :kill_task)
      |> Stream.run()
    end

    :ok
  end

  # The digest is checked again at the write, so an edit that landed mid-call waits for the next run.
  defp embed(%{id: id, text: text, digest: digest}) do
    with {:ok, values} <- Learnings.embed_document(text) do
      Repo.update_all(
        from(i in Issue, where: i.id == ^id and fragment("md5(?)", text(i)) == ^digest),
        set: [embedding: Pgvector.new(values), embedding_digest: digest]
      )
    end
  end
end
