defmodule Rail.Mcp.Utils.RunToolSaveDesignOptionTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveDesignOption

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rtdo_1", "identifier" => "RTDO-1", "title" => "Run Tool Design"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Run Tool Design"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    dir = Path.join(task.scratch_path, "design")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "round-bar.html"), "<html></html>")
    File.write!(Path.join(dir, "round-bar.png"), "png")
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "a good save is receipted by its key and title, taking only the declared fields", %{task: task} do
    option = %{"key" => "round-bar", "title" => "Round bar", "summary" => "A bar.", "html" => "<script>"}

    assert {:ok, "Saved option round-bar: Round bar. " <> _rest} = run_tool_save_design_option(task, option, [])
    assert %{options: [%{key: "round-bar", html: "<html></html>"}]} = Pipeline.read_design(task)
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_design_option(task, %{"key" => "round-bar"}, [])
  end
end
