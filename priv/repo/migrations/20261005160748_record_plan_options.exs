defmodule Rail.Repo.Migrations.RecordPlanOptions do
  @moduledoc false
  use Ecto.Migration

  # Approval now needs a plan that names the pick. Under the old flow the architect
  # only started once the design was approved, so a plan already saved on a task
  # moved into Plan was written for its pick, and the file `save_plan` keeps beside
  # the plan is written to say so. A task missing its scratch, plan or pick is left as it is.
  #
  # A task that never had a product run, started straight at design or architect,
  # never saved a ticket, the issue being its ticket, so the issue is written as one
  # for approval to publish. A task that had one leaves its ticket to Product.
  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier,
             EXISTS (
               SELECT 1 FROM runs r JOIN roles ro ON ro.id = r.role_id
               WHERE r.task_id = tasks.id AND ro.stage = 'product'
             ),
             issues.title, issues.description, issues.priority, issues.estimate
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.stage = 'plan' AND tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier, had_product? | issue] <- rows, File.dir?(scratch_path) do
      record_option(scratch_path, identifier)
      if not had_product?, do: record_ticket(scratch_path, identifier, issue)
    end
  end

  def down, do: :ok

  defp record_option(scratch_path, identifier) do
    plans = Path.join(scratch_path, "plans")
    design = Path.join(scratch_path, "design")

    with true <- File.regular?(Path.join(plans, "#{identifier}.md")),
         {:ok, picked} <- File.read(Path.join(design, "picked")),
         key = String.trim(picked),
         {:ok, manifest} <- File.read(Path.join(design, "manifest.json")),
         {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(manifest),
         %{"title" => title} when is_binary(title) <- Enum.find(options, &match?(%{"key" => ^key}, &1)) do
      write(Path.join(plans, "#{identifier}.design.json"), Jason.encode!(%{key: key, title: String.trim(title)}))
    end
  end

  # The design section approving the design appended is left off, since approving the plan appends it again.
  defp record_ticket(scratch_path, identifier, [title, description, priority, estimate]) do
    path = Path.join([scratch_path, "tickets", "#{identifier}.md"])

    if not File.regular?(path) do
      description = description || ""

      description =
        case :binary.matches(description, "\n\n## Design: ") do
          [] -> description
          matches -> binary_part(description, 0, matches |> List.last() |> elem(0))
        end

      fields =
        [title: String.trim(title || ""), priority: priority, estimate: estimate && Integer.to_string(estimate)]
        |> Enum.reject(fn {_field, value} -> value in [nil, ""] end)
        |> Enum.map_join("\n", fn {field, value} -> "#{field}: #{value}" end)

      File.mkdir_p!(Path.dirname(path))
      write(path, String.trim_trailing("---\n#{fields}\n---\n\n#{String.trim(description)}") <> "\n")
    end
  end

  defp write(path, content) do
    temporary = path <> ".rewrite"
    File.write!(temporary, content)
    File.rename!(temporary, path)
  end
end
