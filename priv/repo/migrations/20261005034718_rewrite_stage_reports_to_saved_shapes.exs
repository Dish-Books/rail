defmodule Rail.Repo.Migrations.RewriteStageReportsToSavedShapes do
  use Ecto.Migration

  # Reports agents wrote before saves went through Rail's tools are rewritten in
  # the shape the tools save, since the readers now refuse any other shape: a
  # review or QA pass that finished before the deploy, and had its findings
  # turned into rows then, stays closed. A report an old-brief agent writes after
  # the deploy is not rewritten, and reads as not saved.
  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier] <- rows do
      rewrite(Path.join([scratch_path, "reviews", "#{identifier}.json"]), &review/2)
      rewrite(Path.join([scratch_path, "qa", "#{identifier}.json"]), &qa_report/2)
    end
  end

  def down, do: :ok

  defp rewrite(path, shape) do
    with {:ok, content} <- File.read(path),
         {:ok, %{} = report} <- Jason.decode(content),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      temporary = path <> ".rewrite"
      File.write!(temporary, Jason.encode!(shape.(report, DateTime.from_unix!(mtime))))
      File.rename!(temporary, path)
    end
  end

  defp review(%{"saved_at" => saved_at}, _modified) when is_binary(saved_at), do: %{saved_at: saved_at}
  defp review(%{}, modified), do: %{saved_at: modified}

  defp qa_report(report, _modified) do
    %{verdict: report["verdict"], summary: report["summary"], not_checked: report["not_checked"]}
  end
end
