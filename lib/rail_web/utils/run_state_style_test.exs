defmodule RailWeb.Utils.RunStateStyleTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RunStateStyle

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  test "icon follows the run's state" do
    assert run_state_style(nil).icon == "pi-clock"
    assert run_state_style(%Run{status: :running}).icon == "pi-play-circle"
    assert run_state_style(%Run{status: :blocked_on_input}).icon == "pi-question"
    assert run_state_style(%Run{status: :finished, error: "boom"}).icon == "pi-warning-circle"
    assert run_state_style(%Run{status: :finished}).icon == "pi-pause-circle"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).icon == "pi-chat-text"
    assert run_state_style(%Run{status: :waiting_for_resources}).icon == "pi-hourglass-medium"
  end

  test "text and chip classes share the state's colour" do
    assert run_state_style(%Run{status: :running}).text_class =~ "text-blue"
    assert run_state_style(%Run{status: :blocked_on_input}).text_class =~ "text-amber"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).text_class =~ "text-amber"
    assert run_state_style(%Run{status: :finished, error: "boom"}).text_class =~ "text-red"
    assert run_state_style(nil).text_class =~ "text-slate"
    assert run_state_style(%Run{status: :waiting_for_resources}).text_class =~ "text-violet"
    assert run_state_style(%Run{status: :waiting_for_resources}).chip_class =~ "bg-violet"

    assert run_state_style(%Run{status: :running}).chip_class =~ "bg-blue"
    assert run_state_style(%Run{status: :blocked_on_input}).chip_class =~ "bg-amber"
    assert run_state_style(%Run{status: :finished, error: "boom"}).chip_class =~ "bg-red"
    assert run_state_style(nil).chip_class =~ "bg-slate"
  end

  test "pill label names the state" do
    assert run_state_style(%Run{status: :running}).pill_label == "Running"
    assert run_state_style(%Run{status: :blocked_on_input}).pill_label == "Needs you"
    assert run_state_style(%Run{status: :finished, error: "boom"}).pill_label == "Failed"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).pill_label == "Done"
    assert run_state_style(%Run{status: :finished}).pill_label == "Stopped"
    assert run_state_style(nil).pill_label == "Queued"
    assert run_state_style(%Run{status: :waiting_for_resources}).pill_label == "Waiting for resources"

    assert %{
             icon: "pi-gauge",
             pill_label: "Waiting for usage",
             text_class: "text-violet" <> _text,
             chip_class: "bg-violet" <> _chip
           } =
             run_state_style(%Run{status: :waiting_for_usage})
  end

  test "a Review round waiting on a person takes the Findings icon, and every other run reads as it does alone" do
    scratch = Path.join(System.tmp_dir!(), "run_state_style_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)
    task = %Task{stage: :review, scratch_path: scratch, issue: %Issue{identifier: "RSS-1"}}
    done = %Run{status: :finished, stage_outcome: :done, role: %Role{stage: :review_lead}}
    amber = run_state_style(done)

    assert %{icon: "pi-list-checks", pill_label: "Done"} = run_state_style(done, task)
    assert %{run_state_style(done, task) | icon: amber.icon} == amber

    for run <- [
          %{done | status: :blocked_on_input},
          %{done | stage_outcome: :in_progress},
          %{done | stage_outcome: :in_progress, error: "boom"},
          %{done | role: %Role{stage: :engineer}}
        ] do
      assert run_state_style(run, task) == run_state_style(run)
    end

    assert run_state_style(%{done | role: %Role{stage: :engineer}}, %{task | stage: :engineer}) ==
             run_state_style(done)

    File.mkdir_p!(Path.join(scratch, "reviews"))

    File.write!(
      Path.join(scratch, "reviews/RSS-1.json"),
      ~s({"passes": [{"round": 1, "saved_at": "2026-10-01T10:00:00Z", "head": "abc", "finished_at": "2026-10-01T11:00:00Z"}]})
    )

    assert run_state_style(done, task) == run_state_style(done)
  end
end
